# OpenProject - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/openproject.nix)
# This file: Redis service, Nginx virtual host, SOPS secrets, PostgreSQL setup, firewall rules, and tmpfiles

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  # Import helper functions
  common = import ../lib/common.nix { inherit secrets; };
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL password for OpenProject user
    (mkPostgresUserSetup {
      user = "openproject";
      database = "openproject";
      secretPath = config.sops.secrets."openproject-db-password".path;
      dependentService = "podman-openproject.service";
    })
  ];

  # Nginx virtual host with WebSocket support
  services.nginx.virtualHosts."openproject.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/openproject.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/openproject.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:8180/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 500M;
        proxy_read_timeout 300s;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        # Note: Standard proxy headers (Host, X-Real-IP, etc.) are automatically
        # included by NixOS nginx module via recommendedProxySettings
      '';
    };

    # Health check location for monitoring
    locations."/health_checks/" = {
      proxyPass = "http://127.0.0.1:8180/health_checks/";
      extraConfig = ''
        proxy_read_timeout 10s;
      '';
    };
  };

  # Add OpenProject to blackbox monitoring
  services.prometheus.scrapeConfigs = [
    # OpenProject Prometheus metrics
    {
      job_name = "openproject";
      static_configs = [
        {
          targets = [ "127.0.0.1:9394" ];
        }
      ];
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
  ];

  # SOPS secrets for OpenProject
  sops.secrets = {
    "openproject-db-password" = {
      sopsFile = config.sops.defaultSopsFile;
      owner = "postgres";
      group = "postgres";
      mode = "0400";
      restartUnits = [ "postgresql.service" ];
    };

    "openproject-secret-key-base" = {
      sopsFile = config.sops.defaultSopsFile;
      owner = "openproject";
      group = "openproject";
      mode = "0400";
      path = "/run/secrets-openproject/openproject-secret-key-base";
      restartUnits = [ "podman-openproject.service" ];
    };

    "openproject-env" = {
      sopsFile = config.sops.defaultSopsFile;
      owner = "openproject";
      group = "openproject";
      mode = "0400";
      path = "/run/secrets-openproject/openproject-env";
      restartUnits = [ "podman-openproject.service" ];
    };
  };

  # tmpfiles rules for state directories
  # NOTE: Using 'd' directive to preserve contents - NEVER use 'D' for persistent data!
  systemd.tmpfiles.rules = [
    "d /var/lib/containers/openproject 0755 openproject openproject -"
    "d /var/lib/containers/openproject/assets 0755 openproject openproject -"
    "d /var/lib/containers/openproject/tmp 0755 openproject openproject -"
    "d /run/secrets-openproject 0755 openproject openproject -"
  ];

  # Redis server for OpenProject cache
  # Rootless containers access via host.containers.internal which resolves to host's network IP
  services.redis.servers.openproject = {
    enable = true;
    port = 6383;
    bind = "0.0.0.0"; # Allow access from container via host.containers.internal
    settings = {
      protected-mode = "no"; # Required for non-localhost access (no auth configured)
      maxmemory = "256mb";
      maxmemory-policy = "allkeys-lru"; # Required for Rails cache - expire old entries
    };
  };

  # Firewall rules for podman network access
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    8180 # OpenProject web
    6383 # Redis for OpenProject
    9394 # OpenProject Prometheus metrics
  ];

  networking.firewall.interfaces."lo".allowedTCPPorts = [
    9394 # OpenProject Prometheus metrics (local scraping)
  ];
}
