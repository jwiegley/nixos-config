{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "wallabag";
      image = "docker.io/wallabag/wallabag:latest";
      port = 9091;
      requiresPostgres = true;

      # Enable health checks
      healthCheck = {
        enable = true;
        type = "http";
        interval = "30s";
        timeout = "10s";
        startPeriod = "60s";
        retries = 3;
        httpPath = "/";
        httpPort = 80;  # Internal container port
      };
      enableWatchdog = false;  # Disabled - requires sdnotify

      secrets = {
        wallabagPassword = "wallabag-secrets";
      };

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

      publishPorts = [ "127.0.0.1:9091:80/tcp" ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:9091/";
        extraConfig = ''
          proxy_read_timeout 1h;
          proxy_buffering off;
        '';
      };
    })
  ];
}
