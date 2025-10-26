{ config, lib, pkgs, ... }:

{
  # VictoriaMetrics time-series database
  # Scrapes Home Assistant Prometheus endpoint for push-based metrics collection
  # Provides high-performance alternative storage for HA metrics

  # SOPS secret for Home Assistant authentication token
  sops.secrets."prometheus/home-assistant-token" = {
    owner = "prometheus";
    group = "prometheus";
    mode = "0440";
    restartUnits = [ "victoriametrics.service" ];
  };

  services.victoriametrics = {
    enable = true;

    # Listen only on localhost (nginx will proxy)
    listenAddress = "127.0.0.1:8428";

    # Data retention period (infinite - retain all Home Assistant historical data)
    retentionPeriod = "100y";  # effectively infinite retention

    # Storage directory
    stateDir = "victoriametrics";

    # Prometheus-compatible scrape configuration
    prometheusConfig = {
      global = {
        scrape_interval = "60s";
        scrape_timeout = "30s";
        external_labels = {
          monitor = "vulcan";
          environment = "production";
          source = "victoriametrics";
        };
      };

      scrape_configs = [
        {
          job_name = "home_assistant";
          scrape_interval = "60s";
          scrape_timeout = "30s";
          metrics_path = "/api/prometheus";
          scheme = "https";

          # Authentication using long-lived access token via systemd credentials
          authorization = {
            type = "Bearer";
            credentials_file = "/run/credentials/victoriametrics.service/ha-token";
          };

          static_configs = [{
            targets = [ "hass.vulcan.lan:443" ];
            labels = {
              instance = "vulcan";
              service = "home-assistant";
              collector = "victoriametrics";
            };
          }];

          # TLS configuration to trust step-ca certificates
          tls_config = {
            ca_file = "/etc/ssl/certs/ca-bundle.crt";
            insecure_skip_verify = false;
          };
        }
      ];
    };

    # Additional VictoriaMetrics flags for optimization
    extraOptions = [
      # Enable deduplication of samples with identical timestamps
      "-dedup.minScrapeInterval=60s"

      # Memory optimizations
      "-memory.allowedPercent=60"

      # Search query optimizations
      "-search.maxQueryDuration=60s"
      "-search.maxConcurrentRequests=8"

      # Retention and storage optimizations
      "-retentionTimezoneOffset=0h"
    ];
  };

  # Ensure VictoriaMetrics can access the Home Assistant token
  systemd.services.victoriametrics = {
    after = [
      "sops-install-secrets.service"
      "home-assistant.service"
    ];
    wants = [
      "sops-install-secrets.service"
      "home-assistant.service"
    ];

    # Use systemd LoadCredential to make token available
    # Token will be available at $CREDENTIALS_DIRECTORY/ha-token
    serviceConfig = {
      LoadCredential = "ha-token:${config.sops.secrets."prometheus/home-assistant-token".path}";
    };
  };

  # Token is managed via systemd LoadCredential, no tmpfiles needed

  # Nginx reverse proxy for VictoriaMetrics
  services.nginx.virtualHosts."victoriametrics.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/victoriametrics.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/victoriametrics.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:8428/";
      extraConfig = ''
        # Increase timeouts for VictoriaMetrics queries
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 300s;

        # Add security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
      '';
    };
  };

  # Certificate generation service for VictoriaMetrics
  systemd.services.victoriametrics-certificate = {
    description = "Generate VictoriaMetrics TLS certificate";
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

      CERT_FILE="$CERT_DIR/victoriametrics.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/victoriametrics.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Create self-signed certificate as fallback
      echo "Creating self-signed certificate for victoriametrics.vulcan.lan"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=victoriametrics.vulcan.lan" \
        -addext "subjectAltName=DNS:victoriametrics.vulcan.lan"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown -R nginx:nginx "$CERT_DIR"

      echo "Certificate generated successfully"
    '';
  };

  # Firewall configuration
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    8428  # VictoriaMetrics
  ];

  # Add helper scripts for VictoriaMetrics management
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "victoriametrics-query" ''
      if [ $# -eq 0 ]; then
        echo "Usage: victoriametrics-query <promql-query>"
        echo "Example: victoriametrics-query 'homeassistant_sensor_temperature_celsius'"
        exit 1
      fi

      QUERY="$1"
      ${pkgs.curl}/bin/curl -s "http://localhost:8428/api/v1/query?query=$QUERY" | ${pkgs.jq}/bin/jq '.'
    '')
  ];

  # Documentation
  environment.etc."victoriametrics/README.md" = {
    text = ''
      # VictoriaMetrics Configuration

      ## Overview
      VictoriaMetrics is configured to scrape Home Assistant metrics from the
      Prometheus endpoint for high-performance, push-based metrics collection.

      ## Access
      - Web UI: https://victoriametrics.vulcan.lan
      - Local API: http://localhost:8428

      ## API Endpoints
      - Query API: http://localhost:8428/api/v1/query
      - Query Range: http://localhost:8428/api/v1/query_range
      - Series: http://localhost:8428/api/v1/series
      - Labels: http://localhost:8428/api/v1/labels
      - Targets: http://localhost:8428/api/v1/targets
      - Storage Stats: http://localhost:8428/api/v1/status/tsdb

      ## Configuration
      - Scrape interval: 60 seconds
      - Retention: 12 months
      - Storage: /var/lib/victoriametrics
      - Listen address: 127.0.0.1:8428

      ## Authentication
      VictoriaMetrics uses the Home Assistant long-lived access token via systemd
      LoadCredential. The token is securely loaded from SOPS secrets at service
      startup and made available at: /run/credentials/victoriametrics.service/ha-token

      ## Useful Commands

      ### Check service status
      ```bash
      check-victoriametrics
      systemctl status victoriametrics
      sudo journalctl -u victoriametrics -f
      ```

      ### Query metrics
      ```bash
      # Query Home Assistant temperature sensors
      victoriametrics-query 'homeassistant_sensor_temperature_celsius'

      # Query with curl
      curl 'http://localhost:8428/api/v1/query?query=homeassistant_sensor_temperature_celsius'
      ```

      ### Storage management
      ```bash
      # Check storage size
      du -sh /var/lib/victoriametrics

      # View storage stats
      curl http://localhost:8428/api/v1/status/tsdb | jq '.'
      ```

      ## Grafana Integration
      VictoriaMetrics is automatically provisioned as a Grafana datasource named
      "VictoriaMetrics" and is compatible with all Prometheus dashboards.

      Access Grafana: https://grafana.vulcan.lan

      ## Querying from Grafana
      VictoriaMetrics supports PromQL and MetricsQL (extended PromQL):

      ```promql
      # Home Assistant temperature sensors
      homeassistant_sensor_temperature_celsius{entity=~"sensor.*_temperature"}

      # Home Assistant lock states
      homeassistant_lock_state{domain="lock"}

      # Solar production (Enphase)
      homeassistant_sensor_state{entity="sensor.envoy_current_power_production"}
      ```

      ## Troubleshooting

      ### Metrics not appearing
      1. Verify SOPS secret exists:
         ```bash
         sudo ls -la /run/secrets/prometheus/home-assistant-token
         ```

      2. Test Home Assistant endpoint (requires root to read credential):
         ```bash
         sudo systemctl show victoriametrics.service -p LoadCredential
         # Token is securely loaded into service credentials directory
         ```

      3. Check VictoriaMetrics scrape targets:
         ```bash
         curl http://localhost:8428/api/v1/targets | jq '.data.activeTargets'
         ```

      4. View VictoriaMetrics logs:
         ```bash
         sudo journalctl -u victoriametrics -f
         ```

      ### Service fails to start
      1. Check if SOPS secret is deployed:
         ```bash
         sudo ls -la /run/secrets/prometheus/home-assistant-token
         systemctl status sops-install-secrets.service
         ```

      2. Verify LoadCredential is configured:
         ```bash
         systemctl show victoriametrics.service -p LoadCredential
         ```

      3. Rebuild configuration:
         ```bash
         sudo nixos-rebuild switch --flake '.#vulcan'
         ```

      ## References
      - VictoriaMetrics docs: https://docs.victoriametrics.com/
      - PromQL reference: https://prometheus.io/docs/prometheus/latest/querying/basics/
      - MetricsQL extensions: https://docs.victoriametrics.com/metricsql/
    '';
    mode = "0644";
  };
}
