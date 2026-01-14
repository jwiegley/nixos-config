{
  config,
  lib,
  pkgs,
  ...
}:

{
  home-manager.users.container-monitor =
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
      home.username = "container-monitor";
      home.homeDirectory = "/var/lib/containers/container-monitor";

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
}
