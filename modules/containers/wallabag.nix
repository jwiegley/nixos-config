{ config, lib, pkgs, ... }:

let
  containerUser = {
    PUID = "1010";
    PGID = "1010";
  };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/wallabag 0755 container-data container-data -"
    "d /var/lib/wallabag/data 0755 container-data container-data -"
    "d /var/lib/wallabag/images 0755 container-data container-data -"
  ];

  # SOPS secret configuration for Wallabag passwords
  sops.secrets."wallabag-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "podman-wallabag.service" ];
  };

  virtualisation.oci-containers.containers.wallabag = {
    autoStart = true;
    image = "wallabag/wallabag:latest";
    ports = [ "127.0.0.1:9090:80/tcp" ];

    # Non-secret environment variables
    environment = containerUser // {
      SYMFONY__ENV__DOMAIN_NAME = "http://wallabag.vulcan.lan";
      POSTGRES_USER = "wallabag";
      POPULATE_DATABASE = "False";
      SYMFONY__ENV__DATABASE_DRIVER = "pdo_pgsql";
      SYMFONY__ENV__DATABASE_HOST = "host.containers.internal";
      SYMFONY__ENV__DATABASE_PORT = "5432";
      SYMFONY__ENV__DATABASE_NAME = "wallabag";
      SYMFONY__ENV__DATABASE_USER = "wallabag";
      # Passwords removed - now provided via SOPS
      SYMFONY__ENV__MAILER_DSN = "smtp://host.containers.internal";
      SYMFONY__ENV__FROM_EMAIL = "johnw@newartisans.com";
      SYMFONY__ENV__SERVER_NAME = "Vulcan";
      SYMFONY__ENV__REDIS_HOST = "host.containers.internal";
      SYMFONY__ENV__FOSUSER_REGISTRATION = "True";
      SYMFONY__ENV__FOSUSER_CONFIRMATION = "False";
    };

    # Secret environment variables from SOPS
    environmentFiles = [
      config.sops.secrets."wallabag-secrets".path
    ];

    volumes = [
      "/var/lib/wallabag/data:/var/www/wallabag/data"
      "/var/lib/wallabag/images:/var/www/wallabag/web/assets/images"
    ];
  };

  # Ensure proper systemd dependencies
  systemd.services."podman-wallabag" = {
    after = [ "sops-nix.service" "postgresql.service" ];
    wants = [ "sops-nix.service" ];
  };
}
