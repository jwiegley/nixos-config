{ config, lib, pkgs, inputs, ... }:

{
  home-manager.users.mailarchiver = { config, lib, pkgs, ... }: {
    imports = [
      inputs.quadlet-nix.homeManagerModules.quadlet
    ];


    home.stateVersion = "24.11";
    home.username = "mailarchiver";
    home.homeDirectory = "/var/lib/containers/mailarchiver";

    home.sessionVariables = {
      PODMAN_USERNS = "keep-id";
    };

    home.file.".keep".text = "";

    home.packages = with pkgs; [
      podman
      coreutils
      postgresql
    ];

    virtualisation.quadlet.containers.mailarchiver = {
      autoStart = true;

      containerConfig = {
        image = "docker.io/s1t5/mailarchiver:latest";
        publishPorts = [ "127.0.0.1:9097:5000/tcp" ];
        networks = [ "slirp4netns:allow_host_loopback=true" ];

        environments = {
          POSTGRES_HOST = "127.0.0.1";
          APP_URL = "https://mailarchiver.vulcan.lan";
          TimeZone__DisplayTimeZoneId = "America/Los_Angeles";
          MAIL_HOST = "10.88.0.1";
          MAIL_PORT = "25";
          MAIL_FROM_ADDRESS = "mailarchiver@vulcan.lan";
          MailSync__IgnoreSelfSignedCert = "true";
          Logging__LogLevel__Default = "Information";
          Logging__LogLevel__Microsoft_AspNetCore = "Warning";
        };

        environmentFiles = [ "/run/secrets-mailarchiver/mailarchiver-env" ];

        volumes = [
          "/var/lib/mailarchiver/storage:/app/DataProtection-Keys:rw"
          "/var/lib/mailarchiver/logs:/app/logs:rw"
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
