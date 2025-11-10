{ config, lib, pkgs, ... }:

{
  # MindsDB health monitoring via HTTP probe
  # MindsDB doesn't expose native Prometheus metrics, so we use blackbox exporter
  # to monitor service availability and response time

  # Prometheus scrape configuration for MindsDB via blackbox exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "mindsdb";
      metrics_path = "/probe";
      params = {
        module = [ "http_2xx" ];
      };
      static_configs = [{
        targets = [
          "http://127.0.0.1:47334/api/status"  # MindsDB API status endpoint (web UI disabled)
        ];
      }];
      relabel_configs = [
        {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        }
        {
          source_labels = [ "__param_target" ];
          target_label = "instance";
        }
        {
          target_label = "__address__";
          replacement = "127.0.0.1:9115";  # Blackbox exporter address
        }
        {
          target_label = "service";
          replacement = "mindsdb";
        }
      ];
    }
  ];

  # Documentation
  environment.etc."mindsdb/metrics-monitoring.md" = {
    text = ''
      # MindsDB Prometheus Monitoring

      ## Overview
      MindsDB does not expose native Prometheus metrics endpoints. Instead, we monitor
      service health using Blackbox Exporter to probe the HTTP endpoint.

      ## Monitoring Strategy
      - **HTTP Health Check**: Blackbox exporter probes http://127.0.0.1:47334/api/status
      - **Response Time**: Track API response latency
      - **Availability**: Monitor service uptime via probe success
      - **Container Health**: Podman container status via systemd

      Note: The web UI is disabled (MINDSDB_WEB_GUI=false) to avoid S3 DNS issues.
      The API endpoints remain fully functional at /api/*

      ## Available Metrics
      Via Blackbox Exporter:
      - `probe_success{service="mindsdb"}` - 1 if probe succeeded, 0 otherwise
      - `probe_duration_seconds{service="mindsdb"}` - HTTP probe duration
      - `probe_http_status_code{service="mindsdb"}` - HTTP response status code
      - `probe_http_ssl{service="mindsdb"}` - SSL/TLS status (via nginx proxy)

      ## Key Metrics to Monitor
      - **Service Availability**: `probe_success{service="mindsdb"} == 0`
      - **Response Time**: `probe_duration_seconds{service="mindsdb"}`
      - **HTTP Status**: `probe_http_status_code{service="mindsdb"} != 200`

      ## Checking Metrics
      ```bash
      # Check MindsDB API status endpoint
      curl http://localhost:47334/api/status

      # Check via HTTPS (nginx proxy)
      curl https://mindsdb.vulcan.lan/api/status

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="mindsdb")'

      # Query service availability
      curl 'http://localhost:9090/api/v1/query?query=probe_success{service="mindsdb"}'

      # Check container status
      systemctl status mindsdb
      podman ps | grep mindsdb
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Example queries:
         - `probe_success{service="mindsdb"}` - Current availability (1=up, 0=down)
         - `rate(probe_duration_seconds{service="mindsdb"}[5m])` - Average response time
         - `probe_http_status_code{service="mindsdb"}` - HTTP status code

      ## Alerting
      Alerts are configured in Alertmanager for:
      - Service down: `probe_success{service="mindsdb"} == 0`
      - Slow response: `probe_duration_seconds{service="mindsdb"} > 5`
      - HTTP errors: `probe_http_status_code{service="mindsdb"} >= 500`
      - Container not running: systemd unit failure

      ## Additional Monitoring
      Since MindsDB doesn't expose internal metrics, consider:
      - **PostgreSQL Metrics**: Monitor mindsdb database via postgres_exporter
      - **Container Metrics**: Monitor resource usage via cAdvisor or podman stats
      - **Log Analysis**: Parse logs for errors and performance issues
      - **Database Queries**: Monitor query patterns in PostgreSQL

      ## Troubleshooting
      - **Probe failures**: Check MindsDB container is running
      - **Timeout errors**: Increase blackbox probe timeout or check MindsDB logs
      - **Connection refused**: Verify port 47334 is open and MindsDB is listening
      - **503 errors**: Check nginx proxy configuration

      ## PostgreSQL Monitoring
      MindsDB uses PostgreSQL for metadata storage. Monitor:
      ```bash
      # Connect to MindsDB database
      sudo -u postgres psql -d mindsdb

      # Check database size
      SELECT pg_database_size('mindsdb');

      # Check connection count
      SELECT count(*) FROM pg_stat_activity WHERE datname = 'mindsdb';
      ```

      ## Container Logs
      ```bash
      # View MindsDB logs
      journalctl -u mindsdb -f

      # View container logs
      podman logs mindsdb -f

      # Check container resource usage
      podman stats mindsdb --no-stream
      ```

      ## Related Files
      - Module: /etc/nixos/modules/monitoring/services/mindsdb-exporter.nix
      - Service: /etc/nixos/modules/services/mindsdb.nix
      - Prometheus: /etc/nixos/modules/monitoring/services/prometheus-server.nix
      - Alertmanager: /etc/nixos/modules/services/alertmanager.nix
    '';
    mode = "0644";
  };
}
