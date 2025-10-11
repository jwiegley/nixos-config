{ config, lib, pkgs, ... }:

{
  # Wallabag container configuration
  virtualisation.quadlet.containers.wallabag = {
    containerConfig = {
      image = "docker.io/wallabag/wallabag:latest";
      publishPorts = [ "127.0.0.1:9091:80/tcp" ];
      environmentFiles = [ config.sops.secrets."wallabag-secrets".path ];
      environments = {
        SYMFONY__ENV__DATABASE_DRIVER = "pdo_pgsql";
        SYMFONY__ENV__DATABASE_HOST = "10.88.0.1";  # Use Podman bridge IP directly
        SYMFONY__ENV__DATABASE_PORT = "5432";
        SYMFONY__ENV__DATABASE_NAME = "wallabag";
        SYMFONY__ENV__DATABASE_USER = "wallabag";
        SYMFONY__ENV__DATABASE_CHARSET = "utf8";
        SYMFONY__ENV__DOMAIN_NAME = "https://wallabag.vulcan.lan";
        SYMFONY__ENV__SERVER_NAME = "Wallabag";
        SYMFONY__ENV__FOSUSER_CONFIRMATION = "false";
        SYMFONY__ENV__TWOFACTOR_AUTH = "false";
        POPULATE_DATABASE = "False";  # Database already exists, skip setup
      };
      volumes = [ ];  # Wallabag manages its own data internally
      networks = [ "podman" ];
    };
    unitConfig = {
      After = [ "sops-nix.service" "postgresql.service" "podman.service" ];
      Wants = [ "sops-nix.service" ];
      Requires = [ "postgresql.service" ];
    };
    serviceConfig = {
      # Wait for PostgreSQL to be ready to accept connections
      ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 10.88.0.1 -p 5432 -t 30";
      # Enhanced restart behavior for resilience
      Restart = "always";
      RestartSec = "10s";
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };
  };

  # Nginx virtual host for Wallabag
  services.nginx.virtualHosts."wallabag.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/wallabag.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/wallabag.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:9091/";
      extraConfig = ''
        proxy_read_timeout 1h;
        proxy_buffering off;
      '';
    };
  };

  # SOPS secret for Wallabag
  sops.secrets."wallabag-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "wallabag.service" ];
  };

  # State directory for Wallabag
  systemd.tmpfiles.rules = [
    "d /var/lib/wallabag 0755 root root -"
  ];
}