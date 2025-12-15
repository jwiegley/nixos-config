{ config, lib, pkgs, ... }:

let
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL password for gitea user
    (mkPostgresUserSetup {
      user = "gitea";
      database = "gitea";
      secretPath = config.sops.secrets."gitea-db-password".path;
      dependentService = "gitea.service";
    })
  ];

  environment.systemPackages = with pkgs; [
    gitea
  ];

  # SOPS secrets for Gitea
  sops.secrets = {
    "gitea-db-password" = {
      owner = "postgres";
      group = "gitea";
      mode = "0440";
    };
  };

  # PostgreSQL database and user for Gitea
  services.postgresql = {
    ensureDatabases = [ "gitea" ];
    ensureUsers = [
      {
        name = "gitea";
        ensureDBOwnership = true;
      }
    ];
  };

  # Redis instance for Gitea (cache and sessions)
  users.groups.redis-gitea = {};

  services.redis.servers.gitea = {
    enable = true;
    port = 0; # Unix socket only
    bind = null;
    unixSocket = "/run/redis-gitea/redis.sock";
    unixSocketPerm = 660;
    user = "redis-gitea";
  };

  # Gitea service configuration
  services.gitea = {
    enable = true;

    # CAPTCHA on registration page (built-in image captcha)
    captcha = {
      enable = true;
      type = "image";
    };

    # Use PostgreSQL database
    database = {
      type = "postgres";
      host = "/run/postgresql";
      name = "gitea";
      user = "gitea";
      passwordFile = config.sops.secrets."gitea-db-password".path;
    };

    # Application settings
    settings = {
      # Server configuration
      server = {
        DOMAIN = "gitea.vulcan.lan";
        ROOT_URL = "https://gitea.vulcan.lan/";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3005;
        PROTOCOL = "http";
        DISABLE_SSH = false;
        SSH_PORT = 2222;
        START_SSH_SERVER = true; # Use Gitea's built-in SSH server
        SSH_LISTEN_HOST = "0.0.0.0";
        SSH_LISTEN_PORT = 2222;
      };

      # Service configuration
      service = {
        DISABLE_REGISTRATION = true;
        REQUIRE_SIGNIN_VIEW = false;
        DEFAULT_KEEP_EMAIL_PRIVATE = true;
        DEFAULT_ALLOW_CREATE_ORGANIZATION = true;
        ENABLE_NOTIFY_MAIL = true;
        DEFAULT_EMAIL_NOTIFICATIONS = "enabled";
        # Email verification: new users must click a link in confirmation email
        REGISTER_EMAIL_CONFIRM = true;
      };

      # Email/Mailer configuration
      mailer = {
        ENABLED = true;
        PROTOCOL = "smtp";
        SMTP_ADDR = "127.0.0.1";
        SMTP_PORT = 25;
        FROM = "gitea@vulcan.lan";
        USER = ""; # No auth required for localhost
        PASSWD = ""; # No auth required for localhost
      };

      # Session configuration using Redis
      session = {
        PROVIDER = "redis";
        PROVIDER_CONFIG = "network=unix,addr=/run/redis-gitea/redis.sock,db=0";
      };

      # Cache configuration using Redis
      cache = {
        ENABLED = true;
        ADAPTER = "redis";
        HOST = "network=unix,addr=/run/redis-gitea/redis.sock,db=1";
      };

      # Queue configuration using Redis
      queue = {
        TYPE = "redis";
        CONN_STR = "network=unix,addr=/run/redis-gitea/redis.sock,db=2";
      };

      # Security settings
      security = {
        INSTALL_LOCK = true;
      };

      # Metrics configuration for Prometheus
      metrics = {
        ENABLED = true;
        TOKEN = ""; # No authentication for metrics endpoint (accessed via localhost)
      };

      # Repository settings
      repository = {
        ROOT = "/var/lib/gitea/repositories";
        DEFAULT_BRANCH = "main";
      };

      # Log configuration
      log = {
        MODE = "console,file";
        LEVEL = "Info";
        ROOT_PATH = "/var/lib/gitea/log";
      };

      # Enable Gitea Actions
      actions = {
        ENABLED = true;
        DEFAULT_ACTIONS_URL = "github"; # Use GitHub-compatible actions
      };
    };
  };

  # Add gitea user to redis-gitea group for socket access
  users.users.gitea = {
    extraGroups = [ "redis-gitea" ];
  };

  # Ensure Gitea starts after Redis
  systemd.services.gitea = {
    after = [ "redis-gitea.service" "postgresql-gitea-setup.service" ];
    requires = [ "redis-gitea.service" "postgresql-gitea-setup.service" ];
  };

  # Open firewall for Gitea SSH
  networking.firewall.allowedTCPPorts = [ 2222 ];

  # Nginx virtual host for Gitea
  services.nginx.virtualHosts."gitea.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/gitea.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/gitea.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:3005";
      proxyWebsockets = true;
      extraConfig = ''
        # Increase timeouts for Git operations
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
        send_timeout 600;

        # Increase buffer sizes for large Git operations
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 1G;
      '';
    };
  };
}
