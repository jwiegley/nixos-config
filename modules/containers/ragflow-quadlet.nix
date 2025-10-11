{ config, lib, pkgs, ... }:

{
  # Redis server for RAGFlow
  services.redis.servers.ragflow = {
    enable = true;
    port = 6379;
    bind = "10.88.0.1";
    settings = {
      protected-mode = "no";
      maxmemory = "512mb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # RAGFlow container configuration
  virtualisation.quadlet.containers.ragflow = {
    containerConfig = {
      image = "docker.io/infiniflow/ragflow:latest-full";

      # Bind to both localhost and podman gateway for container access
      # Port 80 inside container runs nginx which serves frontend and proxies to backend
      publishPorts = [
        "127.0.0.1:9380:80/tcp"
        "10.88.0.1:9380:80/tcp"
      ];

      environmentFiles = [ config.sops.secrets."ragflow-secrets".path ];

      volumes = [
        "/etc/ragflow/conf:/ragflow/conf"
        "/var/lib/ragflow:/ragflow/data"
        "/etc/ragflow/patches/db_models.py:/ragflow/api/db/db_models.py:ro"
        "/etc/ragflow/nginx/ragflow.conf:/etc/nginx/sites-enabled/default:ro"
      ];

      networks = [ "podman" ];

      # Use host DNS via Podman gateway for .lan domain resolution
      dns = [ "10.88.0.1" ];
    };

    unitConfig = {
      After = [
        "sops-nix.service"
        "postgresql.service"
        "postgresql-ragflow-setup.service"
        "elasticsearch.service"
        "minio.service"
        "minio-ragflow-setup.service"
        "redis-ragflow.service"
        "podman.service"
      ];
      Wants = [ "sops-nix.service" ];
      Requires = [
        "postgresql.service"
        "elasticsearch.service"
        "minio.service"
        "redis-ragflow.service"
      ];
      BindsTo = [
        "postgresql.service"
        "elasticsearch.service"
        "minio.service"
      ];
    };

    serviceConfig = {
      # Wait for all services to be ready
      ExecStartPre = [
        # Wait for PostgreSQL
        "${pkgs.postgresql}/bin/pg_isready -h 10.88.0.1 -p 5432 -U ragflow -d ragflow -t 30"
        # Wait for Elasticsearch
        "${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl -s http://10.88.0.1:9200/_cluster/health > /dev/null 2>&1; do echo Waiting for Elasticsearch...; sleep 2; done'"
        # Wait for MinIO
        "${pkgs.bash}/bin/bash -c 'until ${pkgs.curl}/bin/curl -s http://10.88.0.1:9000/minio/health/live > /dev/null 2>&1; do echo Waiting for MinIO...; sleep 2; done'"
        # Wait for Redis
        "${pkgs.bash}/bin/bash -c 'until ${pkgs.redis}/bin/redis-cli -h 10.88.0.1 -p 6379 ping > /dev/null 2>&1; do echo Waiting for Redis...; sleep 2; done'"
      ];
    };
  };

  # Nginx virtual host for RAGFlow (co-located with container config)
  services.nginx.virtualHosts."ragflow.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/ragflow.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/ragflow.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:9380/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 300s;
      '';
    };
  };

  # SOPS secret for RAGFlow environment variables
  sops.secrets."ragflow-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "ragflow.service" ];
  };

  # State directories for RAGFlow
  # Configuration files are pre-populated in /etc/ragflow/conf/ and mounted into container
  systemd.tmpfiles.rules = [
    "d /etc/ragflow/conf 0755 root root -"
    "d /etc/ragflow/patches 0755 root root -"
    "d /etc/ragflow/nginx 0755 root root -"
    "d /var/lib/ragflow 0755 root root -"
  ];

  # Firewall rules for podman0 interface
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    6379  # redis[ragflow]
    9380  # ragflow
  ];
}
