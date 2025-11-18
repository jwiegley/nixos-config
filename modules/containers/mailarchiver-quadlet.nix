# Mail Archiver - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/mailarchiver.nix)
# This file: Nginx virtual host, SOPS secrets, firewall rules, and tmpfiles
#
# Mail Archiver - Email Archiving and Search Platform
# ====================================================
# Mail-archiver is an open-source web application for archiving, searching,
# and exporting emails from multiple accounts.
#
# Features:
# - Automatic email archiving with scheduled synchronization
# - Advanced search with filtering capabilities
# - Export emails as mbox files or zipped EML archives
# - Import emails from other sources
# - Retention policy management
# - Support for IMAP and Microsoft Graph API (M365)
#
# Access: https://mailarchiver.vulcan.lan

{ config, lib, pkgs, secrets, ... }:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/mailarchiver.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "mailarchiver";
  #     image = "docker.io/s1t5/mailarchiver:latest";
  #     port = 9097;
  #     requiresPostgres = true;
  #     containerUser = "mailarchiver";
  #     ...
  #   })
  # ];

  # Nginx virtual host
  services.nginx.virtualHosts."mailarchiver.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/mailarchiver.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/mailarchiver.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:9097/";
      extraConfig = ''
        # Mail archiver can handle large email attachments
        proxy_buffering off;
        client_max_body_size 500M;
        proxy_read_timeout 10m;
        proxy_connect_timeout 2m;
        proxy_send_timeout 10m;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };

  # SOPS secrets
  # The mailarchiver-env file should contain (in KEY=VALUE format):
  #   ConnectionStrings__DefaultConnection=Host=10.88.0.1;Port=5432;Database=mailarchiver;Username=mailarchiver;Password=<db-password>
  #   Authentication__Username=<admin-username>
  #   Authentication__Password=<admin-password>
  sops.secrets."mailarchiver-env" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "mailarchiver";
    path = "/run/secrets-mailarchiver/mailarchiver-env";
  };

  # Additional SOPS secret for PostgreSQL user setup
  sops.secrets."mailarchiver-db-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # Firewall rules
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    9097  # mailarchiver
  ];

  # tmpfiles rules
  systemd.tmpfiles.rules = [
    "d /var/lib/mailarchiver 0755 mailarchiver mailarchiver -"
    "d /var/lib/mailarchiver/.config 0700 mailarchiver mailarchiver -"
    "d /var/lib/mailarchiver/.local 0755 mailarchiver mailarchiver -"
    "d /var/lib/mailarchiver/storage 0755 mailarchiver mailarchiver -"
    "d /var/lib/mailarchiver/logs 0755 mailarchiver mailarchiver -"
  ];
}
