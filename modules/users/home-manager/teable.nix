{ config, lib, pkgs, inputs, ... }:

{
  home-manager.users.teable = { config, lib, pkgs, ... }: {
    imports = [
      inputs.quadlet-nix.homeManagerModules.quadlet
    ];


    home.stateVersion = "24.11";
    home.username = "teable";
    home.homeDirectory = "/var/lib/containers/teable";

    home.sessionVariables = {
      PODMAN_USERNS = "keep-id";
    };

    home.file.".keep".text = "";

    home.packages = with pkgs; [
      podman
      coreutils
      postgresql
    ];

    virtualisation.quadlet.containers.teable = {
      autoStart = true;

      containerConfig = {
        image = "ghcr.io/teableio/teable-community:latest";
        publishPorts = [ "127.0.0.1:3004:3000/tcp" ];
        networks = [ "slirp4netns:allow_host_loopback=true" ];

        environments = {
          POSTGRES_HOST = "127.0.0.1";
          POSTGRES_PORT = "5432";
          POSTGRES_DB = "teable";
          POSTGRES_USER = "teable";
          PUBLIC_ORIGIN = "https://teable.vulcan.lan";
          TIMEZONE = "America/Los_Angeles";
        };

        environmentFiles = [ "/run/secrets-teable/teable-env" ];

        volumes = [
          "/var/lib/teable:/app/.assets:rw"
        ];
      };

      unitConfig = {
        After = [ "network-online.target" ];
        StartLimitIntervalSec = "300";
        StartLimitBurst = "5";
      };

      serviceConfig = {
        ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 30";
        Restart = "always";
        RestartSec = "10s";
        TimeoutStartSec = "900";
      };
    };
  };
}
