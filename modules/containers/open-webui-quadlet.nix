# Open WebUI - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/open-webui.nix)
# This file: Nginx virtual host, SOPS secrets, firewall rules, and tmpfiles

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  common = import ../lib/common.nix { inherit secrets; };
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL password for open_webui user
    (mkPostgresUserSetup {
      user = "open_webui";
      database = "open_webui";
      secretPath = config.sops.secrets."open-webui-db-password".path;
      dependentService = "podman-open-webui.service";
    })
  ];

  # Nginx virtual host
  services.nginx.virtualHosts."chat.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/chat.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/chat.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8084/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
        proxy_read_timeout 2h;
        proxy_connect_timeout 60s;
        proxy_send_timeout 2h;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };
  };

  # SOPS secrets
  sops.secrets."open-webui-secrets" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "open-webui";
    path = "/run/secrets-open-webui/open-webui-secrets";
  };

  sops.secrets."open-webui-db-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "open-webui";
  };

  # tmpfiles rules - use 'd' directive (preserves contents) for persistent data
  systemd.tmpfiles.rules = [
    "d /var/lib/containers/open-webui/data 0755 open-webui open-webui -"
  ];

  # No firewall rules needed - using host networking mode
}
