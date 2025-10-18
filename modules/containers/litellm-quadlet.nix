{ config, lib, pkgs, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "litellm";
      image = "ghcr.io/berriai/litellm-database:main-stable";
      port = 4000;
      requiresPostgres = true;

      # Bind to both localhost and podman gateway for container access
      publishPorts = [
        "127.0.0.1:4000:4000/tcp"
        "10.88.0.1:4000:4000/tcp"
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
        "d /etc/litellm 0755 root root -"
      ];
    })
  ];

  # Redis server for litellm
  services.redis.servers.litellm = {
    enable = true;
    port = 8085;
    bind = "10.88.0.1";
    settings = {
      protected-mode = "no";
    };
  };

  # Ensure redis-litellm waits for podman network
  systemd.services.redis-litellm = {
    after = [ "sys-subsystem-net-devices-podman0.device" "podman.service" ];
    bindsTo = [ "sys-subsystem-net-devices-podman0.device" ];
  };

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    4000 # litellm
    8085 # redis[litellm]
  ];
}
