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
      containerUser = "sillytavern";  # Run rootless as dedicated sillytavern user

      # Disabled - Podman healthchecks cause cgroup permission errors with rootless containers
      # External monitoring via Prometheus/blackbox exporter is used instead
      healthCheck = {
        enable = false;
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

      # Rootless container directories owned by sillytavern
      tmpfilesRules = [
        "d /var/lib/silly-tavern 0755 sillytavern sillytavern -"
        "d /var/lib/silly-tavern/config 0755 sillytavern sillytavern -"
        "d /var/lib/silly-tavern/data 0755 sillytavern sillytavern -"
      ];
    })
  ];
}
