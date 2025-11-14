{ config, lib, pkgs, ... }:

let
  # Helper function to create home-manager config for container users
  mkContainerUserHome = username: {
    home-manager.users.${username} = { config, lib, pkgs, ... }: {
      # Home Manager state version
      home.stateVersion = "24.11";

      # Basic home settings
      home.username = username;
      home.homeDirectory = "/var/lib/containers/${username}";

      # Minimal environment for container operation
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
    };
  };

  # List of all dedicated container users
  containerUsers = [
    "changedetection"
    "litellm"
    "nocobase"
    "wallabag"
    "teable"
    "sillytavern"
    "opnsense-exporter"
    "technitium-dns-exporter"
    "openspeedtest"
  ];
in
{
  # Generate home-manager configurations for all container users
  imports = map mkContainerUserHome containerUsers;
}
