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
            uid = "prometheus";  # Fixed UID for dashboard references
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
          {
            name = "VictoriaMetrics";
            type = "prometheus";
            uid = "victoriametrics";  # Fixed UID for VictoriaMetrics datasource
            access = "proxy";
            url = "http://localhost:8428";
            isDefault = false;
            editable = false;
            jsonData = {
              timeInterval = "60s";
              queryTimeout = "300s";
              httpMethod = "POST";
              # VictoriaMetrics-specific optimizations
              customQueryParameters = "";
            };
          }
          {
            name = "Loki";
            type = "loki";
            uid = "loki";  # Fixed UID for Loki datasource
            access = "proxy";
            url = "http://localhost:3100";
            isDefault = false;
            editable = false;
            jsonData = {
              maxLines = 1000;
              derivedFields = [
                {
                  # Link from trace ID in logs to tempo traces (if using tempo)
                  matcherRegex = "traceID=(\\w+)";
                  name = "TraceID";
                  url = "$${__value.raw}";
                  datasourceUid = "";
                }
              ];
              # Enable correlation with Prometheus metrics
              alertmanager = {
                implementation = "prometheus";
              };
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

      # Loki & Promtail Dashboard (ID: 10880) - comprehensive log analysis
      if [ ! -f "$DASHBOARD_DIR/loki-promtail.json" ]; then
        echo "Downloading Loki & Promtail dashboard..."
        ${pkgs.curl}/bin/curl -sSL \
          "https://grafana.com/api/dashboards/10880/revisions/latest/download" \
          -o "$DASHBOARD_DIR/loki-promtail.json" || true
      fi

      # Logs / App Dashboard (ID: 13639) - application logs overview
      if [ ! -f "$DASHBOARD_DIR/logs-app.json" ]; then
        echo "Downloading Logs App dashboard..."
        ${pkgs.curl}/bin/curl -sSL \
          "https://grafana.com/api/dashboards/13639/revisions/latest/download" \
          -o "$DASHBOARD_DIR/logs-app.json" || true
      fi

      # Copy DNS Query Logs Dashboard
      if [ ! -f "$DASHBOARD_DIR/dns-query-logs.json" ]; then
        echo "Installing DNS Query Logs dashboard..."
        if [ -f "/etc/nixos/modules/storage/dns-query-logs-dashboard.json" ]; then
          cp /etc/nixos/modules/storage/dns-query-logs-dashboard.json "$DASHBOARD_DIR/dns-query-logs.json"
        fi
      fi

      # Technitium DNS Dashboard from GitHub
      # Note: The dashboard must be manually copied from the cloned repository
      # or downloaded directly using the correct path
      if [ ! -f "$DASHBOARD_DIR/technitium-dns.json" ]; then
        echo "Downloading Technitium DNS dashboard..."
        # The dashboard is at the root of the repository, not in a subdirectory
        ${pkgs.curl}/bin/curl -sSL \
          "https://raw.githubusercontent.com/brioche-works/technitium-dns-prometheus-exporter/main/grafana-dashboard.json" \
          -o "$DASHBOARD_DIR/technitium-dns.json" 2>&1 | grep -v "404" || \
        echo "Dashboard download may have failed - manually copy from /tmp/technitium-dns-prometheus-exporter/grafana-dashboard.json if needed"
      fi

      # Copy Home Assistant Security & Safety Dashboard (always update)
      echo "Installing Home Assistant Security & Safety dashboard..."
      if [ -f "/etc/nixos/modules/monitoring/dashboards/home-assistant.json" ]; then
        cp /etc/nixos/modules/monitoring/dashboards/home-assistant.json "$DASHBOARD_DIR/home-assistant.json"
      fi

      # Copy Enhanced Systemd Services Dashboard (always update)
      echo "Installing Enhanced Systemd Services dashboard..."
      if [ -f "/etc/nixos/modules/monitoring/dashboards/systemd-services-enhanced.json" ]; then
        cp /etc/nixos/modules/monitoring/dashboards/systemd-services-enhanced.json "$DASHBOARD_DIR/systemd-services-enhanced.json"
      fi

      # Copy Mac Studio Power Monitoring Dashboard (always update)
      echo "Installing Mac Studio Power Monitoring dashboard..."
      if [ -f "/etc/nixos/modules/monitoring/dashboards/mac-studio-power.json" ]; then
        cp /etc/nixos/modules/monitoring/dashboards/mac-studio-power.json "$DASHBOARD_DIR/mac-studio-power.json"
      fi

      # Copy Copyparty File Server Dashboard (always update)
      echo "Installing Copyparty File Server dashboard..."
      if [ -f "/etc/nixos/modules/monitoring/dashboards/copyparty.json" ]; then
        cp /etc/nixos/modules/monitoring/dashboards/copyparty.json "$DASHBOARD_DIR/copyparty.json"
      fi

      # Set proper ownership
      chown -R grafana:grafana "$DASHBOARD_DIR"
    '';
    deps = [];
  };

  # Grafana nginx upstream with retry logic
  # Prevents 502 errors during service restarts
  services.nginx.upstreams."grafana" = {
    servers = {
      "127.0.0.1:3000" = {
        max_fails = 0;
      };
    };
    extraConfig = ''
      keepalive 16;
      keepalive_timeout 60s;
    '';
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."grafana.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/grafana.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/grafana.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://grafana/";
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Increase timeouts for Grafana
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
      '';
    };
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

  # Prometheus scrape configuration for Grafana metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "grafana";
      static_configs = [{
        targets = [ "localhost:${toString config.services.grafana.settings.server.http_port}" ];
      }];
      scrape_interval = "30s";
    }
  ];

}
