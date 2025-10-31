{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "litellm";
      image = "ghcr.io/berriai/litellm-database:main-stable";
      port = 4000;
      requiresPostgres = true;
      containerUser = "container-db";  # Run rootless as container-db user

      # Health check disabled - /health endpoint requires API authentication
      healthCheck = {
        enable = false;
      };
      enableWatchdog = false;

      # Rootless container - bind to localhost only
      publishPorts = [
        "127.0.0.1:4000:4000/tcp"
      ];

      secrets = {
        litellmApiKey = "litellm-secrets";
      };

      volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
      exec = "--config /app/config.yaml";

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:4000/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 20M;
          proxy_read_timeout 2h;
        '';
      };

      tmpfilesRules = [
        "d /etc/litellm 0755 container-db container-db -"
      ];
    })
  ];

  # Redis server for litellm (rootless container access via localhost)
  services.redis.servers.litellm = {
    enable = true;
    port = 8085;
    bind = "127.0.0.1";  # Rootless containers access via host.containers.internal → 127.0.0.1
    settings = {
      protected-mode = "yes";  # Re-enable since only localhost
    };
  };

  # Redis binds to localhost only - no podman network dependency needed

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    4000 # litellm
    8085 # redis[litellm]
  ];
}
