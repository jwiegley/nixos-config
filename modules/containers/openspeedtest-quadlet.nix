# OpenSpeedTest - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/openspeedtest.nix)
# This file: Nginx virtual host (hostname: speedtest.vulcan.lan)

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/openspeedtest.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "speedtest";
  #     image = "docker.io/openspeedtest/latest:latest";
  #     port = 3002;
  #     requiresPostgres = false;
  #     containerUser = "openspeedtest";
  #     ...
  #   })
  # ];

  # Nginx virtual host (using "speedtest" as service name for hostname)
  services.nginx.virtualHosts."speedtest.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/speedtest.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/speedtest.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:3002/";
      extraConfig = ''
        # OpenSpeedTest requires these settings for accurate speed measurements
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;

        # Client body size for upload tests (35MB as per OpenSpeedTest requirements)
        client_max_body_size 35M;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };
}
