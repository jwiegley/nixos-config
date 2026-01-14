{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.openspeedtest =
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
      home.username = "openspeedtest";
      home.homeDirectory = "/var/lib/containers/openspeedtest";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      virtualisation.quadlet.containers.speedtest = {
        autoStart = true;

        containerConfig = {
          image = "docker.io/openspeedtest/latest:latest";
          publishPorts = [ "127.0.0.1:3002:3000/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];
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
