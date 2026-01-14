{
  config,
  lib,
  pkgs,
  ...
}:

{
  home-manager.users.container-db =
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
      home.username = "container-db";
      home.homeDirectory = "/var/lib/containers/container-db";

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
