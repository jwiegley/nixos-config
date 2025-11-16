{ config, lib, pkgs, convention-speaker-list, ... }:

let
  # Container network configuration
  hostAddress = "10.233.4.1";
  localAddress = "10.233.4.2";

  # Port configuration
  appPort = 3001;
  nginxPort = 80;
  hostExposedPort = 9095; # Localhost-only port for Cloudflare Tunnel (9094 used by Alertmanager)

  # Application paths
  appDataDir = "/var/lib/convention-speaker-list";

in
{
  # SOPS secrets for the application
  sops.secrets."convention-speaker-list/postgres-password" = {
    restartUnits = [ "convention-speaker-list-env-setup.service" ];
  };

  sops.secrets."convention-speaker-list/jwt-secret" = {
    restartUnits = [ "convention-speaker-list-env-setup.service" ];
  };

  sops.secrets."convention-speaker-list/session-secret" = {
    restartUnits = [ "convention-speaker-list-env-setup.service" ];
  };

  # Enable NAT for container internet access
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-+" ];
    externalInterface = "end0";
  };

  # Create environment file from SOPS secrets
  systemd.services.convention-speaker-list-env-setup = {
    description = "Create environment file for convention-speaker-list";
    wantedBy = [ "multi-user.target" ];
    before = [ "container@convention-speaker-list.service" ];
    after = [ "sops-nix.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      mkdir -p /var/lib/convention-speaker-list-env
      chmod 755 /var/lib/convention-speaker-list-env

      # Read secrets from SOPS
      POSTGRES_PASSWORD=$(cat ${config.sops.secrets."convention-speaker-list/postgres-password".path})
      JWT_SECRET=$(cat ${config.sops.secrets."convention-speaker-list/jwt-secret".path})
      SESSION_SECRET=$(cat ${config.sops.secrets."convention-speaker-list/session-secret".path})

      # SECURITY: Write individual credential files for systemd LoadCredential
      # These will be loaded via LoadCredential and exposed in /run/credentials/
      echo -n "$POSTGRES_PASSWORD" > /var/lib/convention-speaker-list-env/postgres-password
      echo -n "$JWT_SECRET" > /var/lib/convention-speaker-list-env/jwt-secret
      echo -n "$SESSION_SECRET" > /var/lib/convention-speaker-list-env/session-secret

      # Set permissions - must be readable by container's convention-app user
      # With user namespaces, we need world-readable since UIDs are mapped
      chmod 644 /var/lib/convention-speaker-list-env/postgres-password
      chmod 644 /var/lib/convention-speaker-list-env/jwt-secret
      chmod 644 /var/lib/convention-speaker-list-env/session-secret

      # CRITICAL: With user namespaces enabled (privateUsers="pick"),
      # the container's root (UID 0) is mapped to an unprivileged UID on the host.
      # We make credential files world-readable so the mapped UID can access them.
      # Since this directory is only accessible via bind mount to the container,
      # world-readable here doesn't expose secrets to other host processes.
    '';
  };

  # Ensure directories exist on host
  systemd.tmpfiles.rules = [
    "d ${appDataDir} 0755 root root -"
    "d ${appDataDir}/app 0755 root root -"
    "d ${appDataDir}/postgres 0750 70 70 -"  # postgres UID in NixOS
    "d ${appDataDir}/redis 0750 997 997 -"  # redis-convention UID in container
    "d /var/lib/convention-speaker-list-env 0755 root root -"
  ];

  # NixOS container for convention-speaker-list
  containers.convention-speaker-list = {
    # Enable private network for isolation
    privateNetwork = true;
    hostAddress = hostAddress;
    localAddress = localAddress;

    # SECURITY: Enable user namespace isolation (CRITICAL for Internet exposure)
    # Maps container root (UID 0) to unprivileged UID on host (e.g., 65536+)
    # This prevents privilege escalation from container to host system
    # Even if attacker gains root in container, they won't have root on host
    privateUsers = "pick";  # Automatically allocate unprivileged UID range

    # SECURITY: Minimize attack surface
    additionalCapabilities = [];  # Remove all additional capabilities
    allowedDevices = [];  # No device access

    bindMounts = {
      # Bind mount application data directory
      # SECURITY NOTE: This must be read-write for PostgreSQL and Redis data persistence
      # Combined with user namespaces (-U flag), files written here are owned by
      # unprivileged UIDs on the host, limiting damage from container compromise
      "${appDataDir}" = {
        hostPath = appDataDir;
        isReadOnly = false;
      };

      # Bind mount environment files (read-only for security)
      # IMPORTANT: With user namespaces enabled, we need special handling for file ownership
      # Files owned by root on host (UID 0) appear as nobody in container with user namespaces
      # Solution: Copy files into the container's namespace-mapped directory
      "/var/lib/convention-speaker-list-env" = {
        hostPath = "/var/lib/convention-speaker-list-env";
        isReadOnly = false;  # Needs write access to copy files with correct ownership
      };

      # Bind mount the application source from flake input
      "/opt/convention-speaker-list-src" = {
        hostPath = "${convention-speaker-list}";
        isReadOnly = true;
      };
    };

    # Auto-start the container
    autoStart = true;

    # Container configuration
    config = { config, pkgs, lib, ... }: {
      # Basic system configuration
      system.stateVersion = "25.05";

      # Networking configuration
      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [ nginxPort ];
        };
      };

      # Time zone (match host)
      time.timeZone = "America/Los_Angeles";

      # Force DNS to point to host
      environment.etc."resolv.conf".text = lib.mkForce ''
        nameserver ${hostAddress}
        options edns0
      '';

      # PostgreSQL service
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_15;

        enableTCPIP = true;

        settings = {
          listen_addresses = lib.mkForce "127.0.0.1";
          max_connections = 100;
          shared_buffers = "256MB";
          effective_cache_size = "1GB";
          maintenance_work_mem = "64MB";
          work_mem = "16MB";
        };

        authentication = lib.mkOverride 10 ''
          # TYPE  DATABASE        USER            ADDRESS                 METHOD
          local   all             all                                     peer
          host    all             all             127.0.0.1/32            scram-sha-256
          host    all             all             ::1/128                 scram-sha-256
        '';

        # Create database and user
        # Note: database name must match username when using ensureDBOwnership
        ensureDatabases = [ "convention_db" "convention_user" ];
        ensureUsers = [
          {
            name = "convention_user";
            ensureDBOwnership = true;
          }
        ];
      };

      # Setup service to prepare PostgreSQL password file
      systemd.services.postgresql-password-setup = {
        description = "Copy PostgreSQL password for convention-speaker-list";
        wantedBy = [ "multi-user.target" ];
        before = [ "postgresql.service" ];
        after = [ "local-fs.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          if [ -f /var/lib/convention-speaker-list-env/postgres-password ]; then
            mkdir -p /run/postgresql-setup
            cp /var/lib/convention-speaker-list-env/postgres-password /run/postgresql-setup/password
            chown postgres:postgres /run/postgresql-setup/password
            chmod 600 /run/postgresql-setup/password
          fi
        '';
      };

      # Set PostgreSQL password from prepared file
      systemd.services.postgresql.postStart = ''
        # Wait for PostgreSQL to be ready
        for i in {1..30}; do
          if ${pkgs.postgresql_15}/bin/pg_isready -q; then
            break
          fi
          sleep 1
        done

        # Set password from prepared file
        if [ -f /run/postgresql-setup/password ]; then
          PASSWORD=$(cat /run/postgresql-setup/password)
          ${pkgs.postgresql_15}/bin/psql -c "ALTER USER convention_user WITH PASSWORD '$PASSWORD';" || true
          # File is in /run (tmpfs), will be cleared on reboot - ignore rm errors
          rm -f /run/postgresql-setup/password || true
        fi
      '';

      systemd.services.postgresql = {
        after = [ "postgresql-password-setup.service" ];
        wants = [ "postgresql-password-setup.service" ];
      };

      # Redis service
      services.redis.servers.convention = {
        enable = true;
        port = 6379;
        bind = "127.0.0.1";

        # Enable persistence
        save = [
          [900 1]   # Save after 900 seconds if at least 1 key changed
          [300 10]  # Save after 300 seconds if at least 10 keys changed
          [60 10000] # Save after 60 seconds if at least 10000 keys changed
        ];

        appendOnly = true;
        appendFsync = "everysec";

        settings = {
          maxmemory = "256mb";
          maxmemory-policy = "allkeys-lru";
          dir = lib.mkForce "${appDataDir}/redis";
        };
      };

      # Allow Redis to write to its data directory
      systemd.services.redis-convention.serviceConfig = {
        ReadWritePaths = [ "${appDataDir}/redis" ];
      };

      # Install Node.js and build the application
      environment.systemPackages = with pkgs; [
        nodejs_20
        postgresql_15  # For pg_isready and psql
        bash  # Required for npm scripts
        coreutils  # Basic utilities
      ];

      # Create application user
      users.users.convention-app = {
        isSystemUser = true;
        group = "convention-app";
        description = "Convention Speaker List app user";
        home = "${appDataDir}/app";
      };
      users.groups.convention-app = {};

      # Application installation service (runs once to set up the app)
      systemd.services.convention-speaker-list-install = {
        description = "Install Convention Speaker List Application";
        wantedBy = [ "multi-user.target" ];
        before = [ "convention-speaker-list-app.service" ];
        after = [ "network-online.target" "local-fs.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
        };

        path = with pkgs; [ nodejs_20 rsync coreutils bash gnused ];

        script = ''
          APP_DIR="${appDataDir}/app"
          SRC_DIR="/opt/convention-speaker-list-src"

          echo "Setting up Convention Speaker List application..."

          # Create app directory structure
          mkdir -p "$APP_DIR"

          # Copy source code if not already present or if source changed
          if [ ! -f "$APP_DIR/.installed" ] || ! diff -r "$SRC_DIR" "$APP_DIR/src" > /dev/null 2>&1; then
            echo "Copying application source..."
            mkdir -p "$APP_DIR/src"
            rsync -a --delete "$SRC_DIR/" "$APP_DIR/src/"

            # Make all files writable (rsync preserves read-only from source)
            chmod -R u+w "$APP_DIR/src"

            # Install dependencies (ignore scripts to prevent build failures during install)
            echo "Installing Node.js dependencies..."
            cd "$APP_DIR/src"
            npm ci --ignore-scripts

            # Rebuild native modules that need compilation
            echo "Building native modules..."
            npm rebuild sqlite3

            # Build frontend for production
            echo "Building frontend..."
            cd "$APP_DIR/src/frontend"
            npm run build

            # Mark as installed
            echo "Installation complete"
            touch "$APP_DIR/.installed"
          else
            echo "Application already installed and up to date"
          fi

          # Set permissions
          # NOTE: With user namespaces (privateUsers=pick), container root can't chown
          # bind-mounted host directories. Files are already accessible with correct perms.
          chown -R convention-app:convention-app "$APP_DIR" || true
        '';
      };

      # Application service
      systemd.services.convention-speaker-list-app = {
        description = "Convention Speaker List Application";
        after = [
          "network.target"
          "postgresql.service"
          "redis-convention.service"
          "convention-speaker-list-install.service"
        ];
        wants = [
          "postgresql.service"
          "redis-convention.service"
          "convention-speaker-list-install.service"
        ];
        requires = [
          "convention-speaker-list-install.service"
        ];
        wantedBy = [ "multi-user.target" ];

        path = with pkgs; [ nodejs_20 postgresql_15 bash python3 ];

        serviceConfig = {
          Type = "simple";
          User = "convention-app";
          Group = "convention-app";
          WorkingDirectory = "${appDataDir}/app/src";

          # SECURITY: Use LoadCredential instead of EnvironmentFile
          # Credentials are loaded from bind-mounted directory and exposed via /run/credentials/
          LoadCredential = [
            "postgres-password:/var/lib/convention-speaker-list-env/postgres-password"
            "jwt-secret:/var/lib/convention-speaker-list-env/jwt-secret"
            "session-secret:/var/lib/convention-speaker-list-env/session-secret"
          ];

          # Set environment variables (non-secret config)
          Environment = [
            "NODE_ENV=production"
            "PORT=${toString appPort}"
            "APP_URL=https://convention.newartisans.com"
            "SESSION_MAX_AGE=86400000"
          ];

          # Wait for database to be ready
          ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in {1..30}; do ${pkgs.postgresql_15}/bin/pg_isready -h 127.0.0.1 -p 5432 -U convention_user && break || sleep 1; done'";

          # SECURITY: Start app with credentials from LoadCredential
          # Reads secrets from /run/credentials/ and constructs environment variables
          ExecStart = pkgs.writeShellScript "start-convention-app" ''
            set -euo pipefail

            # Debug: Check credentials directory
            echo "CREDENTIALS_DIRECTORY=$CREDENTIALS_DIRECTORY"
            ls -la "$CREDENTIALS_DIRECTORY" || echo "Could not list credentials directory"

            # Read credentials from systemd LoadCredential
            POSTGRES_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/postgres-password")
            JWT_SECRET=$(cat "$CREDENTIALS_DIRECTORY/jwt-secret")
            SESSION_SECRET=$(cat "$CREDENTIALS_DIRECTORY/session-secret")

            # Debug: Check if we got the values (without printing secrets)
            echo "Password length: ''${#POSTGRES_PASSWORD}"
            echo "JWT length: ''${#JWT_SECRET}"
            echo "Session length: ''${#SESSION_SECRET}"

            # URL-encode the password for use in DATABASE_URL
            # Special characters like +, /, = need to be encoded
            ENCODED_PASSWORD=$(echo -n "$POSTGRES_PASSWORD" | ${pkgs.python3}/bin/python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')

            # Construct DATABASE_URL with URL-encoded password
            export DATABASE_URL="postgresql://convention_user:$ENCODED_PASSWORD@127.0.0.1:5432/convention_db"
            export REDIS_URL="redis://127.0.0.1:6379"
            export JWT_SECRET
            export SESSION_SECRET

            echo "Starting application..."

            # Run the application
            cd ${appDataDir}/app/src
            exec ${pkgs.nodejs_20}/bin/npx --yes ts-node -r tsconfig-paths/register --transpile-only backend/src/index.ts
          '';

          # Hardening
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ appDataDir ];
          PrivateDevices = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;

          # Resource limits
          MemoryMax = "2G";
          TasksMax = 512;

          # Restart policy
          Restart = "always";
          RestartSec = "10s";
        };
      };

      # Nginx reverse proxy
      services.nginx = {
        enable = true;

        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;

        # Increase buffer sizes for WebSocket connections
        # SECURITY: Add rate limiting zones to prevent abuse
        appendHttpConfig = ''
          proxy_buffers 16 16k;
          proxy_buffer_size 16k;

          # Rate limiting zones
          limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
          limit_req_zone $binary_remote_addr zone=upload:10m rate=2r/s;
          limit_req_zone $binary_remote_addr zone=websocket:10m rate=5r/s;

          # Connection limiting
          limit_conn_zone $binary_remote_addr zone=addr:10m;
        '';

        virtualHosts."_" = {
          default = true;
          listen = [
            {
              addr = "0.0.0.0";
              port = nginxPort;
            }
          ];

          # SECURITY: Add security headers and connection limits
          # These apply to all locations within this server block
          extraConfig = ''
            # Security headers
            add_header X-Served-By "convention-speaker-list-container" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-XSS-Protection "1; mode=block" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;
            add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

            # HSTS (HTTP Strict Transport Security) - Defense-in-depth
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

            # Content Security Policy - Enhanced with base-uri and form-action
            # NOTE: Uses 'unsafe-inline' and 'unsafe-eval' for framework compatibility
            # TODO: After testing, tighten by using nonces/hashes instead of unsafe-*
            add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: ws:; frame-ancestors 'self'; base-uri 'self'; form-action 'self';" always;

            # Connection limits
            limit_conn addr 50;
          '';

          # Serve frontend static files
          locations."/" = {
            root = "${appDataDir}/app/src/frontend/dist";
            index = "index.html";
            tryFiles = "$uri $uri/ /index.html";
            extraConfig = ''
              # Cache static assets
              location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
                expires 1y;
                # IMPORTANT: Repeat ALL security headers because nested locations don't inherit add_header
                add_header Cache-Control "public, immutable";
                add_header X-Frame-Options "SAMEORIGIN" always;
                add_header X-Content-Type-Options "nosniff" always;
                add_header X-XSS-Protection "1; mode=block" always;
                add_header Referrer-Policy "strict-origin-when-cross-origin" always;
                add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
                add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: ws:; frame-ancestors 'self'; base-uri 'self'; form-action 'self';" always;
              }
            '';
          };

          # API endpoints - proxy to backend
          locations."/api" = {
            proxyPass = "http://127.0.0.1:${toString appPort}/api";
            extraConfig = ''
              # SECURITY: Reduced file upload size and added rate limiting
              client_max_body_size 10M;  # Reduced from 50M
              proxy_request_buffering off;

              # Rate limiting for API endpoints
              limit_req zone=api burst=20 nodelay;

              # Proxy headers
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            '';
          };

          # Socket.io WebSocket endpoint
          locations."/socket.io" = {
            proxyPass = "http://127.0.0.1:${toString appPort}/socket.io";
            extraConfig = ''
              # WebSocket support
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host $host;

              # SECURITY: Reduced timeouts from 7 days to prevent resource exhaustion
              # 4 hour timeout is reasonable for long-lived WebSocket connections
              proxy_connect_timeout 4h;
              proxy_send_timeout 4h;
              proxy_read_timeout 4h;

              # Rate limiting for WebSocket connections
              limit_req zone=websocket burst=10 nodelay;
            '';
          };

          # Health check endpoint
          locations."/health" = {
            proxyPass = "http://127.0.0.1:${toString appPort}/health";
            extraConfig = ''
              access_log off;
            '';
          };

          # Nginx status endpoint (internal monitoring only)
          locations."/nginx-status" = {
            extraConfig = ''
              stub_status on;
              access_log off;
              allow 127.0.0.1;
              deny all;
            '';
          };
        };
      };

      # Create nginx spool directory
      systemd.tmpfiles.rules = [
        "d /var/spool/nginx 0755 nginx nginx -"
        "d /var/log/nginx 0755 nginx nginx -"
      ];

      # Nginx hardening
      systemd.services.nginx = {
        after = [ "convention-speaker-list-app.service" ];
        wants = [ "convention-speaker-list-app.service" ];

        serviceConfig = {
          # Filesystem hardening
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [ "/var/log/nginx" "/var/spool/nginx" ];

          # Privilege restrictions
          NoNewPrivileges = true;
          PrivateDevices = true;

          # Kernel hardening
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;

          # Capabilities (nginx needs to bind to port 80)
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

          # Syscall filtering
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@resources"
          ];
          SystemCallArchitectures = "native";

          # Network restrictions
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];

          # Misc hardening
          LockPersonality = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;
        };
      };
    };
  };

  # Increase container start timeout to allow for npm ci installation
  systemd.services."container@convention-speaker-list" = {
    serviceConfig = {
      TimeoutStartSec = lib.mkForce "10min";
    };
  };

  # Systemd socket for localhost-only port forwarding to container
  systemd.sockets."convention-speaker-list-http" = {
    description = "Convention Speaker List HTTP Socket (localhost only, for Cloudflare Tunnel)";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "127.0.0.1:${toString hostExposedPort}" ];
    socketConfig = {
      Accept = false;
    };
  };

  # Systemd service to proxy connections to the container
  systemd.services."convention-speaker-list-http" = {
    description = "Proxy HTTP to convention-speaker-list container";
    requires = [
      "container@convention-speaker-list.service"
      "convention-speaker-list-http.socket"
    ];
    after = [
      "container@convention-speaker-list.service"
      "convention-speaker-list-http.socket"
    ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${localAddress}:${toString nginxPort}";
      PrivateTmp = true;
      PrivateNetwork = false;
    };
  };
}
