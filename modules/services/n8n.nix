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

    # Configuration via environment variables (new format after nixpkgs update)
    environment = {
      # Webhook URL for external triggers (public Cloudflare Tunnel)
      # WEBHOOK_URL = "https://n8n.newartisans.com/";
      WEBHOOK_URL = "https://n8n.vulcan.lan/";
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS = "true";

      # Allow access from local network clients
      N8N_ALLOWED_ORIGINS = "https://n8n.vulcan.lan,http://192.168.1.2:5678";
      N8N_PROXY_HOPS = "1";

      # Database configuration - PostgreSQL
      DB_TYPE = "postgresdb";
      DB_POSTGRESDB_HOST = "/run/postgresql";
      DB_POSTGRESDB_DATABASE = "n8n";
      DB_POSTGRESDB_USER = "n8n";
      # DB_POSTGRESDB_PASSWORD is set via EnvironmentFile from SOPS secret

      # Queue mode using Redis for better performance
      EXECUTIONS_MODE = "queue";
      # QUEUE_BULL_REDIS_HOST and EXECUTIONS_PROCESS are set via EnvironmentFile

      # Public URL configuration for editor
      N8N_HOST = "127.0.0.1";
      N8N_PORT = "5678";
      N8N_PROTOCOL = "http"; # nginx provides SSL termination
      N8N_PATH = "/";

      # Generic timezone
      GENERIC_TIMEZONE = "America/Los_Angeles";

      # User management (disabled = false is the default, so we don't need to set it)

      # Credentials encryption
      # N8N_ENCRYPTION_KEY is set via EnvironmentFile from SOPS secret

      # Metrics endpoint for Prometheus
      N8N_METRICS = "true";
      N8N_METRICS_PREFIX = "n8n_";
      N8N_METRICS_INCLUDE_DEFAULT_METRICS = "true";
      N8N_METRICS_INCLUDE_API_ENDPOINTS = "true";
      N8N_METRICS_INCLUDE_MESSAGE_EVENT_BUS_METRICS = "true";
      N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL = "true";

      # Log configuration
      N8N_LOG_LEVEL = "info";
      N8N_LOG_OUTPUT = "console";

      # Disable external telemetry/analytics (blocked by Technitium DNS ad-blocker anyway)
      N8N_DIAGNOSTICS_ENABLED = "false";
      N8N_VERSION_NOTIFICATIONS_ENABLED = "false";
      N8N_DISABLE_PRODUCTION_MAIN_PROCESS = "true";

      # Task runners and worker configuration
      N8N_RUNNERS_ENABLED = "true";
      OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS = "true";

      # Security settings
      N8N_BLOCK_ENV_ACCESS_IN_NODE = "false";  # Allow env var access from Code Node
      N8N_GIT_NODE_DISABLE_BARE_REPOS = "true";  # Disable bare repos for security

      # Trust Step-CA root certificate for webhook HTTPS connections
      NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/vulcan-ca.crt";
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
      QUEUE_BULL_REDIS_PATH=/run/redis-n8n/redis.sock
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

        # Preserve headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Original-Host $host;

        # (Optional) origin passthrough if your app needs it
        proxy_set_header Origin $host;

        # Timeouts for long-running requests
        proxy_connect_timeout 300;
        proxy_read_timeout 36000s;
        proxy_send_timeout 36000s;

        # Disable buffering/caching for streaming/WS
        chunked_transfer_encoding off;
        proxy_cache off;
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
