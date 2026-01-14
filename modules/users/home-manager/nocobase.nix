{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.nocobase =
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
      home.username = "nocobase";
      home.homeDirectory = "/var/lib/containers/nocobase";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
        postgresql
      ];

      virtualisation.quadlet.containers.nocobase = {
        autoStart = true;

        containerConfig = {
          image = "docker.io/nocobase/nocobase:latest";
          publishPorts = [
            "127.0.0.1:13000:80/tcp"
            "10.88.0.1:13000:80/tcp"
          ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          environments = {
            POSTGRES_HOST = "127.0.0.1";
          };

          environmentFiles = [ "/run/secrets-nocobase/nocobase-secrets" ];

          volumes = [
            "/var/lib/nocobase:/app/nocobase/storage"
          ];
        };

        unitConfig = {
          After = [ "network-online.target" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -U nocobase -d nocobase -t 30";
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "900";
        };
      };
    };
}
