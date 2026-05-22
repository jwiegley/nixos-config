# modules/services/flume-autofill.nix
#
# Phase 2/3 NixOS module for the Flume water-attribution backend. Owns:
#   - SOPS secret declarations for Flume API + HA write-back token
#   - The systemd weekly cross-check service + timer
#   - The subdirectory tmpfiles entries Phase 2/3 need under
#     /var/lib/flume-autofill
#
# The flume-autofill user/group and the base /var/lib/flume-autofill
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
  cfg = config.services.flume-autofill;

  pyenv = pkgs.python3.withPackages (
    ps: with ps; [
      requests
      psycopg2
      websocket-client
      python-dateutil
      pyyaml
    ]
  );

  # Symlinked into the Python environment via PYTHONPATH below. We
  # readSourceFromOutOfTree-style at the source root because the package
  # is laid out as flume_autofill/ inside scripts/flume-autofill/.
  scriptDir = ../../scripts/flume-autofill;

in
{
  options.services.flume-autofill = {
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
      default = "johnw@newartisans.com";
      description = "Recipient of the weekly water report.";
    };

    reportFromAddress = lib.mkOption {
      type = lib.types.str;
      default = "vulcan@vulcan.newartisans.com";
      description = "From: address on the weekly water report email.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── SOPS secrets ────────────────────────────────────────────────
    # These are placeholders until the user populates secrets.yaml. The
    # values never enter Nix-tracked state — sops decrypts them at
    # activation time into /run/secrets/flume/* and the systemd unit
    # plumbs them into the process via LoadCredential.
    sops.secrets."flume/client_id" = {
      owner = "flume-autofill";
      mode = "0400";
    };
    sops.secrets."flume/client_secret" = {
      owner = "flume-autofill";
      mode = "0400";
    };
    sops.secrets."flume/username" = {
      owner = "flume-autofill";
      mode = "0400";
    };
    sops.secrets."flume/password" = {
      owner = "flume-autofill";
      mode = "0400";
    };
    # HA long-lived access token. Used by Phase 2 to write back the
    # cross-check delta sensor, and (planned) by Phase 3 to inject LTS
    # statistics via recorder.import_statistics over WebSocket.
    sops.secrets."home-assistant/flume-autofill-token" = {
      owner = "flume-autofill";
      mode = "0400";
    };

    # NOTE: users.users.flume-autofill, users.groups.flume-autofill, and the
    # base /var/lib/flume-autofill tmpfiles entry live in
    # modules/services/home-assistant-water-attribution.nix. We only add the
    # subdirectories used by Phase 2/3.
    systemd.tmpfiles.rules = [
      "d /var/lib/flume-autofill/reports 0750 flume-autofill flume-autofill -"
      "d /var/lib/flume-autofill/backfill 0750 flume-autofill flume-autofill -"
    ];

    # Hard requirement: Phase 1 owns the user/group and the zones.json
    # this service reads. If a fresh subagent forgets to enable it the
    # service can't start — fail the build with a clear message instead
    # of producing a half-broken system.
    assertions = [
      {
        assertion = config.services.home-assistant-water-attribution.enable;
        message = ''
          services.flume-autofill.enable = true requires
          services.home-assistant-water-attribution.enable = true.
          The latter owns the flume-autofill user/group used by this service.
        '';
      }
    ];

    systemd.services.flume-autofill-weekly = {
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
        FLUME_AUTOFILL_CONFIG = "/var/lib/flume-autofill/zones.json";
        FLUME_AUTOFILL_EMAIL_TO = cfg.emailTo;
        FLUME_AUTOFILL_FROM = cfg.reportFromAddress;
        FLUME_AUTOFILL_DELTA_GAL = toString cfg.deltaToleranceGal;
        FLUME_AUTOFILL_DELTA_PCT = toString cfg.deltaTolerancePct;
      };

      serviceConfig = {
        Type = "oneshot";
        User = "flume-autofill";
        Group = "flume-autofill";
        WorkingDirectory = "/var/lib/flume-autofill";
        # /run/wrappers/bin is needed for the setgid postdrop sendmail
        # wrapper. The Python module shells out to "sendmail -t -i".
        ExecStart = ''
          ${pyenv}/bin/python -m flume_autofill cross-check --days 7
        '';

        LoadCredential = [
          "client_id:${config.sops.secrets."flume/client_id".path}"
          "client_secret:${config.sops.secrets."flume/client_secret".path}"
          "username:${config.sops.secrets."flume/username".path}"
          "password:${config.sops.secrets."flume/password".path}"
          "ha_token:${config.sops.secrets."home-assistant/flume-autofill-token".path}"
        ];

        # ── Hardening ───────────────────────────────────────────────
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
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
          "/var/lib/flume-autofill"
          # Sendmail (setgid postdrop wrapper) writes into postfix's
          # maildrop queue.
          "/var/lib/postfix/queue"
        ];

        TimeoutStartSec = "10min";
      };
    };

    systemd.timers.flume-autofill-weekly = {
      description = "Weekly Flume autofill cross-check + water report";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.weeklySchedule;
        Persistent = true;
        RandomizedDelaySec = "10m";
        AccuracySec = "1min";
        Unit = "flume-autofill-weekly.service";
      };
    };

    # Phase 3: Historical backfill template service. Instantiated manually
    # via `systemctl start 'flume-autofill-backfill@<INSTANCE>.service'`
    # where INSTANCE matches `parse_systemd_instance` in
    # flume_autofill/backfill.py — i.e. one of:
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
    systemd.services."flume-autofill-backfill@" = {
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
        FLUME_AUTOFILL_CONFIG = "/var/lib/flume-autofill/zones.json";
        FLUME_AUTOFILL_INSTANCE = "%i";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "flume-autofill";
        Group = "flume-autofill";
        WorkingDirectory = "/var/lib/flume-autofill";
        ExecStart = "${pyenv}/bin/python -m flume_autofill backfill";

        LoadCredential = [
          "client_id:${config.sops.secrets."flume/client_id".path}"
          "client_secret:${config.sops.secrets."flume/client_secret".path}"
          "username:${config.sops.secrets."flume/username".path}"
          "password:${config.sops.secrets."flume/password".path}"
          "ha_token:${config.sops.secrets."home-assistant/flume-autofill-token".path}"
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
        ReadWritePaths = [ "/var/lib/flume-autofill" ];

        # Multi-year backfills cap out around 10 minutes of wall-clock
        # in practice; give the driver headroom for the LTS write phase
        # which serialises per-category WebSocket sends.
        TimeoutStartSec = "30min";
      };
    };
  };
}
