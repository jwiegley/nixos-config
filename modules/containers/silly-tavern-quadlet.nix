{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "silly-tavern";
      image = "ghcr.io/sillytavern/sillytavern:latest";
      port = 8083;
      requiresPostgres = false;

      # Enable health checks
      healthCheck = {
        enable = true;
        type = "exec";
        interval = "30s";
        timeout = "10s";
        startPeriod = "30s";
        retries = 3;
        execCommand = "wget --spider -q http://127.0.0.1:8000/ || exit 1";
      };
      enableWatchdog = false;  # Disabled - requires sdnotify

      publishPorts = [ "127.0.0.1:8083:8000/tcp" ];

      environments = {
        USER_PASSWORD = "";
        AUTO_UPDATE = "false";
      };

      volumes = [
        "/var/lib/silly-tavern/config:/home/node/app/config:Z"
        "/var/lib/silly-tavern/data:/home/node/app/data:Z"
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:8083/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 100M;
        '';
      };

      # Custom tmpfiles with specific UID/GID for container user
      tmpfilesRules = [
        "d /var/lib/silly-tavern/config 0755 1000 100 -"
        "d /var/lib/silly-tavern/data 0755 1000 100 -"
      ];
    })
  ];
}
