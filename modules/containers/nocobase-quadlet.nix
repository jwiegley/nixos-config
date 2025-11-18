# NocoBase - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/nocobase.nix)
# This file: Nginx virtual host, SOPS secrets, firewall rules, and tmpfiles

{ config, lib, pkgs, secrets, ... }:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/nocobase.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "nocobase";
  #     image = "docker.io/nocobase/nocobase:latest";
  #     port = 13000;
  #     requiresPostgres = true;
  #     containerUser = "nocobase";
  #     ...
  #   })
  # ];

  # Nginx virtual host
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
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };

  # SOPS secrets
  sops.secrets."nocobase-secrets" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "nocobase";
    path = "/run/secrets-nocobase/nocobase-secrets";
  };

  # Additional SOPS secret for PostgreSQL user setup
  sops.secrets."nocobase-db-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "postgres";
    restartUnits = [ "postgresql-nocobase-setup.service" ];
  };

  # Firewall rules for podman0 interface
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    13000  # nocobase
  ];

  # tmpfiles rules
  systemd.tmpfiles.rules = [
    # Create directory with proper ownership
    "d /var/lib/nocobase 0755 nocobase nocobase -"
    # Recursively fix ownership of existing files (Z = recursive ownership/mode fix)
    "Z /var/lib/nocobase 0755 nocobase nocobase -"
  ];
}
