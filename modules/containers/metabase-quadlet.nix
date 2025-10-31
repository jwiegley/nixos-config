{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "metabase";
      image = "docker.io/metabase/metabase:latest";
      port = 3200;
      requiresPostgres = true;
      containerUser = "container-db";  # Run rootless as container-db user

      # Enable health checks
      healthCheck = {
        enable = true;
        type = "http";
        interval = "30s";
        timeout = "10s";
        startPeriod = "120s";  # Metabase takes time to initialize
        retries = 3;
        httpPath = "/api/health";
        httpPort = 3000;  # Internal container port
      };
      enableWatchdog = false;  # Disabled - requires sdnotify

      # SOPS secret containing Metabase environment variables
      # Includes MB_DB_PASS for PostgreSQL backend connection
      secrets = {
        env = "metabase-env";
      };

      environments = {
        # PostgreSQL Backend Configuration
        # Metabase stores its application database (users, dashboards, queries) in PostgreSQL
        MB_DB_TYPE = "postgres";
        MB_DB_HOST = "10.88.0.1";
        MB_DB_PORT = "5432";
        MB_DB_DBNAME = "metabase";
        MB_DB_USER = "metabase";
        # MB_DB_PASS provided via SOPS secret (metabase-env)

        # Java Options (optimize memory for container)
        JAVA_OPTS = "-Xmx2g -XX:+UseContainerSupport";

        # Timezone
        TZ = "America/Los_Angeles";
      };

      publishPorts = [ "127.0.0.1:3200:3000/tcp" ];

      volumes = [
        "/var/lib/metabase:/metabase-data:rw"
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:3200/";
        proxyWebsockets = false;
        extraConfig = ''
          # Metabase can serve large CSV exports and dashboard queries
          proxy_buffering off;
          client_max_body_size 50M;
          proxy_read_timeout 10m;
          proxy_connect_timeout 5m;
          proxy_send_timeout 5m;

          # Metabase session cookies
          proxy_cookie_path / "/; Secure; HttpOnly";

          # Standard proxy headers
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Real-IP $remote_addr;
        '';
      };

      tmpfilesRules = [
        "d /var/lib/metabase 0755 root root -"
      ];
    })
  ];

  # Additional SOPS secret for PostgreSQL user setup
  # (metabase-env is automatically declared by mkQuadletService)
  # Password is set manually via: sudo cat /run/secrets/metabase-postgres-password | sudo -u postgres psql -c "ALTER USER metabase WITH PASSWORD '$(cat)'"
  sops.secrets."metabase-postgres-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "postgres";
  };

  # NOTE: Metabase + Vanna.AI Integration Opportunity
  # =====================================================
  # Metabase can visualize query results from Vanna.AI (AI text-to-SQL tool).
  # Both tools will connect to the same databases (SQL Server at hera.lan:1433, PostgreSQL).
  #
  # Suggested Workflow:
  # 1. Use Vanna.AI to generate SQL queries from natural language prompts
  # 2. Copy generated SQL to Metabase query editor
  # 3. Create visualizations (charts, dashboards) in Metabase from Vanna results
  # 4. Save as Metabase dashboards for team access and scheduled emails
  # 5. Combine AI-powered query generation with professional BI visualization
  #
  # This enables: Natural language queries (Vanna.AI) → Visual dashboards (Metabase)

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    3200  # metabase
  ];
}
