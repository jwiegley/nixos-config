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
      user = "nextcloud";
      database = "nextcloud";
      secretPath = config.sops.secrets."nextcloud-db-password".path;
      dependentService = "nextcloud-setup.service";
    })
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

        # Network Security - Restrict to specific interfaces
        listen_addresses = lib.mkForce "localhost,192.168.1.2,10.88.0.1";
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
      };

      ensureDatabases = [
        "litellm"
        "wallabag"
        "nextcloud"
        "teable"
        "budgetboard"
      ];
      ensureUsers = [
        { name = "postgres"; }
        { name = "johnw"; }
        { name = "litellm"; }
        { name = "wallabag"; }
        {
          name = "nextcloud";
          ensureDBOwnership = true;
        }
        {
          name = "teable";
          ensureDBOwnership = true;
        }
        {
          name = "budgetboard";
          ensureDBOwnership = true;
        }
      ];

      authentication = lib.mkOverride 10 ''
        # TYPE  DATABASE  USER  ADDRESS         METHOD  OPTIONS

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
