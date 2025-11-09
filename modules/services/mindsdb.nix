{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;

  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
{
  imports = [
    # PostgreSQL password setup for mindsdb user
    (mkPostgresUserSetup {
      user = "mindsdb";
      database = "mindsdb";
      secretPath = config.sops.secrets."mindsdb/db-password".path;
      dependentService = "mindsdb.service";
    })

    # Quadlet container service
    (mkQuadletService {
      name = "mindsdb";
      image = "docker.io/mindsdb/mindsdb:latest";
      port = 47334;
      requiresPostgres = true;
      containerUser = "mindsdb";  # Run rootless as dedicated mindsdb user

      # Health checks disabled - will verify service health via Prometheus/Nagios
      healthCheck = {
        enable = false;
      };
      enableWatchdog = false;

      # Environment file with secrets (DB_PASSWORD)
      environmentFiles = [
        config.sops.secrets."mindsdb/env".path
      ];

      environments = {
        # MindsDB Configuration
        MINDSDB_DOCKER_ENV = "True";

        # Metadata Storage Configuration (PostgreSQL)
        # For rootless containers with slirp4netns, use localhost to reach host
        MINDSDB_STORAGE_ENGINE = "postgres";
        MINDSDB_STORAGE_HOST = "127.0.0.1";  # slirp4netns allows localhost access to host
        MINDSDB_STORAGE_PORT = "5432";
        MINDSDB_STORAGE_USER = "mindsdb";
        MINDSDB_STORAGE_DB = "mindsdb";
        # MINDSDB_STORAGE_PASSWORD comes from environmentFiles

        # Redis Configuration (use existing Redis service)
        REDIS_HOST = "127.0.0.1";  # slirp4netns allows localhost access to host
        REDIS_PORT = "6379";

        # API Configuration
        MINDSDB_API_SERVER_HOST = "0.0.0.0";
        MINDSDB_API_SERVER_PORT = "47334";

        # Timezone
        TZ = "America/Los_Angeles";
      };

      publishPorts = [ "127.0.0.1:47334:47334/tcp" ];

      volumes = [
        "/var/lib/mindsdb:/root/mindsdb_storage:rw"
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:47334/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 100M;
          proxy_read_timeout 300s;
          proxy_connect_timeout 300s;
          proxy_send_timeout 300s;

          # MindsDB API headers
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };

      tmpfilesRules = [
        "d /var/lib/mindsdb 0755 root root -"
      ];
    })
  ];

  # SOPS secrets for MindsDB
  sops.secrets = {
    # PostgreSQL password for database setup
    "mindsdb/db-password" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0440";
      owner = "postgres";
      restartUnits = [ "postgresql-mindsdb-setup.service" ];
    };

    # MindsDB environment variables file
    # This secret file should contain:
    # MINDSDB_STORAGE_PASSWORD=...
    "mindsdb/env" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "mindsdb";
      restartUnits = [ "mindsdb.service" ];
    };
  };

  # PostgreSQL database and user for MindsDB
  services.postgresql = {
    ensureDatabases = [ "mindsdb" ];
    ensureUsers = [
      {
        name = "mindsdb";
        ensureDBOwnership = true;
      }
    ];
  };

  # Open firewall for MindsDB on podman interface
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    47334  # mindsdb
  ];

  # Ensure Redis is available for MindsDB
  # Using the default Redis instance
  services.redis.servers."" = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";
  };
}
