{
  config,
  lib,
  pkgs,
  ...
}:

let
  publishDir = "/var/lib/calendar-publisher";
  port = 8090;
  hostname = "calendar.newartisans.com";

  # Retry the fetch rather than failing the day's run on one network blip.
  #
  # sac-cluster-ics pulls a public Google Sheet over HTTPS with a plain
  # urllib.request.urlopen and a read timeout. On 2026-09-04 that timed out after
  # ~30s and failed the unit, which alerted. It was purely transient: the five runs
  # before it (08-30 .. 09-03) each completed in about ONE second, and a manual
  # re-run the same afternoon succeeded immediately. So the failure mode being
  # guarded is a momentary upstream stall, not a broken Sheet or a crash.
  #
  # WHY RETRY RATHER THAN A LONGER TIMEOUT: the timeout lives inside the upstream
  # CLI and is not exposed as a flag, and a longer one would make a genuinely
  # unreachable Sheet hang for minutes instead of failing. Three spaced attempts
  # cost at most ~2 minutes against a daily job whose normal runtime is one second.
  #
  # NOT masking real failure: after three attempts this still exits non-zero, so a
  # Sheet schema change or a persistent outage fails the unit exactly as before.
  # Same shape as the mbsync wrapper, which retries Gmail's socket closes in-process
  # rather than letting the unit enter `failed`.
  #
  # A failed run is already non-destructive -- it aborts before writing, leaving the
  # previous day's .ics files served rather than truncating them -- so the cost of a
  # miss is staleness, not an outage. That is why this is a retry and not an alarm.
  publisher = pkgs.writeShellApplication {
    name = "calendar-publisher-run";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for attempt in 1 2 3; do
        if ${pkgs.sac-cluster-ics}/bin/sac-cluster-ics --per-column ${publishDir}/; then
          exit 0
        fi
        if [ "$attempt" -lt 3 ]; then
          echo "sac-cluster-ics attempt $attempt/3 failed; retrying in 30s" >&2
          sleep 30
        fi
      done
      echo "sac-cluster-ics failed after 3 attempts" >&2
      exit 1
    '';
  };
in
{
  # Sacramento Cluster calendar publisher.
  #
  # Daily timer regenerates per-column .ics files from the public Google
  # Sheet via the sac-cluster-ics CLI. Files land in /var/lib/calendar-publisher
  # and are served by nginx on a localhost port that the existing
  # cloudflared "data" tunnel maps to calendar.newartisans.com.
  #
  # The tunnel's "calendar.newartisans.com" public hostname (and the
  # corresponding DNS record) is managed remotely from the Cloudflare
  # Zero Trust dashboard, so this module is intentionally Nix-side only:
  # publisher + nginx vhost. Adding new hostnames requires a one-time
  # dashboard click in addition to a Nix change.
  #
  # Subscribers add e.g. https://calendar.newartisans.com/florin.ics in any
  # calendar app. The CLI emits stable UIDs so re-runs update events in
  # place rather than duplicating them.

  users.users.calendar-publisher = {
    isSystemUser = true;
    group = "calendar-publisher";
    description = "Sacramento Cluster .ics generator";
  };
  users.groups.calendar-publisher = { };

  systemd.tmpfiles.rules = [
    "d ${publishDir} 0755 calendar-publisher calendar-publisher - -"
  ];

  systemd.services.calendar-publisher = {
    description = "Generate Sacramento Cluster .ics calendar files";

    # Refresh the health metrics as soon as this unit settles, either way.
    #
    # calendar-publisher-health writes calendar_publisher.prom on its OWN daily timer
    # (~05:01), i.e. the same cadence as the thing it observes. So a failure fixed at
    # midday kept CalendarPublisherFailed (critical) firing on 05:01's stale sample
    # until the next morning -- observed 2026-09-04, where the alert outlived the fix
    # by roughly fourteen hours and had to be cleared by running the checker by hand.
    #
    # BOTH hooks, deliberately. onSuccess alone would refresh only the good case, and
    # the failure case is the one that pages: without onFailure a real failure at 04:00
    # would not be reflected in the metrics until 05:01 the NEXT day. ExecStartPost is
    # not usable for this -- it is skipped entirely when ExecStart fails, which is
    # exactly the path that needs it most.
    #
    # The daily health timer stays as the backstop for the case where this unit does
    # not run at all.
    onSuccess = [ "calendar-publisher-health.service" ];
    onFailure = [ "calendar-publisher-health.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "calendar-publisher";
      Group = "calendar-publisher";
      ExecStart = lib.getExe publisher;

      # Bounds the retry above. Worst case is three CLI attempts at ~30s of read
      # timeout each plus two 30s sleeps == ~150s, so 5 minutes leaves headroom.
      #
      # This unit previously had TimeoutStartSec=infinity (measured, not assumed --
      # `systemctl show calendar-publisher -p TimeoutStartUSec` returned `infinity`
      # before this change). So the retry was never at risk of being cut short; what
      # this adds is an upper bound that did not exist, so a fetch that hangs without
      # the CLI's own read timeout firing cannot pin the unit indefinitely. Keep it
      # comfortably above 150s if the retry count or sleep is ever changed.
      TimeoutStartSec = "5min";

      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ReadWritePaths = [ publishDir ];
    };
  };

  systemd.timers.calendar-publisher = {
    description = "Daily refresh of Sacramento Cluster calendars";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  services.nginx.virtualHosts.${hostname} = {
    listen = [
      {
        addr = "127.0.0.1";
        port = port;
      }
    ];
    root = publishDir;
    extraConfig = ''
      types { text/calendar ics; }
      default_type application/octet-stream;
      autoindex off;
    '';
    locations."/" = {
      extraConfig = ''
        # 15-min edge TTL: matches Apple Calendar's poll cadence while
        # absorbing thundering-herd polls. Google polls ~24h regardless.
        add_header Cache-Control "public, max-age=900, stale-while-revalidate=3600";
        try_files $uri =404;
      '';
    };
  };
}
