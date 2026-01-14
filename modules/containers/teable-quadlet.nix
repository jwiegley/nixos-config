# Teable - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/teable.nix)
# This file: Nginx virtual host, SOPS secrets, firewall rules, and tmpfiles

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/teable.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "teable";
  #     image = "ghcr.io/teableio/teable-community:latest";
  #     port = 3001;
  #     requiresPostgres = true;
  #     containerUser = "teable";
  #     ...
  #   })
  # ];

  # Nginx virtual host
  services.nginx.virtualHosts."teable.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/teable.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/teable.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:3004/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
        proxy_read_timeout 5m;
        proxy_connect_timeout 5m;
        proxy_send_timeout 5m;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  # SOPS secrets
  sops.secrets."teable-env" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "teable";
    path = "/run/secrets-teable/teable-env";
  };

  # Additional SOPS secret for PostgreSQL user setup
  sops.secrets."teable-postgres-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "postgres";
    restartUnits = [ "postgresql-teable-setup.service" ];
  };

  # Firewall rules
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    3001 # teable
  ];

  # tmpfiles rules
  systemd.tmpfiles.rules = [
    "d /var/lib/teable 0755 root root -"
  ];
}
