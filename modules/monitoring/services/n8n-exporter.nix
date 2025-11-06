{ config, lib, pkgs, ... }:

{
  # n8n Prometheus metrics monitoring
  # Scrapes metrics from n8n's built-in Prometheus exporter
  # Metrics exposed at http://localhost:5678/metrics

  # Prometheus scrape configuration for n8n
  services.prometheus.scrapeConfigs = [
    {
      job_name = "n8n";
      static_configs = [{
        targets = [ "localhost:5678" ];
        labels = {
          service = "n8n";
          instance = "vulcan";
        };
      }];
      metrics_path = "/metrics";
      scrape_interval = "15s";
      scrape_timeout = "10s";
    }
  ];

  # Documentation
  environment.etc."n8n/metrics-monitoring.md" = {
    text = ''
      # n8n Prometheus Metrics Monitoring

      ## Overview
      n8n exposes Prometheus metrics at http://localhost:5678/metrics

      ## Available Metrics
      n8n exports various operational metrics including:
      - **Workflow metrics**: Execution counts, success/failure rates, duration
      - **Queue metrics**: Queue length, processing time, worker status
      - **System metrics**: CPU, memory usage, event loop lag
      - **API metrics**: Request counts, response times, error rates
      - **Database metrics**: Connection pool usage, query performance

      ## Key Metrics to Monitor
      - `n8n_workflow_executions_total` - Total workflow executions by status
      - `n8n_workflow_execution_duration_seconds` - Workflow execution duration
      - `n8n_workflow_execution_errors_total` - Failed workflow executions
      - `n8n_queue_waiting` - Number of workflows waiting in queue
      - `n8n_queue_processing` - Number of workflows currently processing
      - `n8n_api_requests_total` - Total API requests
      - `n8n_api_request_duration_seconds` - API request duration

      ## Checking Metrics
      ```bash
      # Check n8n metrics endpoint
      curl http://localhost:5678/metrics

      # Check Prometheus scrape status
      curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="n8n")'

      # Query specific metrics via Prometheus
      curl 'http://localhost:9090/api/v1/query?query=n8n_workflow_executions_total'
      ```

      ## Viewing in Grafana
      1. Open Grafana: https://grafana.vulcan.lan
      2. Navigate to the n8n dashboard (if created)
      3. Example queries:
         - `rate(n8n_workflow_executions_total[5m])` - Workflow execution rate
         - `n8n_queue_waiting` - Current queue size
         - `histogram_quantile(0.95, rate(n8n_workflow_execution_duration_seconds_bucket[5m]))` - 95th percentile execution time
         - `rate(n8n_workflow_execution_errors_total[5m])` - Error rate

      ## Alerting
      Consider setting up alerts for:
      - High error rate: `rate(n8n_workflow_execution_errors_total[5m]) > 0.1`
      - Queue backlog: `n8n_queue_waiting > 100`
      - Slow executions: `histogram_quantile(0.95, rate(n8n_workflow_execution_duration_seconds_bucket[5m])) > 300`
      - Service down: `up{job="n8n"} == 0`

      ## Troubleshooting
      - **Metrics not showing**: Check n8n is running and /metrics is accessible
      - **Missing metrics**: Ensure metrics are enabled in n8n configuration
      - **Scrape failures**: Check Prometheus targets page for error messages
      - **High cardinality**: Monitor metric cardinality if using workflow ID labels

      ## Configuration
      Metrics are enabled in the n8n service configuration:
      ```nix
      endpoints = {
        metrics = {
          enable = true;
          prefix = "n8n_";
          includeDefaultMetrics = true;
          includeApiEndpoints = true;
          includeMessageEventBusMetrics = true;
          includeWorkflowIdLabel = true;
        };
      };
      ```

      ## Related Files
      - Module: /etc/nixos/modules/monitoring/services/n8n-exporter.nix
      - n8n service: /etc/nixos/modules/services/n8n.nix
      - Prometheus config: /etc/nixos/modules/monitoring/services/prometheus-server.nix
    '';
    mode = "0644";
  };
}
