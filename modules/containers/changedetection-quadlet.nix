# ChangeDetection.io - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/changedetection.nix)
# This file: Nginx virtual host, SOPS secrets, and tmpfiles

{ config, lib, pkgs, secrets, ... }:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/changedetection.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "changedetection";
  #     image = "ghcr.io/dgtlmoon/changedetection.io:latest";
  #     port = 5000;
  #     containerUser = "changedetection";
  #     ...
  #   })
  # ];

  # Nginx virtual host using "changes.vulcan.lan" instead of "changedetection.vulcan.lan"
  services.nginx.virtualHosts."changes.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/changes.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/changes.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:5055/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
      '';
    };
  };

  # SOPS secrets
  sops.secrets."changedetection/api-key" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "changedetection";
  };

  # Ensure data directory has correct ownership for container data
  # Home directory (/var/lib/containers/changedetection) is managed by home-manager
  systemd.tmpfiles.rules = [
    "d /var/lib/changedetection 0755 changedetection changedetection -"
  ];
}
