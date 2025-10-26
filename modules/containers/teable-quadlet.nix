{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "teable";
      image = "ghcr.io/teableio/teable-community:latest";
      port = 3001;
      requiresPostgres = true;

      # SOPS secret containing all Teable environment variables
      secrets = {
        env = "teable-env";
      };

      environments = {
        # PostgreSQL Configuration (minimal set matching official CE deployment)
        POSTGRES_HOST = "10.88.0.1";
        POSTGRES_PORT = "5432";
        POSTGRES_DB = "teable";
        POSTGRES_USER = "teable";

        # Application Configuration (required for public URL)
        PUBLIC_ORIGIN = "https://teable.vulcan.lan";

        # Timezone
        TIMEZONE = "America/Los_Angeles";
      };

      publishPorts = [ "127.0.0.1:3001:3000/tcp" ];

      volumes = [
        "/var/lib/teable:/app/.assets:rw"
      ];

      nginxVirtualHost = {
        enable = true;
        proxyPass = "http://127.0.0.1:3001/";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          client_max_body_size 100M;
          proxy_read_timeout 5m;
          proxy_connect_timeout 5m;
          proxy_send_timeout 5m;
        '';
      };

      tmpfilesRules = [
        "d /var/lib/teable 0755 root root -"
      ];
    })
  ];

  # Additional SOPS secret for PostgreSQL user setup
  # (teable-env is automatically declared by mkQuadletService)
  sops.secrets."teable-postgres-password" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "postgres";
    restartUnits = [ "postgresql-teable-setup.service" ];
  };

  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    3001  # teable
  ];
}
