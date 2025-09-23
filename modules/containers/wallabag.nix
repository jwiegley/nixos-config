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

  virtualisation.oci-containers.containers.wallabag = {
    autoStart = true;
    image = "wallabag/wallabag:latest";
    ports = [ "127.0.0.1:9090:80/tcp" ];
    environment = containerUser // {
      SYMFONY__ENV__DOMAIN_NAME = "http://wallabag.vulcan.lan";
      POSTGRES_PASSWORD = "bag-1234";
      POSTGRES_USER = "wallabag";
      POPULATE_DATABASE = "False";
      SYMFONY__ENV__DATABASE_DRIVER = "pdo_pgsql";
      SYMFONY__ENV__DATABASE_HOST = "host.containers.internal";
      SYMFONY__ENV__DATABASE_PORT = "5432";
      SYMFONY__ENV__DATABASE_NAME = "wallabag";
      SYMFONY__ENV__DATABASE_USER = "wallabag";
      SYMFONY__ENV__DATABASE_PASSWORD = "bag-1234";
      SYMFONY__ENV__MAILER_DSN = "smtp://host.containers.internal";
      SYMFONY__ENV__FROM_EMAIL = "johnw@newartisans.com";
      SYMFONY__ENV__SERVER_NAME = "Vulcan";
      SYMFONY__ENV__REDIS_HOST = "host.containers.internal";
      SYMFONY__ENV__FOSUSER_REGISTRATION = "True";
      SYMFONY__ENV__FOSUSER_CONFIRMATION = "False";
    };
    volumes = [
      "/var/lib/wallabag/data:/var/www/wallabag/data"
      "/var/lib/wallabag/images:/var/www/wallabag/web/assets/images"
    ];
  };
}
