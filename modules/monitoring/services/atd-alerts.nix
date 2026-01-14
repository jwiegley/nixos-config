{
  config,
  lib,
  pkgs,
  ...
}:

{
  # ============================================================================
  # ATD Alertmanager Rules
  # ============================================================================

  services.prometheus.rules = [
    ''
      groups:
        - name: atd_alerts
          interval: 60s
          rules:
            # Alert if atd service is not running
            - alert: AtdServiceDown
              expr: atd_service_running == 0
              for: 5m
              labels:
                severity: critical
                service: atd
              annotations:
                summary: "ATD service is not running on {{ $labels.instance }}"
                description: "The atd (at daemon) service has been down for more than 5 minutes on {{ $labels.instance }}."

            # Alert if jobs are stuck in queue for too long (> 24 hours)
            - alert: AtdJobsStuck
              expr: |
                (time() - atd_oldest_job_timestamp) > 86400
                and atd_oldest_job_timestamp > 0
              for: 1h
              labels:
                severity: warning
                service: atd
              annotations:
                summary: "ATD has jobs stuck in queue for over 24 hours on {{ $labels.instance }}"
                description: "The oldest job in atd queue has been waiting for {{ $value | humanizeDuration }}. This may indicate a problem with job execution."

            # Alert if queue is growing excessively (> 100 jobs)
            - alert: AtdQueueOverloaded
              expr: atd_queue_total > 100
              for: 15m
              labels:
                severity: warning
                service: atd
              annotations:
                summary: "ATD queue has {{ $value }} jobs on {{ $labels.instance }}"
                description: "The atd queue has grown to {{ $value }} jobs, which may indicate excessive scheduling or execution problems."

            # Alert if exporter hasn't run recently (stale metrics)
            - alert: AtdExporterStale
              expr: |
                (time() - atd_exporter_last_run_timestamp) > 300
              for: 5m
              labels:
                severity: warning
                service: atd
              annotations:
                summary: "ATD exporter metrics are stale on {{ $labels.instance }}"
                description: "The atd-exporter hasn't updated metrics in over 5 minutes. Last update was {{ $value | humanizeDuration }} ago."
    ''
  ];
}
