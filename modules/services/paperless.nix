{ config, lib, pkgs, ... }:

{
  # SOPS secrets for Paperless-ngx
  sops.secrets."paperless/admin-password" = {
    sopsFile = ../../secrets.yaml;
    owner = "paperless";
    mode = "0400";
    restartUnits = [ "paperless-scheduler.service" ];
  };

  sops.secrets."paperless/secret-key" = {
    sopsFile = ../../secrets.yaml;
    owner = "paperless";
    mode = "0400";
    restartUnits = [ "paperless-scheduler.service" ];
  };

  # LiteLLM API key (shared with paperless-ai container)
  # Using root:root with 0444 (world-readable) to allow both paperless user and containers to read it
  sops.secrets."litellm-vulcan-lan" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0444";  # World-readable so paperless user and containers can access
    restartUnits = [ "paperless-scheduler.service" ];
  };

  # Redis instance for Paperless-ngx
  services.redis.servers.paperless = {
    enable = true;
    port = 6379;
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

    # Add peer authentication for paperless user on local socket
    # Using mkOverride 5 to take precedence over databases.nix (which uses mkOverride 10)
    authentication = lib.mkOverride 5 ''
      # TYPE  DATABASE  USER  ADDRESS         METHOD  OPTIONS

      # Paperless-ngx local socket connection (peer authentication)
      local   paperless      paperless                        peer

      # Unix socket connections - require password for non-postgres users
      local   all       postgres                peer
      local   all       all                     scram-sha-256

      # Localhost connections - require password
      host    all       postgres   127.0.0.1/32    scram-sha-256
      host    all       all        127.0.0.1/32    scram-sha-256
      host    all       all        ::1/128         scram-sha-256

      # Podman network - require password (containers should use passwords)
      host    all       all        10.88.0.0/16    scram-sha-256

      # Local networks - SSL required with client certificate verification
      hostssl all       postgres   192.168.0.0/16  scram-sha-256
      hostssl all       all        192.168.0.0/16  scram-sha-256

      # Nebula network - SSL required
      hostssl all       all        10.6.0.0/24     scram-sha-256

      # Reject all other connections
      host    all       all        0.0.0.0/0       reject
      host    all       all        ::/0            reject
    '';
  };

  # Paperless-ngx service
  services.paperless = {
    enable = true;

    # Document storage location on ZFS
    dataDir = "/tank/Paperless/data";
    mediaDir = "/tank/Paperless/media";
    consumptionDir = "/tank/Paperless/consume";
    consumptionDirIsPublic = true; # Allow multiple users to drop files

    # PostgreSQL database configuration
    database.createLocally = false; # We manage PostgreSQL ourselves

    # Admin password from SOPS
    passwordFile = config.sops.secrets."paperless/admin-password".path;

    # Bind to all interfaces (nginx reverse proxy + container access)
    address = "0.0.0.0";
    port = 28981;

    # Enable Tika and Gotenberg for Office document OCR
    configureTika = true;

    # Paperless-ngx settings
    settings = {
      # Django secret key
      PAPERLESS_SECRET_KEY = config.sops.secrets."paperless/secret-key".path;

      # Database configuration
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBHOST = "/run/postgresql";
      PAPERLESS_DBNAME = "paperless";
      PAPERLESS_DBUSER = "paperless";
      # No password needed for peer authentication

      # Redis configuration
      PAPERLESS_REDIS = "redis://localhost:6379";

      # URL configuration for nginx reverse proxy
      PAPERLESS_URL = "https://paperless.vulcan.lan";
      PAPERLESS_ALLOWED_HOSTS = "paperless.vulcan.lan,localhost,127.0.0.1,10.88.0.1";
      PAPERLESS_CORS_ALLOWED_HOSTS = "https://paperless.vulcan.lan";
      PAPERLESS_TRUSTED_PROXIES = "127.0.0.1,::1,10.88.0.0/16";  # Trust podman network
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
      PAPERLESS_WORKER_TIMEOUT = 1800; # 30 minutes for large documents

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

      # Logging
      PAPERLESS_LOGGING_DIR = "/tank/Paperless/logs";
      PAPERLESS_LOGROTATE_MAX_SIZE = 10485760; # 10MB
      PAPERLESS_LOGROTATE_MAX_BACKUPS = 5;
      PAPERLESS_LOGGING_LEVEL = "DEBUG";  # Enable detailed logging for troubleshooting

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

  # Ensure paperless starts after dependencies
  systemd.services.paperless-scheduler = {
    after = [
      "postgresql.service"
      "redis-paperless.service"
      "sops-install-secrets.service"
      "network-online.target"
    ];
    wants = [
      "postgresql.service"
      "redis-paperless.service"
      "sops-install-secrets.service"
      "network-online.target"
    ];

    # Add LiteLLM API key to environment for future AI integration
    environment = {
      LITELLM_API_KEY_FILE = config.sops.secrets."litellm-vulcan-lan".path;
      LITELLM_BASE_URL = "https://litellm.vulcan.lan/v1";
    };
  };

  # Override Gotenberg service to use port 3003 (3000=Grafana, 3001=paperless-ai, 3002=speedtest)
  systemd.services.gotenberg = {
    serviceConfig = {
      ExecStart = lib.mkForce "${pkgs.gotenberg}/bin/gotenberg --api-port=3003 --api-timeout=30s --api-root-path=/ --log-level=info --chromium-max-queue-size=0 --libreoffice-restart-after=10 --libreoffice-max-queue-size=0 --pdfengines-merge-engines=qpdf,pdfcpu,pdftk --pdfengines-convert-engines=libreoffice-pdfengine --pdfengines-read-metadata-engines=exiftool --pdfengines-write-metadata-engines=exiftool --api-download-from-allow-list=.* --api-download-from-max-retry=4 --chromium-disable-javascript --chromium-allow-list=file:///tmp/.*";
    };
  };

  # Create directory structure
  systemd.tmpfiles.rules = [
    "d /tank/Paperless 0755 paperless paperless -"
    "d /tank/Paperless/data 0755 paperless paperless -"
    "d /tank/Paperless/media 0755 paperless paperless -"
    "d /tank/Paperless/consume 0777 paperless paperless -" # World-writable for easy document drop
    "d /tank/Paperless/logs 0755 paperless paperless -"
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

  # Open firewall for local network access (optional, nginx provides access)
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 28981 ];
}
