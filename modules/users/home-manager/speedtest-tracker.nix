# Speedtest Tracker - Home Manager Container Configuration
#
# This file configures a rootless Podman container for Speedtest Tracker via systemd user service.
# System-level configuration (nginx, redis, secrets) is in /etc/nixos/modules/containers/speedtest-tracker-quadlet.nix
#
# Container: lscr.io/linuxserver/speedtest-tracker:latest
# Port: 8765 (internal, proxied via nginx)
# Database: PostgreSQL via host.containers.internal:5432
# Cache: Redis via 127.0.0.1:6387

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.speedtest-tracker =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      home.stateVersion = "24.11";
      home.username = "speedtest-tracker";
      home.homeDirectory = "/var/lib/containers/speedtest-tracker";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
        postgresql
      ];

      systemd.user.services.speedtest-tracker = {
        Unit = {
          Description = "Speedtest Tracker Container";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };

        Service = {
          Type = "simple";

          # Ensure setuid wrappers (newuidmap/newgidmap) are found before non-setuid versions
          Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";

          # Wait for PostgreSQL before starting
          ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 30";

          # Start the container in foreground mode
          ExecStart = builtins.concatStringsSep " " [
            "${pkgs.podman}/bin/podman run --rm"
            "--name speedtest-tracker"
            "--replace"
            "--label PODMAN_SYSTEMD_UNIT=speedtest-tracker.service"
            "--network slirp4netns:allow_host_loopback=true"
            "-p 127.0.0.1:8765:80"
            "-e PUID=1000"
            "-e PGID=1000"
            "-e TZ=America/Los_Angeles"
            "-e APP_URL=https://speedtracker.vulcan.lan"
            "-e APP_TIMEZONE=America/Los_Angeles"
            "-e DISPLAY_TIMEZONE=America/Los_Angeles"
            "-e DB_CONNECTION=pgsql"
            "-e DB_HOST=host.containers.internal"
            "-e DB_PORT=5432"
            "-e DB_DATABASE=speedtest_tracker"
            "-e DB_USERNAME=speedtest_tracker"
            "-e CACHE_DRIVER=redis"
            "-e REDIS_HOST=host.containers.internal"
            "-e REDIS_PORT=6387"
            "-e SPEEDTEST_SCHEDULE=\"0 * * * *\""
            "-e PUBLIC_DASHBOARD=false"
            "-e MAIL_MAILER=smtp"
            "-e MAIL_HOST=host.containers.internal"
            "-e MAIL_PORT=2525"
            "-e MAIL_ENCRYPTION=null"
            "-e MAIL_FROM_ADDRESS=speedtest-tracker@vulcan.lan"
            "-e MAIL_FROM_NAME=\"Speedtest Tracker\""
            "-v /var/lib/containers/speedtest-tracker/config:/config"
            "--env-file /run/secrets-speedtest-tracker/speedtest-tracker-secrets"
            "lscr.io/linuxserver/speedtest-tracker:latest"
          ];

          # Stop the container
          ExecStop = "${pkgs.podman}/bin/podman stop -t 10 speedtest-tracker";

          # Cleanup on stop
          ExecStopPost = "-${pkgs.podman}/bin/podman rm -f speedtest-tracker";

          # Restart configuration
          Restart = "always";
          RestartSec = "15s";
          TimeoutStartSec = "300";
          TimeoutStopSec = "30";
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    };
}
