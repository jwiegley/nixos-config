{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.technitium-dns-exporter =
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
      home.username = "technitium-dns-exporter";
      home.homeDirectory = "/var/lib/containers/technitium-dns-exporter";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      virtualisation.quadlet.containers.technitium-dns-exporter = {
        autoStart = true;

        containerConfig = {
          image = "localhost/technitium-dns-exporter:latest";
          publishPorts = [ "127.0.0.1:9274:8080/tcp" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          environmentFiles = [ "/run/secrets-technitium-dns-exporter/technitium-dns-exporter-env" ];

          exec = "--log.level=warn --log.format=json";
        };

        unitConfig = {
          After = [ "network-online.target" ];
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
