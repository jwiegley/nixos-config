# Wallabag - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/wallabag.nix)
# This file: Nginx virtual host and SOPS secrets

{ config, lib, pkgs, secrets, ... }:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/wallabag.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "wallabag";
  #     image = "docker.io/wallabag/wallabag:latest";
  #     port = 9091;
  #     requiresPostgres = true;
  #     containerUser = "wallabag";
  #     ...
  #   })
  # ];

  # Nginx virtual host
  services.nginx.virtualHosts."wallabag.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/wallabag.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/wallabag.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:9091/";
      extraConfig = ''
        proxy_read_timeout 1h;
        proxy_buffering off;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };

  # SOPS secrets
  sops.secrets."wallabag-secrets" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "wallabag";
    path = "/run/secrets-wallabag/wallabag-secrets";
  };
}
