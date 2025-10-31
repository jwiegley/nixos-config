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

      # Health check disabled - /health endpoint requires API authentication
      healthCheck = {
        enable = false;
      };
      enableWatchdog = false;

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

  # Ensure redis-litellm waits for podman network to be ready
  systemd.services.redis-litellm = {
    after = [ "network-online.target" "podman.service" ];
    wants = [ "network-online.target" ];
    # Remove hard binding to podman0 device to prevent dependency failures

    # Wait for podman network to be ready before starting
    preStart = ''
      # Wait for podman0 interface to be up (up to 30 seconds)
      for i in {1..30}; do
        if ${pkgs.iproute2}/bin/ip link show podman0 >/dev/null 2>&1; then
          if ${pkgs.iproute2}/bin/ip addr show podman0 | ${pkgs.gnugrep}/bin/grep -q "10.88.0.1"; then
            echo "Podman network is ready"
            break
          fi
        fi
        echo "Waiting for podman network to be ready... ($i/30)"
        sleep 1
      done
    '';
  };

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    4000 # litellm
    8085 # redis[litellm]
  ];
}
