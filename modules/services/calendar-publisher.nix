{
  config,
  lib,
  pkgs,
  ...
}:

let
  publishDir = "/var/lib/calendar-publisher";
  port = 8090;
in
{
  # Sacramento Cluster calendar publisher.
  #
  # Daily timer regenerates per-column .ics files from the public Google
  # Sheet via the sac-cluster-ics CLI. Files land in /var/lib/calendar-publisher
  # and are served by nginx on a localhost port that the existing
  # cloudflared "data" tunnel maps to calendar.newartisans.com.
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
    serviceConfig = {
      Type = "oneshot";
      User = "calendar-publisher";
      Group = "calendar-publisher";
      ExecStart = "${pkgs.sac-cluster-ics}/bin/sac-cluster-ics --per-column ${publishDir}/";

      # Hardening
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

  services.nginx.virtualHosts."calendar.newartisans.com" = {
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
        # Trailing-slash directory listing disabled; only direct .ics URLs.
        try_files $uri =404;
      '';
    };
  };
}
