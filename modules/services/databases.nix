{ config, lib, pkgs, secrets, ... }:

let
  # Import helper functions
  common = import ../lib/common.nix { inherit secrets; };
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # Set up PostgreSQL passwords for database users
    (mkPostgresUserSetup {
      user = "teable";
      database = "teable";
      secretPath = config.sops.secrets."teable-postgres-password".path;
      dependentService = "podman-teable.service";
    })
    (mkPostgresUserSetup {
      user = "budgetboard";
      database = "budgetboard";
      secretPath = config.sops.secrets."budgetboard/database-password".path;
      dependentService = "podman-budget-board-server.service";
    })
    (mkPostgresUserSetup {
      user = "nocobase";
      database = "nocobase";
      secretPath = config.sops.secrets."nocobase-db-password".path;
      dependentService = "podman-nocobase.service";
    })
    (mkPostgresUserSetup {
      user = "rspamd";
      database = "rspamd";
      secretPath = config.sops.secrets."rspamd-db-password".path;
      dependentService = "rspamd.service";
    })
    (mkPostgresUserSetup {
      user = "mailarchiver";
      database = "mailarchiver";
      secretPath = config.sops.secrets."mailarchiver-db-password".path;
      dependentService = "podman-mailarchiver.service";
    })
    (mkPostgresUserSetup {
      user = "openproject";
      database = "openproject";
      secretPath = config.sops.secrets."openproject-db-password".path;
      dependentService = "podman-openproject.service";
    })
    (mkPostgresUserSetup {
      user = "shlink";
      database = "shlink";
      secretPath = config.sops.secrets."shlink-db-password".path;
      dependentService = "podman-shlink.service";
    })
  ];

  services = {
    postgresql = {
      enable = true;
      enableTCPIP = true;

      package = pkgs.postgresql_17.withPackages (p: [ p.pgvector ]);

      settings = {
        port = 5432;

        # Connection settings
        max_connections = 200;  # Increased from default 100 to handle bulk operations

        # Network Security - Listen on all interfaces (auth rules control access)
        listen_addresses = lib.mkForce "*";
        ssl = true;
        ssl_cert_file = "/var/lib/postgresql/certs/server.crt";
        ssl_key_file = "/var/lib/postgresql/certs/server.key";
        ssl_ca_file = "/var/lib/postgresql/certs/root_ca.crt";
        ssl_ciphers = "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4:!3DES";
        ssl_prefer_server_ciphers = true;
        ssl_min_protocol_version = "TLSv1.2";
        ssl_max_protocol_version = "TLSv1.3";

        # Authentication settings
        password_encryption = "scram-sha-256";

        # Session timeouts
        # Automatically terminate connections that are idle in a transaction for too long
        # This prevents locks from being held indefinitely by abandoned transactions
        idle_in_transaction_session_timeout = "10min";  # 10 minutes

        # Logging configuration for troubleshooting
        # Log slow queries (longer than 1 second)
        log_min_duration_statement = 1000;  # milliseconds

        # Log lock waits that take longer than deadlock_timeout
        log_lock_waits = true;
        deadlock_timeout = "1s";  # How long to wait before checking for deadlock

        # Log checkpoints (helps identify I/O bottlenecks)
        log_checkpoints = true;

        # Log autovacuum activity (only log runs taking longer than 10 seconds)
        log_autovacuum_min_duration = 10000;  # Log autovacuum runs > 10s to reduce noise

        # Include more context in logs
        log_line_prefix = "%m [%p] %q%u@%d ";  # timestamp [pid] app_name user@database
      };

      ensureDatabases = [
        "litellm"
        "open_webui"
        "wallabag"
        "teable"
        "budgetboard"
        "nocobase"
        "gitea"
        "mailarchiver"
        "openproject"
        "shlink"
      ];
      ensureUsers = [
        { name = "postgres"; }
        { name = "johnw"; }
        { name = "litellm"; }
        { name = "wallabag"; }
        {
          name = "teable";
          ensureDBOwnership = true;
        }
        {
          name = "budgetboard";
          ensureDBOwnership = true;
        }
        {
          name = "nocobase";
          ensureDBOwnership = true;
        }
        {
          name = "mailarchiver";
          ensureDBOwnership = true;
        }
        {
          name = "openproject";
          ensureDBOwnership = true;
        }
        {
          name = "shlink";
          ensureDBOwnership = true;
        }
        {
          name = "open_webui";
          ensureDBOwnership = true;
        }
      ];

      authentication = lib.mkOverride 10 ''
        # TYPE  DATABASE  USER  ADDRESS         METHOD  OPTIONS

        # Unix socket connections - require password for non-postgres users
        local   all       postgres                peer
        # Immich uses peer auth (NixOS native module)
        local   immich    immich                  peer
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
  };

  services.nginx.virtualHosts."postgres.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/postgres.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/postgres.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:5050/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header X-Script-Name "";
        proxy_set_header Host $host;
        proxy_redirect off;
      '';
    };
  };

  # Optimize LiteLLM database with performance indexes
  systemd.services.postgresql-litellm-optimize = {
    description = "Create performance indexes for LiteLLM database";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for PostgreSQL to be ready
      until ${config.services.postgresql.package}/bin/psql -d litellm -c "SELECT 1" 2>/dev/null; do
        sleep 1
      done

      # Create index on api_key column for faster query performance
      # This prevents slow sequential scans on the large LiteLLM_SpendLogs table
      ${config.services.postgresql.package}/bin/psql -d litellm -c \
        'CREATE INDEX CONCURRENTLY IF NOT EXISTS "LiteLLM_SpendLogs_api_key_idx" ON "LiteLLM_SpendLogs" (api_key);'

      # Update table statistics after index creation
      ${config.services.postgresql.package}/bin/psql -d litellm -c \
        'ANALYZE "LiteLLM_SpendLogs";'
    '';
  };

  # Optimize mailarchiver database with performance indexes
  # Fixes PostgreSQLSlowQueries alert caused by sequential scans on ArchivedEmails
  systemd.services.postgresql-mailarchiver-optimize = {
    description = "Create performance indexes for mailarchiver database";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for PostgreSQL to be ready
      until ${config.services.postgresql.package}/bin/psql -d mailarchiver -c "SELECT 1" 2>/dev/null; do
        sleep 1
      done

      # Check if the mail_archiver schema and ArchivedEmails table exist
      # (they are created by the application on first run via EF Core migrations)
      if ${config.services.postgresql.package}/bin/psql -d mailarchiver -tAc \
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'mail_archiver' AND table_name = 'ArchivedEmails'" | grep -q 1; then

        # Create composite index for MessageId + MailAccountId lookups
        # The application frequently queries by these columns to check for duplicate emails
        # Without this index, queries do expensive sequential scans on 200k+ rows
        ${config.services.postgresql.package}/bin/psql -d mailarchiver -c \
          'CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_archivedemails_mailaccountid_messageid ON mail_archiver."ArchivedEmails" ("MailAccountId", "MessageId");'

        # Update table statistics after index creation
        ${config.services.postgresql.package}/bin/psql -d mailarchiver -c \
          'ANALYZE mail_archiver."ArchivedEmails";'
      fi
    '';
  };

  # CRITICAL FIX: PostgreSQL must wait for network devices before starting
  # Problem: PostgreSQL starts before network interfaces are fully up
  # Result: PostgreSQL fails to bind to configured addresses
  # - podman0: PostgreSQL fails to bind to 10.88.0.1 (causes litellm/wallabag to fail pg_isready)
  # - end0: PostgreSQL fails to bind to 192.168.1.2 (causes external postgres.vulcan.lan connections to fail)
  systemd.services.postgresql = {
    after = [ "sys-subsystem-net-devices-podman0.device" "sys-subsystem-net-devices-end0.device" ];
    requires = [ "sys-subsystem-net-devices-podman0.device" "sys-subsystem-net-devices-end0.device" ];
  };

  networking.firewall = {
    allowedTCPPorts =
      lib.mkIf config.services.postgresql.enable [ 5432 ];
    interfaces.podman0.allowedTCPPorts =
      lib.mkIf config.services.postgresql.enable [ 5432 ];
  };
}
