{ config, lib, pkgs, secrets, ... }:

# SillyTavern - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/sillytavern.nix)
# This file: Nginx virtual host and tmpfiles rules for persistent data

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/sillytavern.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "silly-tavern";
  #     image = "ghcr.io/sillytavern/sillytavern:latest";
  #     port = 8083;
  #     containerUser = "sillytavern";
  #     ...
  #   })
  # ];

  # Nginx virtual host configuration
  services.nginx.virtualHosts."silly-tavern.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/silly-tavern.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/silly-tavern.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8083/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };

  # Persistent data directories (owned by sillytavern user)
  systemd.tmpfiles.rules = [
    "d /var/lib/silly-tavern 0755 sillytavern sillytavern -"
    "d /var/lib/silly-tavern/config 0755 sillytavern sillytavern -"
    "d /var/lib/silly-tavern/data 0755 sillytavern sillytavern -"
  ];
}
