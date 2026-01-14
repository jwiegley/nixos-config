{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.sillytavern =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];

      home.stateVersion = "24.11";
      home.username = "sillytavern";
      home.homeDirectory = "/var/lib/containers/sillytavern";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      virtualisation.quadlet.containers.silly-tavern = {
        autoStart = true;

        containerConfig = {
          image = "ghcr.io/sillytavern/sillytavern:latest";
          publishPorts = [ "127.0.0.1:8083:8000/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          environments = {
            USER_PASSWORD = "";
            AUTO_UPDATE = "false";
          };

          volumes = [
            "/var/lib/silly-tavern/config:/home/node/app/config:Z"
            "/var/lib/silly-tavern/data:/home/node/app/data:Z"
          ];
        };

        unitConfig = {
          After = [ "sops-nix.service" ];
          Wants = [ "sops-nix.service" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "900";
        };
      };
    };
}
