{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Cockpit web-based server management interface
  # Provides system administration through a modern web interface
  services.cockpit = {
    enable = true;
    port = 9099; # Use 9099 to avoid conflict with Prometheus on 9090

    # Configure Cockpit settings
    settings = {
      WebService = {
        # Allow connections from nginx reverse proxy
        Origins = lib.mkForce "https://cockpit.vulcan.lan wss://cockpit.vulcan.lan";
        # Disable direct HTTP/HTTPS - nginx will handle SSL
        AllowUnencrypted = true;
        # Set URL root for reverse proxy
        UrlRoot = "/";
      };

      Session = {
        # Session timeout in minutes
        IdleTimeout = 15;
      };
    };
  };

  # Install additional Cockpit packages
  environment.systemPackages = with pkgs; [
    cockpit
  ];

  # Enable cockpit.socket for socket activation
  # The socket starts cockpit on-demand when accessed
  # Override to use IPv4 only to avoid "Address family not supported" error
  # The empty string "" clears the upstream ListenStream before adding ours
  systemd.sockets.cockpit = {
    wantedBy = [ "sockets.target" ];
    listenStreams = lib.mkForce [
      ""
      "127.0.0.1:${toString config.services.cockpit.port}"
    ];
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."cockpit.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/cockpit.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/cockpit.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:9099/";
      proxyWebsockets = true;
      extraConfig = ''
        # Pass through original request information
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Server $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Required for Cockpit to work behind reverse proxy
        proxy_set_header Host $host;

        # Increase buffer sizes for Cockpit
        proxy_buffering off;
        proxy_buffer_size 4k;

        # Timeouts for long-running operations
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
      '';
    };
  };

  # Certificate generation script service
  systemd.services.cockpit-certificate = {
    description = "Generate Cockpit TLS certificate";
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

      CERT_FILE="$CERT_DIR/cockpit.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/cockpit.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # For now, create a self-signed certificate as a fallback
      # This will be replaced once step-ca certificate generation is working
      echo "Creating temporary self-signed certificate for cockpit.vulcan.lan"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=cockpit.vulcan.lan" \
        -addext "subjectAltName=DNS:cockpit.vulcan.lan"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown -R nginx:nginx "$CERT_DIR"

      echo "Certificate generated successfully"
    '';
  };

  # Don't open firewall ports - access via nginx reverse proxy only
  # Cockpit binds to localhost:9090 and nginx proxies HTTPS traffic

  # Ensure johnw user can access cockpit (wheel group has admin access)
  # No additional configuration needed - PAM authentication uses system users
}
