# Speedtest Tracker - System Configuration
#
# Quadlet container: Managed by Home Manager
#   - /etc/nixos/modules/users/home-manager/speedtest-tracker.nix
#
# This file: Redis service, Nginx virtual host, SOPS secrets, firewall rules
#
# Access: https://speedtracker.vulcan.lan
#
# Database: PostgreSQL (speedtest_tracker database, speedtest_tracker user) - configured in databases.nix
# Cache: Redis on port 6387

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

{
  # ============================================================================
  # Data Directory
  # ============================================================================

  systemd.tmpfiles.rules = [
    "d /var/lib/containers/speedtest-tracker/config 0755 speedtest-tracker speedtest-tracker -"
  ];

  # ============================================================================
  # SOPS Secrets
  # ============================================================================

  sops.secrets = {
    # Database password for PostgreSQL password setup
    "speedtest-tracker-db-password" = {
      sopsFile = config.sops.defaultSopsFile;
      owner = "postgres";
      group = "postgres";
      mode = "0400";
    };

    # Container environment secrets (APP_KEY and DB_PASSWORD in env format)
    "speedtest-tracker-secrets" = {
      sopsFile = config.sops.defaultSopsFile;
      mode = "0400";
      owner = "speedtest-tracker";
      path = "/run/secrets-speedtest-tracker/speedtest-tracker-secrets";
      restartUnits = [ "podman-speedtest-tracker.service" ];
    };
  };

  # ============================================================================
  # Redis Server for Speedtest Tracker
  # ============================================================================

  services.redis.servers.speedtest-tracker = {
    enable = true;
    port = 6387;
    bind = "127.0.0.1";
    settings = {
      protected-mode = "yes";
      maxmemory = "64mb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # ============================================================================
  # Nginx Virtual Host
  # ============================================================================

  services.nginx.virtualHosts."speedtracker.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/speedtracker.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/speedtracker.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8765/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 10M;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_connect_timeout 30s;
      '';
    };
  };

  # Certificate generation for Speedtest Tracker web interface
  systemd.services.speedtest-tracker-certificate = {
    description = "Generate Speedtest Tracker TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [
      pkgs.openssl
      pkgs.step-cli
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/speedtracker.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/speedtracker.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Create self-signed certificate as fallback for nginx
      echo "Creating temporary self-signed certificate for speedtracker.vulcan.lan"
      echo "Generate proper certificate with: sudo /etc/nixos/certs/renew-certificate.sh speedtracker.vulcan.lan -o /var/lib/nginx-certs -d 365 --owner root:nginx"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=speedtracker.vulcan.lan" \
        -addext "subjectAltName=DNS:speedtracker.vulcan.lan"

      # Set proper permissions for nginx
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown nginx:nginx "$CERT_FILE" "$KEY_FILE"

      echo "Certificate generated successfully"
    '';
  };

  # ============================================================================
  # Firewall Rules
  # ============================================================================

  networking.firewall.interfaces."lo".allowedTCPPorts = [
    8765 # speedtest-tracker web
    6387 # redis[speedtest-tracker]
  ];
}
