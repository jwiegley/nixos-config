# modules/services/flume-data.nix
#
# Phase 2/3 NixOS module for the Flume water-attribution backend. Owns:
#   - SOPS secret declarations for Flume API + HA write-back token
#   - The systemd weekly cross-check service + timer
#   - The subdirectory tmpfiles entries Phase 2/3 need under
#     /var/lib/flume-data
#
# The flume-data user/group and the base /var/lib/flume-data
# tmpfiles entry are declared by
# modules/services/home-assistant-water-attribution.nix (Phase 1), which
# is shared infrastructure between Phase 1 (zones.json materialization)
# and Phase 2/3 (this module). An assertion enforces that the Phase 1
# module is also enabled so a fresh subagent doesn't ship a half-broken
# system.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.flume-data;

  pyenv = pkgs.python3.withPackages (
    ps: with ps; [
      requests
      psycopg2
      websocket-client
      python-dateutil
      pyyaml
      # Explicit tz database for zoneinfo.ZoneInfo("America/Los_Angeles"), used
      # by the weekly report's daily breakdown (local-midnight meter-reset
      # alignment). Redundant with CPython's compiled TZPATH on this nixpkgs
      # build, but pins zone resolution independent of interpreter build flags.
      tzdata
    ]
  );

  # Symlinked into the Python environment via PYTHONPATH below. We
  # readSourceFromOutOfTree-style at the source root because the package
  # is laid out as flume_data/ inside scripts/flume-data/.
  scriptDir = ../../scripts/flume-data;

  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";

  # Last-success/last-run "did this oneshot work, and when" emitter for the
  # flume-data oneshots. A green Type=oneshot exit (code 0) is NOT proof the
  # cross-check actually reconciled, nor that the 6-hourly sync UPSERTed
  # anything — these jobs reconcile the inferred pool auto-fill attribution
  # (memory: project_pool_autofill_flume_detection) and previously failed or
  # succeeded INVISIBLY. This collector records, on every run:
  #   <prefix>_last_success                 1 iff $SERVICE_RESULT == "success", else 0
  #   <prefix>_last_run_timestamp_seconds   wall-clock of this emission
  # so FlumeSyncFailed / FlumeSyncStale / FlumeCrossCheckFailed /
  # FlumeCrossCheckStale can catch a silently-broken pipeline.
  #
  # Runs via ExecStopPost with a '+' prefix (as root) so it always fires on
  # success AND failure and can write atomically into the (sticky) textfile
  # dir regardless of the unit's User=flume-data. Mirrors the proven
  # pg_dump emitter in modules/services/postgresql-backup.nix.
  #   $1 = metric prefix (e.g. "flume_weekly_cross_check")
  #   $2 = textfile basename (e.g. "flume_cross_check.prom")
  #   $3 = run result ("success"/other from $SERVICE_RESULT)
  flumeMetricsScript = pkgs.writeShellScript "flume-data-metrics" ''
    set -euo pipefail

    prefix="$1"
    fname="$2"
    case "''${3:-0}" in
      success|1) success=1 ;;
      *)         success=0 ;;
    esac

    ${pkgs.coreutils}/bin/mkdir -p "${metricsDir}"
    now=$(${pkgs.coreutils}/bin/date +%s)

    target="${metricsDir}/$fname"
    tmp="$target.$$"

    {
      echo "# HELP ''${prefix}_last_success Whether the most recent run exited successfully (1=success, 0=failure)"
      echo "# TYPE ''${prefix}_last_success gauge"
      echo "''${prefix}_last_success $success"
      echo "# HELP ''${prefix}_last_run_timestamp_seconds Unix timestamp of the most recent run"
      echo "# TYPE ''${prefix}_last_run_timestamp_seconds gauge"
      echo "''${prefix}_last_run_timestamp_seconds $now"
    } > "$tmp"

    ${pkgs.coreutils}/bin/mv "$tmp" "$target"
    ${pkgs.coreutils}/bin/chmod 644 "$target"
  '';

in
{
  options.services.flume-data = {
    enable = lib.mkEnableOption "Flume autofill cross-check + backfill (Phase 2/3)";

    weeklySchedule = lib.mkOption {
      type = lib.types.str;
      default = "Mon 03:30:00";
      description = ''
        OnCalendar schedule for the weekly cross-check + water-report
        run. Monday morning before John's typical work-day start.
      '';
    };

    deltaToleranceGal = lib.mkOption {
      type = lib.types.float;
      default = 5.0;
      description = ''
        Absolute-delta threshold (gallons) for cross-check anomaly
        classification. A category passes if EITHER the absolute or
        the percentage delta is within tolerance.
      '';
    };

    deltaTolerancePct = lib.mkOption {
      type = lib.types.float;
      default = 3.0;
      description = ''
        Percent-delta threshold for cross-check anomaly classification.
        See deltaToleranceGal for the OR semantics.
      '';
    };

    emailTo = lib.mkOption {
      type = lib.types.str;
      default = "johnw@vulcan.lan";
      description = ''
        Recipient of the weekly water report. Kept on the local vulcan.lan
        domain so the message is delivered straight to Dovecot via LMTP
        (no Fastmail round-trip) and matches the Hermes/OpenClaw reports.
      '';
    };

    reportFromAddress = lib.mkOption {
      type = lib.types.str;
      default = "flume-data@vulcan.lan";
      description = ''
        From: address on the weekly water report email. Uses the local
        vulcan.lan domain so the Dovecot sieve_before whitelist
        (`address :domain :is "from" "vulcan.lan"`) and the rspamd
        local_mail_whitelist exempt it from spam filing. NOTE: a
        vulcan.lan sender only works for a vulcan.lan recipient — for an
        external recipient, smtp_generic_maps rewrites it to gmail.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ── SOPS secrets ────────────────────────────────────────────────
    # These are placeholders until the user populates secrets.yaml. The
    # values never enter Nix-tracked state — sops decrypts them at
    # activation time into /run/secrets/flume/* and the systemd unit
    # plumbs them into the process via LoadCredential.
    sops.secrets."flume/client_id" = {
      owner = "flume-data";
      mode = "0400";
    };
    sops.secrets."flume/client_secret" = {
      owner = "flume-data";
      mode = "0400";
    };
    sops.secrets."flume/username" = {
      owner = "flume-data";
      mode = "0400";
    };
    sops.secrets."flume/password" = {
      owner = "flume-data";
      mode = "0400";
    };
    # HA long-lived access token. Used by Phase 2 to write back the
    # cross-check delta sensor, and (planned) by Phase 3 to inject LTS
    # statistics via recorder.import_statistics over WebSocket.
    sops.secrets."home-assistant/flume-data-token" = {
      owner = "flume-data";
      mode = "0400";
    };

    # NOTE: users.users.flume-data, users.groups.flume-data, and the
    # base /var/lib/flume-data tmpfiles entry live in
    # modules/services/home-assistant-water-attribution.nix. We only add the
    # subdirectories used by Phase 2/3.
    systemd.tmpfiles.rules = [
      "d /var/lib/flume-data/reports 0750 flume-data flume-data -"
      "d /var/lib/flume-data/backfill 0750 flume-data flume-data -"
    ];

    # Hard requirement: Phase 1 owns the user/group and the zones.json
    # this service reads. If a fresh subagent forgets to enable it the
    # service can't start — fail the build with a clear message instead
    # of producing a half-broken system.
    assertions = [
      {
        # `or false` guards against the case where a host imports this
        # module without ever importing modules/services/home-assistant-
        # water-attribution.nix — without the fallback, the option
        # lookup itself would error before the friendly message fires.
        assertion = config.services.home-assistant-water-attribution.enable or false;
        message = ''
          services.flume-data.enable = true requires
          services.home-assistant-water-attribution.enable = true.
          The latter owns the flume-data user/group used by this service.
        '';
      }
    ];

    systemd.services.flume-data-weekly = {
      description = "Flume autofill weekly cross-check + water report";
      after = [
        "network-online.target"
        "postgresql.service"
        "home-assistant.service"
        "postfix.service"
      ];
      wants = [ "network-online.target" ];

      # PATH needs /run/wrappers (for the setgid postdrop sendmail
      # wrapper used by the email step) plus the usual coreutils/systemd
      # bins. Mirrors hermes-nightly-report's pattern.
      path = with pkgs; [
        "/run/wrappers"
        coreutils
        systemd
      ];

      environment = {
        PYTHONPATH = "${scriptDir}";
        PYTHONUNBUFFERED = "1";
        FLUME_AUTOFILL_CONFIG = "/var/lib/flume-data/zones.json";
        FLUME_AUTOFILL_EMAIL_TO = cfg.emailTo;
        FLUME_AUTOFILL_FROM = cfg.reportFromAddress;
        FLUME_AUTOFILL_DELTA_GAL = toString cfg.deltaToleranceGal;
        FLUME_AUTOFILL_DELTA_PCT = toString cfg.deltaTolerancePct;
      };

      serviceConfig = {
        Type = "oneshot";
        User = "flume-data";
        Group = "flume-data";
        WorkingDirectory = "/var/lib/flume-data";
        # /run/wrappers/bin is needed for the setgid postdrop sendmail
        # wrapper. The Python module shells out to "sendmail -t -i".
        ExecStart = ''
          ${pyenv}/bin/python -m flume_data cross-check --days 7
        '';

        # Emit last-success/last-run metrics on EVERY exit (success and
        # failure). The leading '+' runs this as root (ignoring
        # User=flume-data) so it can always write the textfile atomically.
        # $SERVICE_RESULT is "success" on a clean run; normalized to 1/0.
        ExecStopPost = "+${flumeMetricsScript} flume_weekly_cross_check flume_cross_check.prom $SERVICE_RESULT";

        LoadCredential = [
          "client_id:${config.sops.secrets."flume/client_id".path}"
          "client_secret:${config.sops.secrets."flume/client_secret".path}"
          "username:${config.sops.secrets."flume/username".path}"
          "password:${config.sops.secrets."flume/password".path}"
          "ha_token:${config.sops.secrets."home-assistant/flume-data-token".path}"
        ];

        # ── Hardening ───────────────────────────────────────────────
        ProtectSystem = "strict";
        ProtectHome = true;
        # NoNewPrivileges MUST stay false here: the email step shells out
        # to /run/wrappers/bin/sendmail, which is setgid `postdrop`, and
        # postdrop needs that setgid to write into postfix's 0730 maildrop
        # queue. With NoNewPrivileges=true the kernel ignores the setgid
        # bit, so postdrop runs as group flume-data, fails with
        # "mail_queue_enter: ... Permission denied", and the
        # sendmail/postdrop chain HANGS until TimeoutStartSec kills the
        # unit (FlumeCrossCheckFailed, root-caused 2026-06-15).
        # hermes-nightly-report keeps NNP=true only because it runs as
        # User=root (DAC override bypasses the queue perms); this unit runs
        # unprivileged as flume-data, so the setgid must actually take
        # effect. Matches the *-self-heal.nix pattern (setgid/setuid wrapper
        # ⇒ NoNewPrivileges=false + RestrictSUIDSGID=false).
        NoNewPrivileges = false;
        RestrictSUIDSGID = false; # postdrop sendmail wrapper is setgid
        PrivateTmp = true;
        # Required for HTTPS to api.flumewater.com, HTTP to localhost VM
        # + HA, and AF_NETLINK + AF_PACKET for postfix's getifaddrs() at
        # sendmail startup (mirrors hermes-nightly-report's required set).
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_PACKET"
        ];
        ReadWritePaths = [
          "/var/lib/flume-data"
          # Sendmail (setgid postdrop wrapper) writes into postfix's
          # maildrop queue.
          "/var/lib/postfix/queue"
        ];

        TimeoutStartSec = "10min";
      };
    };

    systemd.timers.flume-data-weekly = {
      description = "Weekly Flume autofill cross-check + water report";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.weeklySchedule;
        Persistent = true;
        RandomizedDelaySec = "10m";
        AccuracySec = "1min";
        Unit = "flume-data-weekly.service";
      };
    };

    # 6-hourly DB sync: pulls the last 3 days from Flume API + cache and
    # UPSERTs into flume_history.flume_segments. The 3-day window absorbs
    # late-arriving data without re-fetching the full history.
    systemd.services.flume-data-daily-sync = {
      description = "Sync recent Flume per-segment data into flume_history";
      after = [
        "network-online.target"
        "postgresql.service"
      ];
      wants = [ "network-online.target" ];

      path = [ pkgs.bash ];
      environment = {
        PYTHONPATH = "${scriptDir}";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "flume-data";
        Group = "flume-data";
        WorkingDirectory = "/var/lib/flume-data";
        ExecStart = "${pyenv}/bin/python -m flume_db_sync --days 3";

        # Last-success/last-run emitter on EVERY exit. Root via '+' so it can
        # write the textfile atomically regardless of User=flume-data and the
        # ProtectSystem=strict sandbox (which the '+' prefix bypasses).
        ExecStopPost = "+${flumeMetricsScript} flume_daily_sync flume_sync.prom $SERVICE_RESULT";

        LoadCredential = [
          "client_id:${config.sops.secrets."flume/client_id".path}"
          "client_secret:${config.sops.secrets."flume/client_secret".path}"
          "username:${config.sops.secrets."flume/username".path}"
          "password:${config.sops.secrets."flume/password".path}"
        ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/flume-data" ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    systemd.timers.flume-data-daily-sync = {
      description = "6-hourly Flume DB sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # 00:30, 06:30, 12:30, 18:30 — staggered off the top of the hour.
        OnCalendar = "*-*-* 00,06,12,18:30:00";
        Persistent = true;
        RandomizedDelaySec = "5m";
        AccuracySec = "1min";
        Unit = "flume-data-daily-sync.service";
      };
    };

    # One-shot bulk-loader: replays EVERY cached day into Postgres.
    # No timer; fired manually with `systemctl start
    # flume-data-bulkload.service` once the initial historical pull
    # has finished filling the cache. Idempotent — re-running just
    # UPSERTs the same rows over themselves.
    #
    # Uses execute_values batched at 5000 rows/page for the ~1.2M
    # minute samples; completes in seconds not minutes.
    systemd.services.flume-data-bulkload = {
      description = "Bulk-load all cached Flume days into PostgreSQL";
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
      environment = {
        PYTHONPATH = "${scriptDir}";
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "flume-data";
        Group = "flume-data";
        WorkingDirectory = "/var/lib/flume-data";
        ExecStart = "${pyenv}/bin/python -m flume_db_sync --from-cache";
        TimeoutStartSec = "30m";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/flume-data" ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    # Phase 3: Historical backfill template service. Instantiated manually
    # via `systemctl start 'flume-data-backfill@<INSTANCE>.service'`
    # where INSTANCE matches `parse_systemd_instance` in
    # flume_data/backfill.py — i.e. one of:
    #   YYYY                    e.g. 2024
    #   YYYY-MM                 e.g. 2024-05
    #   YYYY-MM-DD              e.g. 2024-05-18
    #   YYYY-MM-DD:YYYY-MM-DD   e.g. 2024-05-01:2024-05-07
    #
    # The instance string is plumbed into the process via
    # FLUME_AUTOFILL_INSTANCE=%i (systemd substitutes %i with the
    # post-@ portion of the unit name). The Python driver expands the
    # short form into a (start, end) date pair before running.
    #
    # No timer: backfill is operator-driven, not scheduled. The unit
    # holds the same LoadCredential set as the weekly service so it can
    # write back to HA's LTS namespace.
    systemd.services."flume-data-backfill@" = {
      description = "Flume autofill backfill for %i";
      after = [
        "network-online.target"
        "postgresql.service"
        "home-assistant.service"
      ];
      wants = [ "network-online.target" ];

      environment = {
        PYTHONPATH = "${scriptDir}";
        PYTHONUNBUFFERED = "1";
        FLUME_AUTOFILL_CONFIG = "/var/lib/flume-data/zones.json";
        FLUME_AUTOFILL_INSTANCE = "%i";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "flume-data";
        Group = "flume-data";
        WorkingDirectory = "/var/lib/flume-data";
        ExecStart = "${pyenv}/bin/python -m flume_data backfill";

        LoadCredential = [
          "client_id:${config.sops.secrets."flume/client_id".path}"
          "client_secret:${config.sops.secrets."flume/client_secret".path}"
          "username:${config.sops.secrets."flume/username".path}"
          "password:${config.sops.secrets."flume/password".path}"
          "ha_token:${config.sops.secrets."home-assistant/flume-data-token".path}"
        ];

        # ── Hardening ───────────────────────────────────────────────
        # Lighter than the weekly service (no postfix path needed —
        # backfill is fire-and-forget; failures appear in journalctl,
        # not email).
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        ReadWritePaths = [ "/var/lib/flume-data" ];

        # Multi-year backfills cap out around 10 minutes of wall-clock
        # in practice; give the driver headroom for the LTS write phase
        # which serialises per-category WebSocket sends.
        TimeoutStartSec = "30min";
      };
    };
  };
}
