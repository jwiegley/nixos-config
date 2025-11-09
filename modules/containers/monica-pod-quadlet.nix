{ config, lib, pkgs, secrets, ... }:

{
  # Monica CRM Pod - MariaDB + Monica containers sharing network namespace
  # Architecture: MariaDB database + PHP/Apache Monica app in a Podman Pod
  #
  # NOTE: Uses a Pod because rootless containers with slirp4netns networking
  # can't communicate with each other directly. Containers in a pod share
  # network namespace and communicate via localhost.

  # SOPS secrets
  sops.secrets."mariadb-env" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "root";
    path = "/run/secrets/mariadb-env";
  };

  sops.secrets."monica-env" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "root";
    path = "/run/secrets/monica-env";
    restartUnits = [ "monica-app.service" ];
  };

  # Create data directories
  systemd.tmpfiles.rules = [
    "D /var/lib/mariadb 0755 362144 362144 -"  # UID 362144 = container root (UID 0)
    "D /var/lib/monica 0755 362144 362144 -"   # UID 362144 = container root (UID 0)
  ];

  # Create CSRF patch script
  environment.etc."monica-csrf-patch.sh" = {
    mode = "0755";
    text = ''
      #!/bin/bash
      # Patch Monica's CSRF middleware to exclude OAuth routes
      # This fixes the issue where personal access tokens cannot be created

      CSRF_FILE="/var/www/html/app/Http/Middleware/VerifyCsrfToken.php"

      if [ -f "$CSRF_FILE" ]; then
          # Check if oauth/* is already in the exclusion list
          if ! grep -q "'oauth/\*'" "$CSRF_FILE"; then
              echo "Patching CSRF middleware to exclude OAuth routes..."
              sed -i "s/'stripe\/\*',/'stripe\/*',\n        'oauth\/*',/" "$CSRF_FILE"
              echo "CSRF middleware patched successfully."
          else
              echo "OAuth routes already excluded from CSRF protection."
          fi
      else
          echo "Warning: CSRF middleware file not found at $CSRF_FILE"
      fi
    '';
  };

  # Monica Pod - containers share network namespace
  virtualisation.quadlet.pods.monica = {
    podConfig = {
      # Expose Monica web interface to host
      publishPorts = [
        "127.0.0.1:9092:80/tcp"
      ];
      # Use slirp4netns for rootless networking
      networks = [ "slirp4netns:allow_host_loopback=true" ];
    };

    unitConfig = {
      After = [ "sops-nix.service" "podman.service" ];
      Wants = [ "sops-nix.service" ];
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
      TimeoutStartSec = "900";
      Environment = "PATH=/run/current-system/sw/bin:/run/wrappers/bin";
      # User/Group not set for pods - only for containers
      # Pods need root to create the pod infra container
    };
  };

  # MariaDB Container - runs in pod
  virtualisation.quadlet.containers.mariadb = {
    autoStart = true;

    containerConfig = {
      image = "docker.io/library/mariadb:11.7";

      # MariaDB listens on localhost:3306 within the pod
      # No port publishing needed - Monica accesses via pod's shared network

      environments = {
        MYSQL_DATABASE = "monica";
        MYSQL_USER = "monica";
        # MYSQL_PASSWORD and MYSQL_ROOT_PASSWORD from mariadb-env secret
      };

      environmentFiles = [ "/run/secrets/mariadb-env" ];

      volumes = [
        "/var/lib/mariadb:/var/lib/mysql:rw"
      ];

      # Join the monica pod
      pod = "monica.pod";
    };

    unitConfig = {
      After = [ "sops-nix.service" "podman.service" "monica-pod.service" ];
      Wants = [ "sops-nix.service" ];
      Requires = [ "monica-pod.service" ];
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };

    serviceConfig = {
      Environment = "PATH=/run/current-system/sw/bin:/run/wrappers/bin";
      Restart = "always";
      RestartSec = "10s";
      TimeoutStartSec = "900";
    };
  };

  # Monica Container - runs in pod
  virtualisation.quadlet.containers.monica-app = {
    autoStart = true;

    containerConfig = {
      image = "docker.io/monica:4.1.2";

      # Port exposed via pod configuration above
      # Monica connects to MariaDB via localhost:3306 (same pod)

      # Health check configuration
      healthCmd = "CMD-SHELL curl -f http://localhost:80/ || exit 1";
      healthInterval = "30s";
      healthTimeout = "10s";
      healthStartPeriod = "90s";  # Monica takes time to initialize
      healthRetries = 3;

      environments = {
        # MariaDB connection - use 127.0.0.1 to force TCP (localhost uses Unix socket)
        DB_CONNECTION = "mysql";
        DB_HOST = "127.0.0.1";  # Use 127.0.0.1 not localhost to force TCP connection
        DB_PORT = "3306";
        DB_DATABASE = "monica";
        DB_USERNAME = "monica";
        # DB_PASSWORD provided via SOPS secret (monica-env)

        # Application Configuration
        APP_ENV = "production";
        APP_DEBUG = "false";
        APP_URL = "https://monica.vulcan.lan";
        # APP_KEY provided via SOPS secret (monica-env)

        # Disable registration (adjust as needed)
        APP_DISABLE_SIGNUP = "false";

        # Mail Configuration (using local Postfix)
        MAIL_MAILER = "smtp";
        MAIL_HOST = "10.88.0.1";
        MAIL_PORT = "25";
        MAIL_USERNAME = "";
        MAIL_PASSWORD = "";
        MAIL_ENCRYPTION = "";
        MAIL_FROM_ADDRESS = "monica@vulcan.lan";
        MAIL_FROM_NAME = "Monica CRM";

        # Timezone
        APP_TIMEZONE = "America/Los_Angeles";

        # Cache and Session Configuration
        CACHE_DRIVER = "database";
        SESSION_DRIVER = "database";
        QUEUE_CONNECTION = "sync";
      };

      environmentFiles = [ "/run/secrets/monica-env" ];

      volumes = [
        "/var/lib/monica:/var/www/html/storage:rw"
      ];

      # Join the monica pod
      pod = "monica.pod";
    };

    unitConfig = {
      After = [ "sops-nix.service" "podman.service" "monica-pod.service" "mariadb.service" ];
      Wants = [ "sops-nix.service" "mariadb.service" ];
      Requires = [ "monica-pod.service" ];
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };

    serviceConfig = {
      Environment = "PATH=/run/current-system/sw/bin:/run/wrappers/bin";
      Restart = "always";
      RestartSec = "10s";
      TimeoutStartSec = "900";
    };
  };

  # Nginx virtual host for Monica
  services.nginx.virtualHosts."monica.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/monica.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/monica.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:9092/";
      proxyWebsockets = false;
      extraConfig = ''
        # Monica can handle large file uploads (photos, documents)
        proxy_buffering off;
        client_max_body_size 100M;
        proxy_read_timeout 5m;
        proxy_connect_timeout 2m;
        proxy_send_timeout 5m;

        # Monica session cookies
        proxy_cookie_path / "/; Secure; HttpOnly";

        # Standard proxy headers
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Real-IP $remote_addr;
      '';
    };
  };

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    9092  # monica
  ];


  # Monica CRM - Personal Relationship Manager
  # ==========================================
  # Monica is an open-source personal CRM that helps you organize
  # and remember everything about your friends, family, and colleagues.
  #
  # Features:
  # - Contact management with relationships, notes, activities
  # - Reminders for birthdays, important dates, and tasks
  # - Gift ideas tracking
  # - Conversation logging
  # - Document and photo storage
  # - Journal entries
  # - Activity tracking
}
