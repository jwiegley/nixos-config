{ config, lib, pkgs, ... }:

{
  # LiteLLM container configuration
  virtualisation.quadlet.containers.litellm = {
    containerConfig = {
      image = "ghcr.io/berriai/litellm-database:main-stable";
      # Bind to both localhost and podman gateway for container access
      publishPorts = [
        "127.0.0.1:4000:4000/tcp"
        "10.88.0.1:4000:4000/tcp"
      ];
      environmentFiles = [ config.sops.secrets."litellm-secrets".path ];
      volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
      exec = "--config /app/config.yaml";
      networks = [ "podman" ];
    };
    unitConfig = {
      After = [ "sops-nix.service" "postgresql.service" "ensure-podman-network.service" "podman.service" ];
      Wants = [ "sops-nix.service" "ensure-podman-network.service" ];
      Requires = [ "postgresql.service" ];
      BindsTo = [ "postgresql.service" ];
    };
    serviceConfig = {
      # Wait for PostgreSQL to be ready to accept connections
      ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 10.88.0.1 -p 5432 -t 30";
    };
  };

  # Nginx virtual host for LiteLLM
  services.nginx.virtualHosts."litellm.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/litellm.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/litellm.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:4000/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 20M;
        proxy_read_timeout 2h;
      '';
    };
  };

  # Redis server for litellm
  services.redis.servers.litellm = {
    enable = true;
    port = 8085;
    bind = "127.0.0.1";
    settings = {
      protected-mode = "no";
    };
  };

  # SOPS secret for LiteLLM
  sops.secrets."litellm-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "litellm.service" ];
  };

  # State directory for LiteLLM config
  systemd.tmpfiles.rules = [
    "d /etc/litellm 0755 root root -"
  ];

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    4000 # litellm
    8085 # redis[litellm]
  ];
}
