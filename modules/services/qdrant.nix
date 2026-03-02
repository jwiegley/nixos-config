{
  config,
  lib,
  pkgs,
  ...
}:

{
  # ============================================================================
  # Qdrant Vector Search Engine
  # ============================================================================
  # Qdrant is a self-contained vector database with no external DB dependencies.
  # Data stored at /var/lib/qdrant/ (managed by systemd StateDirectory).
  # API key injected via QDRANT__SERVICE__API_KEY environment variable.
  # Metrics exposed at http://localhost:6333/metrics (requires Bearer auth).
  # Health checks at /healthz, /livez, /readyz (no auth required).

  # SOPS secret for Qdrant API key authentication
  # group = "prometheus" so Prometheus can read it for scraping via credentials_file
  sops.secrets."qdrant/api-key" = {
    owner = "root";
    group = "prometheus";
    mode = "0440";
    restartUnits = [ "qdrant.service" ];
  };

  # Native NixOS Qdrant service
  services.qdrant = {
    enable = true;
    settings = {
      storage = {
        storage_path = "/var/lib/qdrant/storage";
        snapshots_path = "/var/lib/qdrant/snapshots";
      };
      service = {
        host = "127.0.0.1";
        http_port = 6333;
        grpc_port = 6334;
        enable_tls = false; # TLS terminated by nginx
      };
      telemetry = {
        disabled = true;
      };
      log_level = "INFO";
    };
  };

  # Inject API key securely via LoadCredential + EnvironmentFile
  # Avoids storing the secret in the Nix store or readable systemd unit files
  systemd.services.qdrant = {
    serviceConfig = {
      LoadCredential = [
        "api-key:${config.sops.secrets."qdrant/api-key".path}"
      ];
      RuntimeDirectory = "qdrant-env";
      RuntimeDirectoryMode = "0750";
      EnvironmentFile = "-/run/qdrant-env/env";
    };
    preStart = lib.mkAfter ''
      echo "QDRANT__SERVICE__API_KEY=$(cat "$CREDENTIALS_DIRECTORY/api-key")" \
        > /run/qdrant-env/env
      chmod 600 /run/qdrant-env/env
    '';
  };

  # Bootstrap TLS certificate (self-signed placeholder)
  # Replace with a proper step-ca cert:
  #   sudo /etc/nixos/certs/renew-certificate.sh "qdrant.vulcan.lan" \
  #     -o "/var/lib/nginx-certs" -d 365 --owner "nginx:nginx"
  systemd.services.qdrant-certificate = {
    description = "Generate Qdrant TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [ pkgs.openssl ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/qdrant.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/qdrant.vulcan.lan.key"

      # Exit early if cert is valid for >30 days
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate valid for >30 days, skipping generation"
          exit 0
        fi
      fi

      # Create self-signed bootstrap certificate
      echo "Creating bootstrap self-signed certificate for qdrant.vulcan.lan"
      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=qdrant.vulcan.lan" \
        -addext "subjectAltName=DNS:qdrant.vulcan.lan"

      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown -R nginx:nginx "$CERT_DIR"

      echo "Bootstrap cert created. Replace with step-ca cert:"
      echo "  sudo /etc/nixos/certs/renew-certificate.sh qdrant.vulcan.lan \\"
      echo "    -o /var/lib/nginx-certs -d 365 --owner nginx:nginx"
    '';
  };

  # Nginx upstream with keepalive and retry logic
  services.nginx.upstreams."qdrant" = {
    servers = {
      "127.0.0.1:6333" = {
        max_fails = 0;
      };
    };
    extraConfig = ''
      keepalive 16;
      keepalive_timeout 60s;
    '';
  };

  # Nginx HTTPS virtual host for Qdrant
  services.nginx.virtualHosts."qdrant.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/qdrant.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/qdrant.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://qdrant/";
      extraConfig = ''
        # Retry on transient backend errors
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Standard proxy headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Generous timeouts for large vector upsert operations
        proxy_connect_timeout 60s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;

        # Allow large payloads for bulk vector uploads
        client_max_body_size 100M;
      '';
    };
  };

  # Allow Qdrant ports on loopback (nginx proxies externally)
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    6333 # Qdrant HTTP REST API
    6334 # Qdrant gRPC API
  ];
}
