# Letta - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/letta.nix)
# This file: Nginx virtual host, SOPS secrets, firewall rules, Redis, and tmpfiles
#
# External services used:
# - PostgreSQL: letta database on localhost:5432
# - Redis: dedicated instance on localhost:6384

{ config, lib, pkgs, secrets, ... }:

let
  common = import ../lib/common.nix { inherit secrets; };
in
{
  # ============================================================================
  # Redis Server for Letta
  # ============================================================================

  services.redis.servers.letta = {
    enable = true;
    port = 6384;
    # Bind to all interfaces so rootless containers can access via host.containers.internal
    bind = null;
    settings = {
      protected-mode = "no";  # Required for non-localhost access (no auth configured)
      maxmemory = "256mb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # ============================================================================
  # Nginx Virtual Host
  # ============================================================================

  # Nginx virtual host
  services.nginx.virtualHosts."letta.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/letta.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/letta.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8283/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
        proxy_read_timeout 5m;
        proxy_connect_timeout 5m;
        proxy_send_timeout 5m;
      '';
    };
  };

  # SOPS secrets for Letta container environment
  # Note: Cannot use restartUnits for rootless user-level services
  # The letta.service runs under user@923.service, not as a system service
  # Manually restart with: sudo -u letta XDG_RUNTIME_DIR=/run/user/923 systemctl --user restart letta.service
  sops.secrets."letta-secrets" = {
    sopsFile = common.secretsPath;
    mode = "0400";
    owner = "letta";
    path = "/run/secrets-letta/letta-secrets";
  };

  # PostgreSQL password for database setup
  sops.secrets."letta-db-password" = {
    sopsFile = common.secretsPath;
    mode = "0400";
    owner = "postgres";
    restartUnits = [ "postgresql-letta-setup.service" ];
  };

  # tmpfiles rules for persistent data
  # Using 'd' directive to create directory if it doesn't exist (preserves contents)
  systemd.tmpfiles.rules = [
    "d /var/lib/letta 0755 letta letta -"
  ];

  # Firewall rules for podman0 interface
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    8283  # letta
  ];
}
