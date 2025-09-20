{ config, lib, pkgs, ... }:

let
  # Common container user settings
  containerUser = {
    PUID = "1010";
    PGID = "1010";
  };

  # Common volume base paths
  volumeBase = path: [
    "${path}/config:/config"
    "${path}/data:/data"
  ];
in
{
  systemd.tmpfiles.rules = [
    # Wallabag
    "d /var/lib/wallabag 0755 container-data container-data -"
    "d /var/lib/wallabag/data 0755 container-data container-data -"
    "d /var/lib/wallabag/images 0755 container-data container-data -"

    # SillyTavern
    "d /var/lib/silly-tavern 0755 container-data container-data -"
    "d /var/lib/silly-tavern/config 0755 container-data container-data -"
    "d /var/lib/silly-tavern/data 0755 container-data container-data -"
    "d /var/lib/silly-tavern/plugins 0755 container-data container-data -"
    "d /var/lib/silly-tavern/extensions 0755 container-data container-data -"

    # Organizr
    "d /var/lib/organizr 0755 container-data container-data -"
  ];

  virtualisation = {
    podman = {
      enable = true;
      autoPrune = {
        enable = true;
        flags = [ "--all" ];
      };
    };

    oci-containers.containers = {
      litellm = {
        autoStart = true;
        image = "ghcr.io/berriai/litellm-database:main-stable";
        ports = [ "127.0.0.1:4000:4000/tcp" ];
        environment = {
          LITELLM_MASTER_KEY = "sk-1234";
          DATABASE_URL = "postgresql://litellm:sk-1234@host.containers.internal:5432/litellm";
          # REDIS_HOST = "localhost";
          # REDIS_PORT = "8085" ;
          # REDIS_PASSWORD = "sk-1234";
        };
        volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
        cmd = [
          "--config" "/app/config.yaml"
          # "--detailed_debug"
        ];
      };

      silly-tavern = {
        autoStart = true;
        image = "ghcr.io/sillytavern/sillytavern:latest";
        ports = [ "127.0.0.1:8083:8000/tcp" ];
        environment = {
          NODE_ENV = "production";
          FORCE_COLOR = "1";
        };
        volumes = [
          "/var/lib/silly-tavern/config:/home/node/app/config"
          "/var/lib/silly-tavern/data:/home/node/app/data"
          "/var/lib/silly-tavern/plugins:/home/node/app/plugins"
          "/var/lib/silly-tavern/extensions:/home/node/app/public/scripts/extensions/third-party"
        ];
      };

      organizr = {
        autoStart = true;
        image = "ghcr.io/organizr/organizr:latest";
        ports = [ "127.0.0.1:8080:80/tcp" ];
        environment = containerUser;
        volumes = [ "/var/lib/organizr:/config" ];
      };

      wallabag = {
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
    };
  };
}
