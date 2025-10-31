{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "vanna";
      image = "localhost/vanna:latest";
      port = 5000;
      requiresPostgres = false;  # Vanna connects to databases dynamically, no bootstrap needed
      containerUser = "container-db";  # Run rootless as container-db user

      # Never pull image - it's built locally and loaded into rootless user's store
      extraContainerConfig = {
        pull = "never";
      };

      # Enable health checks using Python (Flask app)
      healthCheck = {
        enable = true;
        type = "exec";
        interval = "30s";
        timeout = "10s";
        startPeriod = "45s";
        retries = 3;
        execCommand = "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:5000/', timeout=5)\"";
      };
      enableWatchdog = false;  # Disabled - requires sdnotify

      # SOPS secret containing Vanna.AI environment variables
      # Includes:
      # - OPENAI_API_KEY: LiteLLM API key (for local LLM access)
      # - VANNA_DB_URL: PostgreSQL connection for optional persistence
      # Note: Using local LiteLLM instead of OpenAI commercial API
      secrets = {
        env = "vanna-env";
      };

      environments = {
        # Flask server configuration
        FLASK_APP = "app.py";
        FLASK_ENV = "production";
        FLASK_RUN_HOST = "0.0.0.0";
        FLASK_RUN_PORT = "5000";

        # OpenAI-compatible API configuration (using local LiteLLM)
        # LiteLLM acts as a proxy to local/self-hosted LLMs
        # Both vanna and litellm run rootless - use localhost
        OPENAI_API_BASE = "http://127.0.0.1:4000/v1";  # LiteLLM endpoint
        # OPENAI_API_KEY provided via SOPS secret (vanna-env)
        # This key is for LiteLLM authentication, not OpenAI

        # Model selection - using local hera/gpt-oss-120b via LiteLLM
        VANNA_MODEL = "hera/gpt-oss-120b";

        # PostgreSQL backend (optional - for storing query history/metadata)
        # Connection details provided via SOPS secret
        # VANNA_DB_URL format: postgresql://user:password@host:port/database

        # Redis backend (optional - for caching query results)
        # REDIS_URL format: redis://host:port/db
        # REDIS_URL = "redis://10.88.0.1:6379/3";  # DB 3 for Vanna

        # Timezone
        TZ = "America/Los_Angeles";

        # Security settings
        # Disable debug mode in production
        DEBUG = "false";
      };

      publishPorts = [ "127.0.0.1:5000:5000/tcp" ];

      volumes = [
        "/var/lib/vanna/faiss:/vanna/faiss:rw"  # Persistent FAISS vector store
        "/var/lib/vanna/cache:/vanna/cache:rw"  # Cache directory
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:5000/";
        proxyWebsockets = true;  # Vanna.AI may use WebSockets for real-time updates
        extraConfig = ''
          # Vanna.AI can generate large result sets
          proxy_buffering off;
          client_max_body_size 100M;
          proxy_read_timeout 5m;
          proxy_connect_timeout 1m;
          proxy_send_timeout 5m;

          # Session cookies
          proxy_cookie_path / "/; Secure; HttpOnly";

          # Standard proxy headers
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Real-IP $remote_addr;
        '';
      };

      tmpfilesRules = [
        "d /var/lib/vanna 0755 container-db container-db -"
        "d /var/lib/vanna/faiss 0755 container-db container-db -"
        "d /var/lib/vanna/cache 0755 container-db container-db -"
      ];
    })
  ];

  # NOTE: Vanna.AI + Metabase Integration Workflow
  # =================================================
  # Vanna.AI (this service) generates SQL queries from natural language prompts.
  # Metabase (already installed) visualizes the query results.
  #
  # Workflow:
  # 1. User asks natural language question in Vanna.AI
  # 2. Vanna.AI generates SQL query using LLM + RAG
  # 3. User reviews and executes SQL in Vanna.AI
  # 4. Copy SQL query to Metabase query editor
  # 5. Create visualizations and dashboards in Metabase
  #
  # Both services will connect to:
  # - SQL Server at hera.lan:1433 (primary data source)
  # - PostgreSQL at 10.88.0.1:5432 (optional metadata storage)
  #
  # Training Vanna.AI:
  # - Feed database schema (DDL statements)
  # - Provide documentation about tables/columns
  # - Add example questions and SQL pairs
  # - More training = better accuracy
  #
  # This enables: Natural language → AI-generated SQL → Professional BI dashboards

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    5000  # vanna
  ];
}
