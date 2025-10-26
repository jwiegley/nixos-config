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

      environmentFiles = [
        "/run/secrets/teable-secrets"
      ];

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
        "/tank/Services/teable:/app/.assets:rw"
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
        "d /tank/Services/teable 0755 root root -"
      ];
    })
  ];


  # SOPS secrets configuration
  # PostgreSQL password for database authentication
  sops.secrets = {
    "teable-postgres-password" = {
      mode = "0400";
      owner = "postgres";
      restartUnits = [ "podman-teable.service" "teable-secrets-generator.service" ];
    };
  };

  # Generate combined secrets environment file for container
  systemd.services.teable-secrets-generator = {
    description = "Generate Teable secrets environment file";
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-teable.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Read PostgreSQL password
      POSTGRES_PASSWORD=$(cat ${config.sops.secrets."teable-postgres-password".path})

      # URL-encode the password for PRISMA_DATABASE_URL
      URL_ENCODED_PASSWORD=$(${pkgs.python3}/bin/python3 -c 'import urllib.parse; import sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$POSTGRES_PASSWORD")

      # Generate secrets file (minimal set for Community Edition)
      SECRETS_FILE="/run/secrets/teable-secrets"
      mkdir -p "$(dirname "$SECRETS_FILE")"

      cat > "$SECRETS_FILE" <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
PRISMA_DATABASE_URL=postgresql://teable:$URL_ENCODED_PASSWORD@10.88.0.1:5432/teable
EOF

      chmod 400 "$SECRETS_FILE"
    '';
  };



  networking.firewall.interfaces.podman0.allowedTCPPorts = [
    3001  # teable
  ];
}
