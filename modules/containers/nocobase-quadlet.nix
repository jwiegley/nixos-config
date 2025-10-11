{ config, lib, pkgs, ... }:

{
  # NocoBase container configuration
  virtualisation.quadlet.containers.nocobase = {
    containerConfig = {
      image = "docker.io/nocobase/nocobase:latest";

      # Bind to both localhost and podman gateway for container access
      publishPorts = [
        "127.0.0.1:13000:80/tcp"
        "10.88.0.1:13000:80/tcp"
      ];

      environmentFiles = [ config.sops.secrets."nocobase-secrets".path ];

      volumes = [
        "/var/lib/nocobase:/nocobase/storage"
      ];

      networks = [ "podman" ];

      # Use host DNS via Podman gateway for .lan domain resolution
      dns = [ "10.88.0.1" ];
    };

    unitConfig = {
      After = [
        "sops-nix.service"
        "postgresql.service"
        "postgresql-nocobase-setup.service"
        "podman.service"
      ];
      Wants = [ "sops-nix.service" ];
      Requires = [
        "postgresql.service"
      ];
    };

    serviceConfig = {
      # Wait for PostgreSQL to be ready
      ExecStartPre = [
        # Wait for PostgreSQL
        "${pkgs.postgresql}/bin/pg_isready -h 10.88.0.1 -p 5432 -U nocobase -d nocobase -t 30"
      ];
      # Enhanced restart behavior for resilience
      Restart = "always";
      RestartSec = "10s";
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };
  };

  # Nginx virtual host for NocoBase
  services.nginx.virtualHosts."nocobase.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/nocobase.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/nocobase.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:13000/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_connect_timeout 60s;
      '';
    };
  };

  # SOPS secret for NocoBase environment variables
  sops.secrets."nocobase-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "nocobase.service" ];
  };

  # State directories for NocoBase
  systemd.tmpfiles.rules = [
    "d /var/lib/nocobase 0755 root root -"
  ];

  # Firewall rules for podman0 interface
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    13000  # nocobase
  ];
}
