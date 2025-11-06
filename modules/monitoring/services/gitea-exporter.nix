{ config, lib, pkgs, ... }:

{
  # Gitea Prometheus metrics monitoring
  # Scrapes metrics from Gitea's built-in Prometheus exporter
  # Metrics exposed at http://localhost:3005/metrics

  # Prometheus scrape configuration for Gitea
  services.prometheus.scrapeConfigs = [
    {
      job_name = "gitea";
      static_configs = [{
        targets = [ "localhost:3005" ];
        labels = {
          service = "gitea";
          instance = "vulcan";
        };
      }];
      metrics_path = "/metrics";
      scrape_interval = "30s";
      scrape_timeout = "10s";
    }
  ];

  # Documentation
  environment.etc."gitea/metrics-monitoring.md" = {
    text = ''
      # Gitea Prometheus Metrics Monitoring

      ## Overview
      Gitea exposes Prometheus metrics at http://localhost:3005/metrics

      ## Available Metrics
      Gitea provides various metrics including:
      - **HTTP metrics**: Request counts, durations, response codes
      - **Repository metrics**: Number of repos, stars, forks, issues, PRs
      - **User metrics**: User counts, authentication attempts
      - **Git operations**: Clone, push, pull statistics
      - **Database metrics**: Connection pool stats, query performance
      - **Go runtime metrics**: Memory usage, goroutines, GC stats

      ## Key Metrics Examples
      - `gitea_organizations`: Number of organizations
      - `gitea_repositories`: Number of repositories
      - `gitea_users`: Number of users
      - `gitea_issues`: Number of issues
      - `gitea_pulls`: Number of pull requests
      - `http_request_duration_seconds`: HTTP request durations
      - `http_requests_total`: Total HTTP requests
      - `process_resident_memory_bytes`: Memory usage

      ## Checking Metrics
      ```bash
      # View raw metrics
      curl http://localhost:3005/metrics

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="gitea")'

      # Query specific metric
      curl 'http://localhost:9090/api/v1/query?query=gitea_repositories'
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Import Gitea dashboard (if available) or create custom dashboard
      3. Example PromQL queries:
         - `gitea_repositories`: Total repositories
         - `rate(http_requests_total{job="gitea"}[5m])`: Request rate
         - `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{job="gitea"}[5m]))`: 95th percentile response time
         - `process_resident_memory_bytes{job="gitea"}`: Memory usage

      ## Common Dashboards
      Search Grafana.com for community Gitea dashboards:
      - Dashboard ID 14673: Gitea Overview
      - Dashboard ID 15489: Gitea Detailed Metrics

      ## Troubleshooting
      - **Metrics not showing**: Check Gitea is running: `systemctl status gitea`
      - **Scrape failures**: Check Prometheus targets page for error messages: https://prometheus.vulcan.lan/targets
      - **Missing metrics**: Ensure `[metrics].ENABLED = true` in Gitea config
      - **Connection refused**: Verify Gitea is listening on localhost:3005

      ## Configuration
      Metrics are enabled in Gitea configuration at:
      /etc/nixos/modules/services/gitea.nix

      ## Related Files
      - Gitea service: /etc/nixos/modules/services/gitea.nix
      - Exporter config: /etc/nixos/modules/monitoring/services/gitea-exporter.nix
      - Prometheus server: /etc/nixos/modules/monitoring/services/prometheus-server.nix
    '';
    mode = "0644";
  };
}
