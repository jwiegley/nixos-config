{ config, lib, pkgs, ... }:

{
  # ChangeDetection.io Prometheus metrics monitoring
  # Scrapes metrics from the ChangeDetection Prometheus exporter
  # Metrics exposed at http://localhost:9123/metrics

  # Prometheus scrape configuration for ChangeDetection exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "changedetection";
      static_configs = [{
        targets = [ "localhost:9123" ];
        labels = {
          service = "changedetection";
          instance = "vulcan";
        };
      }];
      metrics_path = "/metrics";
      scrape_interval = "60s";  # Scrape every minute
      scrape_timeout = "10s";
    }
  ];

  # Documentation
  environment.etc."changedetection/metrics-monitoring.md" = {
    text = ''
      # ChangeDetection.io Prometheus Metrics Monitoring

      ## Overview
      ChangeDetection.io exposes Prometheus metrics via a dedicated exporter at http://localhost:9123/metrics

      ## Available Metrics
      The exporter provides the following metrics:
      - **Website watch metrics**: Scrape statistics for each monitored watch
      - **Queue metrics**: Queue size and processing statistics
      - **System metrics**: Uptime, version information, and resource usage
      - **Price tracking**: Latest prices of tracked products (if configured)
      - **Watch state**: Status and health of individual watches

      ## Checking Metrics
      ```bash
      # Check ChangeDetection metrics endpoint
      curl http://localhost:9123/metrics

      # Check specific watch metrics
      curl -s http://localhost:9123/metrics | grep changedetection

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="changedetection")'
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Create a new dashboard
      3. Add panel with PromQL query
      4. Example queries:
         - `changedetection_watch_count` - Total number of watches
         - `changedetection_queue_size` - Current queue size
         - `changedetection_scrape_duration_seconds` - Scrape duration per watch
         - `rate(changedetection_scrape_total[5m])` - Scrape rate

      ## Accessing ChangeDetection.io
      - **Web UI**: https://changes.vulcan.lan
      - **API**: http://localhost:5055/api (requires API key)
      - **Metrics**: http://localhost:9123/metrics

      ## Troubleshooting
      - **Metrics not showing**: Check exporter container is running:
        ```bash
        sudo systemctl status changedetection-exporter-container.service
        sudo podman ps | grep changedetection
        ```
      - **Scrape failures**: Check Prometheus targets page for error messages
      - **Missing metrics**: Ensure ChangeDetection app is running and healthy
      - **API key issues**: Verify SOPS secret is properly configured:
        ```bash
        sudo systemctl status changedetection-env-setup.service
        ls -la /run/changedetection/exporter.env
        ```

      ## Related Files
      - Module: /etc/nixos/modules/monitoring/services/changedetection-exporter.nix
      - Service config: /etc/nixos/modules/containers/changedetection-quadlet.nix
      - Prometheus config: /etc/nixos/modules/monitoring/services/prometheus-server.nix

      ## Exporter Configuration
      The exporter is configured via environment variables:
      - CDIO_API_BASE_URL: http://localhost:5000 (internal pod network)
      - CDIO_API_KEY: Loaded from SOPS secret changedetection/api-key

      ## Service Management
      ```bash
      # Check service status
      sudo systemctl status changedetection-app-container.service
      sudo systemctl status changedetection-exporter-container.service
      sudo systemctl status changedetection-pod.service

      # Restart services
      sudo systemctl restart changedetection-app-container.service
      sudo systemctl restart changedetection-exporter-container.service

      # View logs
      sudo journalctl -u changedetection-app-container.service -f
      sudo journalctl -u changedetection-exporter-container.service -f
      ```
    '';
    mode = "0644";
  };
}
