{ config, lib, pkgs, ... }:

{
  # MinIO Prometheus metrics monitoring
  # Monitors object storage performance, capacity, and health

  # Generate MinIO Prometheus bearer token at startup
  systemd.services.minio-prometheus-token-setup = {
    description = "Generate MinIO Prometheus bearer token";
    after = [ "minio.service" "minio-credentials-setup.service" ];
    wants = [ "minio.service" ];
    requires = [ "minio-credentials-setup.service" ];
    before = [ "prometheus.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    path = [ pkgs.minio-client pkgs.gawk pkgs.coreutils pkgs.su ];

    script = ''
      # Wait for MinIO to be ready
      until ${pkgs.curl}/bin/curl -s http://10.88.0.1:9000/minio/health/live > /dev/null 2>&1; do
        echo "Waiting for MinIO to be ready..."
        sleep 2
      done

      # Generate Prometheus bearer token using mc admin as minio user
      TOKEN_OUTPUT=$(su -s /bin/sh minio -c "HOME=/var/lib/minio ${pkgs.minio-client}/bin/mc admin prometheus generate ragflow-local cluster --api-version v3 2>&1")

      if echo "$TOKEN_OUTPUT" | grep -q "bearer_token:"; then
        # Extract just the bearer token value using sed
        BEARER_TOKEN=$(echo "$TOKEN_OUTPUT" | grep "bearer_token:" | sed 's/.*bearer_token: *//')

        # Ensure Prometheus data directory exists
        mkdir -p /var/lib/prometheus
        chown prometheus:prometheus /var/lib/prometheus
        chmod 755 /var/lib/prometheus

        # Store the bearer token in Prometheus data directory
        echo "$BEARER_TOKEN" > /var/lib/prometheus/minio-bearer-token
        chmod 640 /var/lib/prometheus/minio-bearer-token
        chown prometheus:prometheus /var/lib/prometheus/minio-bearer-token
        echo "MinIO Prometheus bearer token generated successfully"
      else
        echo "Error: Failed to generate MinIO Prometheus bearer token"
        echo "$TOKEN_OUTPUT"
        exit 1
      fi
    '';
  };

  # Prometheus scrape configuration for MinIO
  services.prometheus.scrapeConfigs = [
    {
      job_name = "minio";
      bearer_token_file = "/var/lib/prometheus/minio-bearer-token";
      metrics_path = "/minio/metrics/v3/cluster";
      scheme = "http";
      static_configs = [{
        targets = [ "10.88.0.1:9000" ];
      }];
      scrape_interval = "60s";
    }
  ];

  # Ensure prometheus starts after token is generated
  systemd.services.prometheus = {
    after = [ "minio-prometheus-token-setup.service" ];
    wants = [ "minio-prometheus-token-setup.service" ];
  };

  # Helper script to check MinIO exporter
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-minio-metrics" ''
      echo "=== MinIO Service Status ==="
      systemctl is-active minio && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== MinIO Prometheus Token Status ==="
      if [ -f /var/lib/prometheus/minio-bearer-token ]; then
        echo "Bearer token file exists"
        echo "Permissions: $(sudo stat -c '%a %U:%G' /var/lib/prometheus/minio-bearer-token)"

        # Test token by making authenticated request
        echo ""
        echo "=== Testing Authenticated Metrics Access ==="
        TOKEN=$(sudo cat /var/lib/prometheus/minio-bearer-token)
        RESPONSE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
          -H "Authorization: Bearer $TOKEN" \
          http://10.88.0.1:9000/minio/metrics/v3/cluster)

        if [ "$RESPONSE" = "200" ]; then
          echo "✓ MinIO metrics accessible (HTTP $RESPONSE)"
        else
          echo "✗ MinIO metrics not accessible (HTTP $RESPONSE)"
        fi
      else
        echo "✗ Bearer token file not found"
        exit 1
      fi

      echo ""
      echo "=== Sample MinIO Metrics ==="
      TOKEN=$(sudo cat /var/lib/prometheus/minio-bearer-token)
      ${pkgs.curl}/bin/curl -s \
        -H "Authorization: Bearer $TOKEN" \
        http://10.88.0.1:9000/minio/metrics/v3/cluster | \
        grep -E "minio_cluster_health_status|minio_cluster_capacity_usable_total_bytes|minio_node_online_total" | \
        head -10

      echo ""
      echo "=== Prometheus Scrape Status ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9090/api/v1/targets | \
        ${pkgs.jq}/bin/jq -r '.data.activeTargets[] | select(.labels.job == "minio") | "MinIO: \(.health) - \(.lastError // "no error")"'
    '')
  ];
}
