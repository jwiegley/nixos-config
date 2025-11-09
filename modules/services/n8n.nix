{ config, lib, pkgs, ... }:

let
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL password for n8n user
    (mkPostgresUserSetup {
      user = "n8n";
      database = "n8n";
      secretPath = config.sops.secrets."n8n-db-password".path;
      dependentService = "n8n.service";
    })
  ];

  # SOPS secrets for n8n
  # Note: n8n uses DynamicUser, so secrets are owned by root and accessed via LoadCredential
  sops.secrets = {
    "n8n-db-password" = {
      owner = "postgres";  # Postgres setup script needs to read this
      mode = "0440";
    };

    "n8n-encryption-key" = {
      owner = "root";  # DynamicUser will access via systemd LoadCredential
      mode = "0400";
      restartUnits = [ "n8n.service" ];
    };
  };

  # PostgreSQL database and user for n8n
  services.postgresql = {
    ensureDatabases = [ "n8n" ];
    ensureUsers = [
      {
        name = "n8n";
        ensureDBOwnership = true;
      }
    ];
  };

  # Redis instance for n8n (queue and cache)
  users.groups.redis-n8n = {};

  services.redis.servers.n8n = {
    enable = true;
    port = 0; # Unix socket only
    bind = null;
    unixSocket = "/run/redis-n8n/redis.sock";
    unixSocketPerm = 660;
    user = "redis-n8n";
  };

  # n8n service configuration
  services.n8n = {
    enable = true;

    # Webhook URL for external triggers (public Cloudflare Tunnel)
    webhookUrl = "https://n8n.newartisans.com/";

    # Configuration settings
    settings = {
      # Database configuration - PostgreSQL
      database = {
        type = "postgresdb";
        postgresdb = {
          host = "/run/postgresql";
          database = "n8n";
          user = "n8n";
        };
      };

      # Queue mode using Redis for better performance
      executions = {
        mode = "queue";
      };

      # Public URL configuration for editor
      host = "127.0.0.1";
      port = 5678;
      protocol = "http"; # nginx provides SSL termination
      path = "/";

      # Generic timezone
      timezone = "America/Los_Angeles";

      # User management
      userManagement = {
        disabled = false; # Enable user management for multi-user setup
      };

      # Credentials encryption
      # Note: N8N_ENCRYPTION_KEY environment variable is set via systemd

      # Metrics endpoint for Prometheus
      endpoints = {
        metrics = {
          enable = true;
          prefix = "n8n_";
          includeDefaultMetrics = true;
          includeApiEndpoints = true;
          includeMessageEventBusMetrics = true;
          includeWorkflowIdLabel = true;
        };
      };

      # Log configuration
      logs = {
        level = "info";
        output = "console";
      };
    };
  };

  # Ensure n8n starts after PostgreSQL and Redis with proper secret access
  systemd.services.n8n = {
    after = [ "redis-n8n.service" "postgresql-n8n-setup.service" "sops-install-secrets.service" ];
    requires = [ "redis-n8n.service" "postgresql-n8n-setup.service" ];
    wants = [ "sops-install-secrets.service" ];

    serviceConfig = {
      # Add n8n dynamic user to redis-n8n group for socket access
      SupplementaryGroups = [ "redis-n8n" ];

      # Load secrets via systemd LoadCredential (works with DynamicUser)
      LoadCredential = [
        "db-password:${config.sops.secrets."n8n-db-password".path}"
        "encryption-key:${config.sops.secrets."n8n-encryption-key".path}"
      ];

      # Runtime directory for environment file
      RuntimeDirectory = "n8n";
      RuntimeDirectoryMode = "0750";

      # Load environment file with credentials (- prefix makes it optional)
      EnvironmentFile = "-/run/n8n/env";
    };

    # Generate environment file from credentials (runs as root before main service)
    preStart = ''
      # Create environment file with credentials
      cat > /run/n8n/env <<EOF
      DB_POSTGRESDB_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/db-password")
      N8N_ENCRYPTION_KEY=$(cat "$CREDENTIALS_DIRECTORY/encryption-key")
      QUEUE_BULL_REDIS_HOST=/run/redis-n8n/redis.sock
      EXECUTIONS_PROCESS=main
      EOF

      # Set permissions so dynamic user can read it
      chmod 640 /run/n8n/env
    '';
  };

  # n8n nginx upstream with retry logic
  # Prevents 502 errors during service restarts
  services.nginx.upstreams."n8n" = {
    servers = {
      "127.0.0.1:5678" = {
        max_fails = 0;
      };
    };
    extraConfig = ''
      keepalive 16;
      keepalive_timeout 60s;
    '';
  };

  # Nginx virtual host for n8n
  services.nginx.virtualHosts."n8n.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/n8n.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/n8n.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://n8n/";
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Increase timeouts for long-running workflows
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;

        # Buffer settings for large payloads
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 100M;
      '';
    };
  };

  # Open firewall for local network access
  # HTTPS access via nginx on port 443 (already open globally in web.nix)
  networking.firewall.interfaces."end0".allowedTCPPorts = [
    5678 # n8n web interface (for direct local access)
  ];
}
