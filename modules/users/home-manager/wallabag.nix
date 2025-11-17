{ config, lib, pkgs, inputs, ... }:

{
  home-manager.users.wallabag = { config, lib, pkgs, ... }: {
    imports = [
      inputs.quadlet-nix.homeManagerModules.quadlet
    ];


    home.stateVersion = "24.11";
    home.username = "wallabag";
    home.homeDirectory = "/var/lib/containers/wallabag";

    home.sessionVariables = {
      PODMAN_USERNS = "keep-id";
    };

    home.file.".keep".text = "";

    home.packages = with pkgs; [
      podman
      coreutils
      postgresql
    ];

    virtualisation.quadlet.containers.wallabag = {
      autoStart = true;

      containerConfig = {
        image = "docker.io/wallabag/wallabag:latest";
        publishPorts = [ "127.0.0.1:9091:80/tcp" ];
        networks = [ "slirp4netns:allow_host_loopback=true" ];

        environments = {
          POSTGRES_HOST = "127.0.0.1";
          SYMFONY__ENV__DATABASE_DRIVER = "pdo_pgsql";
          SYMFONY__ENV__DATABASE_HOST = "10.88.0.1";
          SYMFONY__ENV__DATABASE_PORT = "5432";
          SYMFONY__ENV__DATABASE_NAME = "wallabag";
          SYMFONY__ENV__DATABASE_USER = "wallabag";
          SYMFONY__ENV__DATABASE_CHARSET = "utf8";
          SYMFONY__ENV__DOMAIN_NAME = "https://wallabag.vulcan.lan";
          SYMFONY__ENV__SERVER_NAME = "Wallabag";
          SYMFONY__ENV__FOSUSER_CONFIRMATION = "false";
          SYMFONY__ENV__TWOFACTOR_AUTH = "false";
          POPULATE_DATABASE = "False";
        };

        environmentFiles = [ "/run/secrets-wallabag/wallabag-secrets" ];
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
