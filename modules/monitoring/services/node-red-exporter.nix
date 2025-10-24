{ config, lib, pkgs, ... }:

{
  # Node-RED Prometheus metrics monitoring
  # Scrapes metrics from Node-RED's built-in Prometheus exporter
  # Metrics exposed at http://localhost:1880/metrics

  # SOPS secret for Prometheus to authenticate with Node-RED
  # This should be one of the tokens from node-red/api-tokens
  sops.secrets."prometheus/node-red-token" = {
    owner = "prometheus";
    group = "prometheus";
    mode = "0400";
    restartUnits = [ "prometheus.service" ];
  };

  # Prometheus scrape configuration for Node-RED with authentication
  services.prometheus.scrapeConfigs = [
    {
      job_name = "node-red";
      static_configs = [{
        targets = [ "localhost:1880" ];
        labels = {
          service = "node-red";
          instance = "vulcan";
        };
      }];
      metrics_path = "/metrics";
      scrape_interval = "15s";
      scrape_timeout = "10s";

      # Bearer token authentication for Node-RED metrics endpoint
      # Token is loaded from SOPS secret file
      bearer_token_file = config.sops.secrets."prometheus/node-red-token".path;
    }
  ];

  # Helper script to check Node-RED metrics
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-node-red-metrics" ''
      echo "=== Node-RED Service Status ==="
      systemctl is-active node-red && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== Node-RED Metrics Endpoint ==="
      if ${pkgs.curl}/bin/curl -s -f http://localhost:1880/metrics > /dev/null 2>&1; then
        echo "Metrics endpoint: Accessible"
      else
        echo "Metrics endpoint: Not accessible"
        echo "Note: If authentication is enabled, metrics endpoint may require authentication"
      fi

      echo ""
      echo "=== Node-RED Metrics Sample ==="
      ${pkgs.curl}/bin/curl -s http://localhost:1880/metrics 2>/dev/null | head -20 || echo "Could not fetch metrics"

      echo ""
      echo "=== Node-RED Custom Metrics ==="
      ${pkgs.curl}/bin/curl -s http://localhost:1880/metrics 2>/dev/null | grep -v "^#" | grep "node_red" || echo "No node_red metrics found"

      echo ""
      echo "=== Prometheus Scrape Status ==="
      echo "Check Prometheus targets: http://localhost:9090/targets"
      echo "Search for job_name: node-red"
    '')
  ];

  # Documentation
  environment.etc."node-red/metrics-monitoring.md" = {
    text = ''
      # Node-RED Prometheus Metrics Monitoring

      ## Overview
      Node-RED exposes Prometheus metrics at http://localhost:1880/metrics

      ## Available Metrics
      Node-RED can export custom metrics using prometheus-contrib nodes:
      - Counters: Incrementing values (e.g., event counts)
      - Gauges: Point-in-time values (e.g., temperature)
      - Histograms: Value distributions (e.g., response times)
      - Summaries: Statistical summaries

      ## Checking Metrics
      ```bash
      # Check Node-RED metrics endpoint
      check-node-red-metrics

      # View raw metrics
      curl http://localhost:1880/metrics

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="node-red")'
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Create a new dashboard
      3. Add panel with PromQL query
      4. Example queries:
         - `node_red_example` - Your custom metric
         - `rate(node_red_example[5m])` - Rate of change over 5 minutes
         - `increase(node_red_example[1h])` - Total increase over 1 hour

      ## Adding Custom Metrics in Node-RED
      1. Install node-red-contrib-prometheus-exporter (if not already installed)
      2. Add a "prometheus-metric-config" node to configure a metric
      3. Add metric nodes (counter, gauge, histogram, summary)
      4. Wire your flows to update metrics
      5. Metrics are automatically exposed at /metrics

      ## Troubleshooting
      - **Metrics not showing**: Check Node-RED is running and /metrics is accessible
      - **Authentication issues**: Metrics endpoint may require authentication if httpNodeAuth is enabled
      - **Missing metrics**: Ensure prometheus-exporter nodes are properly configured in Node-RED
      - **Scrape failures**: Check Prometheus targets page for error messages

      ## Authentication Setup
      The /metrics endpoint requires bearer token authentication (httpNodeAuth is enabled).
      Prometheus uses a dedicated token stored in SOPS:

      1. Edit SOPS secrets:
         ```bash
         sops /etc/nixos/secrets/secrets.yaml
         ```

      2. Add prometheus section with a Node-RED API token:
         ```yaml
         prometheus:
           node-red-token: "abc123..."  # Use one of your node-red/api-tokens
         ```

      3. Rebuild NixOS:
         ```bash
         sudo nixos-rebuild switch --flake '.#vulcan'
         ```

      The token should match one of the tokens defined in node-red/api-tokens.
      This allows Prometheus to authenticate when scraping Node-RED metrics.

      ## Related Files
      - Module: /etc/nixos/modules/monitoring/services/node-red-exporter.nix
      - Node-RED config: /etc/nixos/modules/services/node-red.nix
      - Prometheus config: /etc/nixos/modules/monitoring/services/prometheus-server.nix
    '';
    mode = "0644";
  };
}
