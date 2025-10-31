{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "nocobase";
      image = "docker.io/nocobase/nocobase:latest";
      port = 13000;
      requiresPostgres = true;

      # Enable health checks
      healthCheck = {
        enable = true;
        type = "exec";
        interval = "30s";
        timeout = "10s";
        startPeriod = "90s";  # NocoBase needs time to initialize
        retries = 3;
        execCommand = "node -e \"require('http').get('http://localhost:80/', (res) => process.exit(res.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))\"";
      };
      enableWatchdog = false;  # Disabled - requires sdnotify

      # Bind to both localhost and podman gateway for container access
      publishPorts = [
        "127.0.0.1:13000:80/tcp"
        "10.88.0.1:13000:80/tcp"
      ];

      secrets = {
        nocobaseEnv = "nocobase-secrets";
      };

      volumes = [
        "/var/lib/nocobase:/app/nocobase/storage"
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:13000/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 100M;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
          proxy_connect_timeout 60s;
        '';
      };

      # Wait for PostgreSQL nocobase user to be set up
      extraUnitConfig = {
        After = [ "postgresql-nocobase-setup.service" ];
      };

      # Custom pg_isready with nocobase user
      extraServiceConfig = {
        ExecStartPre = lib.mkForce [
          "${pkgs.postgresql}/bin/pg_isready -h 10.88.0.1 -p 5432 -U nocobase -d nocobase -t 30"
        ];
      };

      tmpfilesRules = [
        "d /var/lib/nocobase 0755 root root -"
      ];
    })
  ];

  # Additional SOPS secret for PostgreSQL user setup
  # (nocobase-secrets is automatically declared by mkQuadletService)
  sops.secrets."nocobase-db-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "postgres";
    restartUnits = [ "postgresql-nocobase-setup.service" ];
  };

  # Firewall rules for podman0 interface
  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    13000  # nocobase
  ];
}
