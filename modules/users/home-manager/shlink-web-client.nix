# Shlink Web Client - Home Manager Container Configuration
#
# This file configures a rootless Podman container for Shlink Web Client via systemd user service.
# System-level configuration (nginx, secrets) is in /etc/nixos/modules/containers/shlink-quadlet.nix
#
# Container: shlinkio/shlink-web-client:stable
# Port: 8581 (internal, proxied via nginx)
# Connects to: Shlink API at https://shlink-api.vulcan.lan

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.shlink-web-client =
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
      home.username = "shlink-web-client";
      home.homeDirectory = "/var/lib/containers/shlink-web-client";

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
      ];

      # Create a systemd user service for the shlink-web-client container
      systemd.user.services.shlink-web-client = {
        Unit = {
          Description = "Shlink Web Client Container";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };

        Service = {
          Type = "simple";

          # Start the container in foreground mode (not detached)
          # The container expects environment variables for server configuration
          # We use the internal vulcan.lan API URL since we're on the same network
          # Note: Using default pasta network instead of slirp4netns for better compatibility
          ExecStart = "${pkgs.podman}/bin/podman run --rm --name shlink-web-client --replace -p 127.0.0.1:8581:8080 --env-file /run/secrets-shlink-web-client/shlink-web-client docker.io/shlinkio/shlink-web-client:stable";

          # Stop the container
          ExecStop = "${pkgs.podman}/bin/podman stop -t 10 shlink-web-client";

          # Cleanup on stop
          ExecStopPost = "-${pkgs.podman}/bin/podman rm -f shlink-web-client";

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
