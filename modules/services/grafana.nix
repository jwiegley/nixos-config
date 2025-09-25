{ config, lib, pkgs, ... }:

{
  # Grafana visualization server for Prometheus metrics
  services.grafana = {
    enable = true;

    # Bind only to localhost - nginx will proxy
    settings = {
      server = {
        # Only listen on localhost
        http_addr = "127.0.0.1";
        http_port = 3000;

        # Configure for reverse proxy
        domain = "grafana.vulcan.lan";
        root_url = "https://grafana.vulcan.lan";
        serve_from_sub_path = false;

        # Security headers
        enable_gzip = true;
      };

      # Security settings
      security = {
        # Disable signups
        disable_gravatar = true;
        allow_embedding = false;
        cookie_secure = true;
        cookie_samesite = "strict";
        strict_transport_security = true;
        strict_transport_security_max_age_seconds = 31536000;
        strict_transport_security_preload = true;
        content_security_policy = true;
      };

      # Anonymous access for read-only viewing (optional)
      "auth.anonymous" = {
        enabled = false;  # Set to true if you want read-only public access
        org_name = "Main Org.";
        org_role = "Viewer";
      };

      # Database settings (uses local SQLite by default)
      database = {
        type = "sqlite3";
        path = "/var/lib/grafana/data/grafana.db";
      };

      # Analytics and telemetry
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
    };

    # Automatic provisioning of data sources
    provision = {
      enable = true;

      datasources.settings = {
        apiVersion = 1;

        # Configure Prometheus as default data source
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://localhost:${toString config.services.prometheus.port}";
            isDefault = true;
            editable = false;
            jsonData = {
              timeInterval = "15s";
              queryTimeout = "60s";
              httpMethod = "POST";
            };
          }
        ];

        # Clean up removed data sources
        deleteDatasources = [];
      };

      # Dashboard provisioning
      dashboards.settings = {
        apiVersion = 1;

        providers = [
          {
            name = "default";
            orgId = 1;
            type = "file";
            disableDeletion = false;
            updateIntervalSeconds = 10;
            allowUiUpdates = true;
            options = {
              path = "/var/lib/grafana/dashboards";
            };
          }
        ];
      };
    };
  };

  # Create dashboard directory and populate with JSON dashboards
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana/dashboards 0755 grafana grafana -"
  ];

  # Download and install popular dashboards
  system.activationScripts.grafana-dashboards = {
    text = ''
      DASHBOARD_DIR="/var/lib/grafana/dashboards"

      # Create directory if it doesn't exist
      mkdir -p "$DASHBOARD_DIR"

      # Node Exporter Full dashboard (ID: 1860)
      if [ ! -f "$DASHBOARD_DIR/node-exporter-full.json" ]; then
        echo "Downloading Node Exporter Full dashboard..."
        ${pkgs.curl}/bin/curl -sSL \
          "https://grafana.com/api/dashboards/1860/revisions/latest/download" \
          -o "$DASHBOARD_DIR/node-exporter-full.json" || true
      fi

      # Node Exporter Dashboard (ID: 11074) - comprehensive system metrics
      if [ ! -f "$DASHBOARD_DIR/node-exporter-11074.json" ]; then
        echo "Downloading Node Exporter dashboard 11074..."
        ${pkgs.curl}/bin/curl -sSL \
          "https://grafana.com/api/dashboards/11074/revisions/latest/download" \
          -o "$DASHBOARD_DIR/node-exporter-11074.json" || true
      fi

      # PostgreSQL Database dashboard (ID: 9628)
      if [ ! -f "$DASHBOARD_DIR/postgresql.json" ]; then
        echo "Downloading PostgreSQL dashboard..."
        ${pkgs.curl}/bin/curl -sSL \
          "https://grafana.com/api/dashboards/9628/revisions/latest/download" \
          -o "$DASHBOARD_DIR/postgresql.json" || true
      fi

      # Copy ZFS Replication Dashboard
      if [ ! -f "$DASHBOARD_DIR/zfs-replication.json" ]; then
        echo "Installing ZFS Replication dashboard..."
        if [ -f "/etc/nixos/modules/storage/zfs-replication-dashboard.json" ]; then
          cp /etc/nixos/modules/storage/zfs-replication-dashboard.json "$DASHBOARD_DIR/zfs-replication.json"
        fi
      fi

      # Set proper ownership
      chown -R grafana:grafana "$DASHBOARD_DIR"
    '';
    deps = [];
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."grafana.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/grafana.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/grafana.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:3000";
      proxyWebsockets = true;

      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Grafana specific settings
        proxy_set_header X-Forwarded-Host $host;
        proxy_hide_header X-Frame-Options;

        # Increase timeouts for Grafana
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
      '';
    };

    extraConfig = ''
      # Security headers
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-XSS-Protection "1; mode=block" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    '';
  };

  # Certificate generation script service
  systemd.services.grafana-certificate = {
    description = "Generate Grafana TLS certificate";
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

      CERT_FILE="$CERT_DIR/grafana.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/grafana.vulcan.lan.key"

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
      echo "Creating temporary self-signed certificate for grafana.vulcan.lan"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=grafana.vulcan.lan" \
        -addext "subjectAltName=DNS:grafana.vulcan.lan"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown -R nginx:nginx "$CERT_DIR"

      echo "Certificate generated successfully"
    '';
  };

  # Ensure Grafana starts after Prometheus
  systemd.services.grafana = {
    after = [ "prometheus.service" ];
    wants = [ "prometheus.service" ];
  };

  # Open firewall for HTTPS access to Grafana (via nginx)
  # Port 3000 remains closed as it's only accessible via localhost
  networking.firewall.allowedTCPPorts = [ 443 ];

  # Add monitoring check script
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-grafana" ''
      echo "=== Grafana Status ==="
      systemctl is-active grafana && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== Local Connection Test ==="
      ${pkgs.curl}/bin/curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:3000/api/health

      echo ""
      echo "=== HTTPS Access Test ==="
      ${pkgs.curl}/bin/curl -ks -o /dev/null -w "HTTP Status: %{http_code}\n" https://grafana.vulcan.lan/api/health || \
        echo "Note: HTTPS test requires valid DNS or /etc/hosts entry for grafana.vulcan.lan"

      echo ""
      echo "=== Data Sources ==="
      ${pkgs.curl}/bin/curl -s http://localhost:3000/api/datasources | ${pkgs.jq}/bin/jq -r '.[] | "\(.name): \(.type) - \(.url)"' 2>/dev/null || \
        echo "Unable to query data sources (authentication may be required)"

      echo ""
      echo "=== Certificate Status ==="
      if [ -f /var/lib/step-ca/certs/grafana.vulcan.lan.crt ]; then
        ${pkgs.openssl}/bin/openssl x509 -in /var/lib/step-ca/certs/grafana.vulcan.lan.crt -noout -dates
      else
        echo "Certificate not yet generated"
      fi
    '')
  ];
}
