# Shlink URL Shortener - Home Manager Container Configuration
#
# This file configures a rootless Podman container for Shlink via systemd user service.
# System-level configuration (nginx, redis, secrets) is in /etc/nixos/modules/containers/shlink-quadlet.nix
#
# Container: shlinkio/shlink:stable
# Port: 8580 (internal, proxied via nginx)
# Database: PostgreSQL via host.containers.internal:5432
# Cache: Redis via host.containers.internal:6385

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.shlink =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # Home Manager state version
      home.stateVersion = "24.11";

      # Basic home settings
      home.username = "shlink";
      home.homeDirectory = "/var/lib/containers/shlink";

      # Environment for rootless container operation
      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      # Ensure home directory structure exists
      home.file.".keep".text = "";

      # Basic packages available in container user environment
      home.packages = with pkgs; [
        podman
        coreutils
        postgresql # For pg_isready health check
      ];

      # Create a systemd user service for the shlink container
      # Using systemd service directly instead of quadlet to avoid sdnotify issues
      systemd.user.services.shlink = {
        Unit = {
          Description = "Shlink URL Shortener Container";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };

        Service = {
          Type = "simple";

          # Wait for PostgreSQL before starting
          ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 30";

          # Start the container in foreground mode (not detached)
          ExecStart = "${pkgs.podman}/bin/podman run --rm --name shlink --replace --label PODMAN_SYSTEMD_UNIT=shlink.service --network slirp4netns:allow_host_loopback=true -p 127.0.0.1:8580:8080 -e AUTO_RESOLVE_TITLES=true -e DB_DRIVER=postgres -e DB_HOST=host.containers.internal -e DB_NAME=shlink -e DB_PORT=5432 -e DB_USER=shlink -e DEFAULT_DOMAIN=s.newartisans.com -e DISABLE_TRACKING=false -e IS_HTTPS_ENABLED=true -e MEMORY_LIMIT=256M -e REDIRECT_STATUS_CODE=302 -e REDIS_SERVERS=tcp://host.containers.internal:6385 -e ROBOTS_ALLOW_ALL_SHORT_URLS=false -e TIMEZONE=America/Los_Angeles --env-file /run/secrets-shlink/shlink-secrets docker.io/shlinkio/shlink:stable";

          # Stop the container
          ExecStop = "${pkgs.podman}/bin/podman stop -t 10 shlink";

          # Cleanup on stop
          ExecStopPost = "-${pkgs.podman}/bin/podman rm -f shlink";

          # Restart configuration
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "300";
          TimeoutStopSec = "30";
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    };
}
