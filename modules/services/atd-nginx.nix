{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # ATD Nginx Virtual Host Configuration
  # ============================================================================

  # Nginx upstream for ATD web interface
  services.nginx.upstreams.atd = {
    servers = {
      "127.0.0.1:9281" = {
        max_fails = 3;
        fail_timeout = "30s";
      };
    };
    extraConfig = ''
      keepalive 8;
      keepalive_timeout 60s;
    '';
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."atd.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/atd.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/atd.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://atd/";
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Standard timeouts
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
      '';
    };

    # Health check endpoint
    locations."/health" = {
      proxyPass = "http://atd/health";
      extraConfig = ''
        # Allow health checks from monitoring systems
        allow 127.0.0.1;
        allow 192.168.0.0/16;
        deny all;
      '';
    };
  };

  # Certificate generation script service
  systemd.services.atd-certificate = {
    description = "Generate ATD TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [ pkgs.openssl pkgs.step-cli ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/atd.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/atd.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Create a self-signed certificate as a fallback
      echo "Creating temporary self-signed certificate for atd.vulcan.lan"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=atd.vulcan.lan" \
        -addext "subjectAltName=DNS:atd.vulcan.lan"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown nginx:nginx "$CERT_FILE" "$KEY_FILE"

      echo "Certificate generated successfully"
    '';
  };
}
