{ config, lib, pkgs, ... }:

{
  # Immich Prometheus metrics monitoring
  # Scrapes metrics from Immich's built-in Prometheus endpoints
  # API metrics exposed at http://localhost:9283/metrics
  # Microservices metrics exposed at http://localhost:9284/metrics

  # Prometheus scrape configuration for Immich
  services.prometheus.scrapeConfigs = [
    {
      job_name = "immich-api";
      static_configs = [{
        targets = [ "localhost:9283" ];
        labels = {
          service = "immich";
          component = "api";
          instance = "vulcan";
        };
      }];
      metrics_path = "/metrics";
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
    {
      job_name = "immich-microservices";
      static_configs = [{
        targets = [ "localhost:9284" ];
        labels = {
          service = "immich";
          component = "microservices";
          instance = "vulcan";
        };
      }];
      metrics_path = "/metrics";
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
  ];

  # Documentation
  environment.etc."immich/metrics-monitoring.md" = {
    text = ''
      # Immich Prometheus Metrics Monitoring

      ## Overview
      Immich exposes Prometheus metrics on two endpoints:
      - API metrics: http://localhost:9283/metrics
      - Microservices metrics: http://localhost:9284/metrics

      ## Available Metrics
      Immich provides various metrics including:
      - **HTTP metrics**: Request counts, durations, response codes
      - **Photo/Video metrics**: Upload counts, processing status
      - **ML metrics**: Face detection, smart search processing
      - **Job metrics**: Background job queue status
      - **Go/Node runtime metrics**: Memory usage, CPU, event loop

      ## Checking Metrics
      ```bash
      # View API metrics
      curl http://localhost:9283/metrics

      # View microservices metrics
      curl http://localhost:9284/metrics

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.service=="immich")'
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Import the Immich dashboard from the provisioned dashboards
      3. Or search Grafana.com for community Immich dashboards

      ## Troubleshooting
      - **Metrics not showing**: Check Immich services are running: `systemctl status immich-server immich-machine-learning`
      - **Scrape failures**: Check Prometheus targets page: https://prometheus.vulcan.lan/targets
      - **Missing metrics**: Verify IMMICH_TELEMETRY_INCLUDE=all is set

      ## Related Files
      - Immich service: /etc/nixos/modules/services/immich.nix
      - Exporter config: /etc/nixos/modules/monitoring/services/immich-exporter.nix
      - Alerts: /etc/nixos/modules/monitoring/alerts/immich.yaml
    '';
    mode = "0644";
  };
}
