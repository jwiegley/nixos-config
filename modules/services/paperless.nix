{ config, lib, pkgs, ... }:

{
  # SOPS secrets for Paperless-ngx
  sops.secrets."paperless/admin-password" = {
    owner = "paperless";
    mode = "0400";
    restartUnits = [ "paperless-scheduler.service" ];
  };

  sops.secrets."paperless/secret-key" = {
    owner = "paperless";
    mode = "0400";
    restartUnits = [ "paperless-scheduler.service" ];
  };

  sops.secrets."paperless/postgres-password" = {
    owner = "paperless";
    mode = "0400";
    restartUnits = [ "paperless-scheduler.service" ];
  };

  # LiteLLM API key (shared with paperless-ai container)
  # Using root:root with 0444 (world-readable) to allow both paperless user and containers can access
  sops.secrets."litellm-vulcan-lan" = {
    owner = "root";
    group = "root";
    mode = "0444";  # World-readable so paperless user and containers can access
    restartUnits = [ "paperless-scheduler.service" ];
  };

  # Redis instance for Paperless-ngx
  services.redis.servers.paperless = {
    enable = true;
    port = 6382;  # Use port 6382 (6379-6381 already in use)
    bind = "127.0.0.1";
  };

  # PostgreSQL database for Paperless-ngx
  services.postgresql = {
    ensureDatabases = [ "paperless" ];
    ensureUsers = [
      {
        name = "paperless";
        ensureDBOwnership = true;
      }
    ];
  };

  # Paperless-ngx service
  services.paperless = {
    enable = true;

    # Document storage location in /var/lib (standard NixOS location)
    dataDir = "/var/lib/paperless-ngx/data";
    mediaDir = "/var/lib/paperless-ngx/media";
    consumptionDir = "/var/lib/paperless-ngx/consume";
    consumptionDirIsPublic = true; # Allow multiple users to drop files

    # PostgreSQL database configuration
    database.createLocally = false; # We manage PostgreSQL ourselves

    # Admin password from SOPS
    passwordFile = config.sops.secrets."paperless/admin-password".path;

    # Bind to localhost only (accessed via nginx reverse proxy)
    address = "127.0.0.1";
    port = 28981;

    # Enable Tika and Gotenberg for Office document OCR
    configureTika = true;

    # Paperless-ngx settings
    settings = {
      # Django secret key
      PAPERLESS_SECRET_KEY = config.sops.secrets."paperless/secret-key".path;

      # Database configuration
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBHOST = "localhost";
      PAPERLESS_DBNAME = "paperless";
      PAPERLESS_DBUSER = "paperless";
      PAPERLESS_DBPORT = 5432;

      # Redis configuration
      PAPERLESS_REDIS = "redis://localhost:6382";

      # URL configuration for nginx reverse proxy
      PAPERLESS_URL = "https://paperless.vulcan.lan";
      PAPERLESS_ALLOWED_HOSTS = "paperless.vulcan.lan,localhost,127.0.0.1,10.88.0.1,10.0.2.2";
      PAPERLESS_CORS_ALLOWED_HOSTS = "https://paperless.vulcan.lan";
      PAPERLESS_TRUSTED_PROXIES = "127.0.0.1,::1,10.88.0.0/16,10.0.2.0/24";  # Trust podman network and slirp4netns
      PAPERLESS_USE_X_FORWARD_HOST = true;
      PAPERLESS_USE_X_FORWARD_PORT = true;

      # Database connection management
      PAPERLESS_DB_TIMEOUT = 300;  # 5 minute connection timeout
      PAPERLESS_DBCONNECTION_KEEPALIVE = 60;  # Keep connections alive for 60 seconds

      # Time zone
      PAPERLESS_TIME_ZONE = "America/Los_Angeles";

      # OCR configuration
      PAPERLESS_OCR_LANGUAGE = "eng";
      PAPERLESS_OCR_MODE = "redo"; # Redo OCR even if text layer exists
      PAPERLESS_OCR_CLEAN = "clean"; # Clean up OCR output
      PAPERLESS_OCR_DESKEW = true;
      PAPERLESS_OCR_ROTATE_PAGES = true;
      PAPERLESS_OCR_ROTATE_PAGES_THRESHOLD = 12.0;
      PAPERLESS_OCR_MAX_IMAGE_PIXELS = 1000000000; # 1 billion pixels (prevents DecompressionBombError)
      PAPERLESS_OCR_USER_ARGS = {
        optimize = 1;
        pdfa_image_compression = "lossless";
      };

      # Tika and Gotenberg endpoints
      PAPERLESS_TIKA_ENABLED = true;
      PAPERLESS_TIKA_ENDPOINT = "http://localhost:9998";
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT = "http://localhost:3003";

      # Document processing (increased for bulk upload handling)
      PAPERLESS_TASK_WORKERS = 8;  # Increased from 2 to handle bulk uploads better
      PAPERLESS_THREADS_PER_WORKER = 1;
      PAPERLESS_WORKER_TIMEOUT = 7200; # 120 minutes for large documents (80MB+ PDFs)

      # Consumption
      PAPERLESS_CONSUMER_POLLING = 60; # Check every 60 seconds
      PAPERLESS_CONSUMER_DELETE_DUPLICATES = true;
      PAPERLESS_CONSUMER_RECURSIVE = true;
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = true;

      # AI/LLM Configuration via LiteLLM
      # Paperless-ngx doesn't have native OpenAI integration yet
      # This can be configured via custom post-processing scripts
      # For now, we'll set up the environment for future use

      # Enable thumbnail generation
      PAPERLESS_THUMBNAIL_FONT_NAME = "${pkgs.liberation_ttf}/share/fonts/truetype/LiberationSans-Regular.ttf";

      # User and permissions
      PAPERLESS_ADMIN_USER = "admin";
      PAPERLESS_ADMIN_MAIL = "johnw@newartisans.com";

      # Filename formatting (use double brackets for new format)
      PAPERLESS_FILENAME_FORMAT = "{{created_year}}/{{correspondent}}/{{title}}";

      # Logging - enable file logging for UI logs pane
      # Logs also go to systemd journald (viewable with journalctl)
      PAPERLESS_LOGROTATE_MAX_SIZE = "1024000";  # 1MB per log file
      PAPERLESS_LOGROTATE_MAX_BACKUPS = "5";  # Keep 5 backup files
      PAPERLESS_LOGGING_LEVEL = "INFO";  # Use INFO level for normal operation

      # Email settings (using local postfix)
      PAPERLESS_EMAIL_HOST = "localhost";
      PAPERLESS_EMAIL_PORT = 25;
      PAPERLESS_EMAIL_FROM = "paperless@vulcan.lan";
      PAPERLESS_EMAIL_USE_TLS = false;
      PAPERLESS_EMAIL_USE_SSL = false;

      # Security
      PAPERLESS_COOKIE_PREFIX = "paperless_";
      PAPERLESS_ENABLE_HTTP_REMOTE_USER = false;

      # Enable app tokens for API access
      PAPERLESS_APPS_ENABLED = true;
    };
  };

  # Create systemd service to generate database password environment file
  systemd.services.paperless-db-env = {
    description = "Generate Paperless database password environment file";
    before = [ "paperless-scheduler.service" ];
    wantedBy = [ "paperless-scheduler.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /var/lib/paperless-ngx
      cat > /var/lib/paperless-ngx/db.env <<EOF
      PAPERLESS_DBPASS=$(cat ${config.sops.secrets."paperless/postgres-password".path})
      EOF
      chmod 600 /var/lib/paperless-ngx/db.env
      chown paperless:paperless /var/lib/paperless-ngx/db.env
    '';
  };

  # Ensure paperless starts after dependencies and load database password
  systemd.services.paperless-scheduler = {
    after = [
      "postgresql.service"
      "redis-paperless.service"
      "sops-install-secrets.service"
      "postgresql-paperless-setup.service"
      "paperless-db-env.service"
      "network-online.target"
    ];
    wants = [
      "postgresql.service"
      "redis-paperless.service"
      "sops-install-secrets.service"
      "postgresql-paperless-setup.service"
      "paperless-db-env.service"
      "network-online.target"
    ];

    # Load database password from environment file
    serviceConfig.EnvironmentFile = "/var/lib/paperless-ngx/db.env";

    # Add LiteLLM API key to environment for future AI integration
    environment = {
      LITELLM_API_KEY_FILE = config.sops.secrets."litellm-vulcan-lan".path;
      LITELLM_BASE_URL = "https://litellm.vulcan.lan/v1";
    };
  };

  # All paperless services need the database password
  systemd.services.paperless-consumer = {
    after = [ "paperless-db-env.service" ];
    wants = [ "paperless-db-env.service" ];
    serviceConfig.EnvironmentFile = "/var/lib/paperless-ngx/db.env";
  };

  systemd.services.paperless-web = {
    after = [ "paperless-db-env.service" ];
    wants = [ "paperless-db-env.service" ];
    serviceConfig.EnvironmentFile = "/var/lib/paperless-ngx/db.env";
  };

  systemd.services.paperless-task-queue = {
    after = [ "paperless-db-env.service" ];
    wants = [ "paperless-db-env.service" ];
    serviceConfig.EnvironmentFile = "/var/lib/paperless-ngx/db.env";
  };

  # Override Gotenberg service to use port 3003 (3000=Grafana, 3001=paperless-ai, 3002=speedtest)
  systemd.services.gotenberg = {
    serviceConfig = {
      ExecStart = lib.mkForce "${pkgs.gotenberg}/bin/gotenberg --api-port=3003 --api-timeout=30s --api-root-path=/ --log-level=info --chromium-max-queue-size=0 --libreoffice-restart-after=10 --libreoffice-max-queue-size=0 --pdfengines-merge-engines=qpdf,pdfcpu,pdftk --pdfengines-convert-engines=libreoffice-pdfengine --pdfengines-read-metadata-engines=exiftool --pdfengines-write-metadata-engines=exiftool --api-download-from-allow-list=.* --api-download-from-max-retry=4 --chromium-disable-javascript --chromium-allow-list=file:///tmp/.*";
    };
  };

  # Create directory structure using 'd' directive (preserve existing contents)
  # CRITICAL: Using 'd' to preserve contents - 'D' would empty directories on rebuild!
  systemd.tmpfiles.rules = [
    "d /var/lib/paperless-ngx 0755 paperless paperless -"
    "d /var/lib/paperless-ngx/data 0755 paperless paperless -"
    "d /var/lib/paperless-ngx/media 0755 paperless paperless -"
    "d /var/lib/paperless-ngx/consume 0777 paperless paperless -" # World-writable for easy document drop
  ];

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."paperless.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/paperless.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/paperless.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.paperless.port}";
      proxyWebsockets = true;
      recommendedProxySettings = false; # Disable default proxy settings to avoid duplicate Host header
      extraConfig = ''
        # Proxy headers - explicitly set all headers to avoid duplicates
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        # Timeouts for document upload and processing
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;

        # Large file uploads
        client_max_body_size 100M;
      '';
    };
  };

  # Open firewall for container access (paperless-ai) and nginx reverse proxy
  # Note: Changed from lo-only to allow rootless containers with slirp4netns to access
  networking.firewall.allowedTCPPorts = [ 28981 ];
}
