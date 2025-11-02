{ config, lib, pkgs, secrets, ... }:

let
  # Import helper functions
  common = import ../lib/common.nix { inherit secrets; };
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;

  ntopngPort = 8081;
  ntopngDataDir = "/var/lib/ntopng";

  # Configuration file for ntopng (using command-line option format)
  ntopngConfig = pkgs.writeText "ntopng.conf" ''
    -i=end0
    -i=podman0
    -i=wlp1s0f0
    -w=${toString ntopngPort}
    --http-bind-address=127.0.0.1
    -d=${ntopngDataDir}
    -r=127.0.0.1:6380
    -F=postgres
    --db-host=127.0.0.1
    --db-port=5432
    --db-username=ntopng
    --db-name=ntopng
    --disable-autologout
    --disable-login=1
    --dns-mode=1
    --community
  '';

in
{
  imports = [
    # Set up PostgreSQL password for ntopng database user
    (mkPostgresUserSetup {
      user = "ntopng";
      database = "ntopng";
      secretPath = config.sops.secrets."ntopng-db-password".path;
      dependentService = "ntopng.service";
    })
  ];

  # SOPS secrets for ntopng
  sops.secrets."ntopng-db-password" = {
    owner = "ntopng";
    group = "ntopng";
    mode = "0400";
    restartUnits = [ "ntopng.service" ];
  };

  # PostgreSQL database setup
  services.postgresql = {
    ensureDatabases = [ "ntopng" ];
    ensureUsers = [
      {
        name = "ntopng";
        ensureDBOwnership = true;
      }
    ];
  };

  # Redis instance for ntopng caching
  services.redis.servers.ntopng = {
    enable = true;
    port = 6380;
    bind = "127.0.0.1";
    settings = {
      protected-mode = "yes";
      maxmemory = "256mb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # Create ntopng user and group
  users.users.ntopng = {
    isSystemUser = true;
    group = "ntopng";
    home = ntopngDataDir;
    createHome = true;
  };

  users.groups.ntopng = {};

  # ntopng systemd service
  systemd.services.ntopng = {
    description = "ntopng Network Traffic Monitoring";
    after = [ "network.target" "postgresql.service" "redis-ntopng.service" ];
    requires = [ "redis-ntopng.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "ntopng";
      Group = "ntopng";
      ExecStart = "${pkgs.ntopng}/bin/ntopng ${ntopngConfig}";
      Restart = "on-failure";
      RestartSec = "10s";

      # Security hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ ntopngDataDir ];

      # Network capabilities (required for packet capture)
      AmbientCapabilities = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
    };

    # Environment with database password
    environment = {
      PGPASSWORD = "\${CREDENTIALS_DIRECTORY}/db-password";
    };

    serviceConfig.LoadCredential = [
      "db-password:${config.sops.secrets."ntopng-db-password".path}"
    ];
  };

  # Nginx virtual host for ntopng
  services.nginx.virtualHosts."ntopng.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/ntopng.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/ntopng.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString ntopngPort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;

        # Increase timeouts for long-running queries
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
      '';
    };
  };

  # Firewall: ntopng web interface only accessible via nginx reverse proxy
  # No external ports needed as ntopng binds to localhost only

}
