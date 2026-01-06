# Shlink URL Shortener - System Configuration
#
# Quadlet containers: Managed by Home Manager
#   - Shlink API: /etc/nixos/modules/users/home-manager/shlink.nix
#   - Shlink Web Client: /etc/nixos/modules/users/home-manager/shlink-web-client.nix
#
# This file: Redis service, Nginx virtual hosts, SOPS secrets, firewall rules
#
# Access:
#   - Web Client (UI): https://shlink.vulcan.lan
#   - API (internal): https://shlink-api.vulcan.lan
#   - API (external): https://s.newartisans.com (via Cloudflare Tunnel)
#
# Database: PostgreSQL (shlink database, shlink user) - configured in databases.nix
# Cache: Redis on port 6385

{ config, lib, pkgs, secrets, ... }:

{
  # ============================================================================
  # CLI Tools for managing Shlink
  # ============================================================================

  environment.systemPackages = [
    # Main shlink CLI wrapper - runs commands inside the container
    (pkgs.writeScriptBin "shlink" ''
      #!${pkgs.bash}/bin/bash
      # Shlink CLI wrapper - executes commands in the shlink container
      # Usage: shlink <command> [args...]
      # Examples:
      #   shlink short-url:create <url>  # Create a new short URL
      #   shlink short-url:list          # List all short URLs
      #   shlink api-key:generate        # Generate a new API key
      #   shlink list                    # Show all available commands
      #   shlink --help                  # Show help

      if [ $# -eq 0 ]; then
        echo "Shlink CLI - URL Shortener"
        echo ""
        echo "Usage: shlink <command> [args...]"
        echo ""
        echo "Common commands:"
        echo "  short-url:create <url>  Create a new short URL"
        echo "  short-url:list          List all short URLs"
        echo "  short-url:delete        Delete a short URL"
        echo "  api-key:generate        Generate a new API key"
        echo "  api-key:list            List all API keys"
        echo "  short-url:visits        List visits for a short URL"
        echo "  list                    Show all available commands"
        echo ""
        echo "Run 'shlink <command> --help' for command-specific help"
        exit 0
      fi

      cd /tmp
      exec sudo -u shlink ${pkgs.podman}/bin/podman exec -it shlink /usr/local/bin/shlink "$@"
    '')

    # Convenience script to create a short URL quickly
    (pkgs.writeScriptBin "shlink-shorten" ''
      #!${pkgs.bash}/bin/bash
      # Quick shortcut to create a short URL
      # Usage: shlink-shorten <long-url> [custom-slug]

      if [ $# -eq 0 ]; then
        echo "Usage: shlink-shorten <long-url> [custom-slug]"
        echo ""
        echo "Examples:"
        echo "  shlink-shorten https://example.com/very/long/url"
        echo "  shlink-shorten https://example.com/page my-slug"
        exit 1
      fi

      LONG_URL="$1"
      CUSTOM_SLUG="$2"

      cd /tmp
      if [ -n "$CUSTOM_SLUG" ]; then
        exec sudo -u shlink ${pkgs.podman}/bin/podman exec shlink /usr/local/bin/shlink short-url:create "$LONG_URL" --custom-slug "$CUSTOM_SLUG"
      else
        exec sudo -u shlink ${pkgs.podman}/bin/podman exec shlink /usr/local/bin/shlink short-url:create "$LONG_URL"
      fi
    '')

    # List all short URLs
    (pkgs.writeScriptBin "shlink-list" ''
      #!${pkgs.bash}/bin/bash
      # List all short URLs
      cd /tmp
      exec sudo -u shlink ${pkgs.podman}/bin/podman exec shlink /usr/local/bin/shlink short-url:list "$@"
    '')
  ];

  # ============================================================================
  # SOPS Secrets
  # ============================================================================

  sops.secrets = {
    # Database password for PostgreSQL
    "shlink-db-password" = {
      sopsFile = config.sops.defaultSopsFile;
      owner = "postgres";
      group = "postgres";
      mode = "0400";
    };

    # Shlink API secrets (database password in env format) - deployed to container user's secrets dir
    "shlink-secrets" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "shlink";
      path = "/run/secrets-shlink/shlink-secrets";
      restartUnits = [ "podman-shlink.service" ];
    };

    # Shlink Web Client secrets (API URL and key) - deployed to web client container user's secrets dir
    "shlink-web-client" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "shlink-web-client";
      path = "/run/secrets-shlink-web-client/shlink-web-client";
      restartUnits = [ "podman-shlink-web-client.service" ];
    };
  };

  # ============================================================================
  # Redis Server for Shlink
  # ============================================================================

  services.redis.servers.shlink = {
    enable = true;
    port = 6385;
    # Bind to all interfaces so rootless containers can access via host.containers.internal
    # Similar to PostgreSQL which also binds to 0.0.0.0
    bind = null;  # null means bind to all interfaces
    settings = {
      protected-mode = "no";  # Disabled since we use firewall rules for access control
      maxmemory = "128mb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # ============================================================================
  # Nginx Virtual Hosts
  # ============================================================================

  # Shlink Web Client - the management UI
  # This is the main user-facing interface for managing short URLs
  services.nginx.virtualHosts."shlink.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/shlink.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/shlink.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8581/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 10M;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_connect_timeout 30s;
      '';
    };
  };

  # Shlink API - internal access for the web client and other integrations
  # Note: Shlink handles CORS internally (Access-Control-Allow-Origin: *), no need for nginx CORS config
  services.nginx.virtualHosts."shlink-api.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/shlink-api.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/shlink-api.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8580/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 10M;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_connect_timeout 30s;
      '';
    };
  };

  # ============================================================================
  # Firewall Rules
  # ============================================================================

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    8580  # shlink API
    8581  # shlink web client
    6385  # redis[shlink]
  ];

  # Note: User secrets directories (/run/secrets-shlink, /run/secrets-shlink-web-client) are created by
  # modules/users/container-users-dedicated.nix along with the symlinks to /run/secrets/
}
