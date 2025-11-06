{ config, lib, pkgs, ... }:

let
  # Define n8n monitoring rules as a separate file
  n8nRulesFile = pkgs.writeText "n8n-alerts.yml" ''
    groups:
    - name: n8n_alerts
      interval: 60s
      rules:
      # Alert if n8n service is down
      - alert: N8nServiceDown
        expr: up{job="n8n"} == 0
        for: 2m
        labels:
          severity: critical
          service: n8n
        annotations:
          summary: "n8n service is down"
          description: "The n8n workflow automation service is not responding. Check service status with 'systemctl status n8n.service' and logs with 'journalctl -u n8n.service -f'"

      # Alert if workflow error rate is high
      - alert: N8nHighErrorRate
        expr: rate(n8n_workflow_execution_errors_total[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
          service: n8n
        annotations:
          summary: "n8n workflow error rate is high"
          description: "n8n is experiencing {{ $value | humanizePercentage }} workflow execution errors per second. Check failed workflows in the n8n UI at https://n8n.vulcan.lan"

      # Alert if workflow error rate is critical
      - alert: N8nCriticalErrorRate
        expr: rate(n8n_workflow_execution_errors_total[5m]) > 0.5
        for: 5m
        labels:
          severity: critical
          service: n8n
        annotations:
          summary: "n8n workflow error rate is critical"
          description: "n8n is experiencing {{ $value | humanizePercentage }} workflow execution errors per second (over 50%). This indicates a serious problem. Check logs immediately with 'journalctl -u n8n.service -f'"

      # Alert if queue is backing up
      - alert: N8nQueueBacklog
        expr: n8n_queue_waiting > 100
        for: 10m
        labels:
          severity: warning
          service: n8n
        annotations:
          summary: "n8n has a large queue backlog"
          description: "n8n has {{ $value }} workflows waiting in queue. This may indicate slow execution, resource constraints, or increased workload. Consider scaling workers or investigating slow workflows."

      # Alert if queue backlog is critical
      - alert: N8nQueueBacklogCritical
        expr: n8n_queue_waiting > 500
        for: 5m
        labels:
          severity: critical
          service: n8n
        annotations:
          summary: "n8n queue backlog is critical"
          description: "n8n has {{ $value }} workflows waiting in queue (over 500). System is severely backed up. Check worker status and consider immediate scaling."

      # Alert if workflow execution is very slow (95th percentile)
      - alert: N8nSlowExecutions
        expr: histogram_quantile(0.95, rate(n8n_workflow_execution_duration_seconds_bucket[5m])) > 300
        for: 10m
        labels:
          severity: warning
          service: n8n
        annotations:
          summary: "n8n workflow executions are slow"
          description: "95th percentile workflow execution time is {{ $value | humanizeDuration }} (over 5 minutes). This may indicate performance issues, slow external APIs, or resource constraints."

      # Alert if database connection issues
      - alert: N8nDatabaseErrors
        expr: rate(n8n_database_errors_total[5m]) > 0.01
        for: 5m
        labels:
          severity: critical
          service: n8n
        annotations:
          summary: "n8n is experiencing database errors"
          description: "n8n has {{ $value }} database errors per second. Check PostgreSQL service status and n8n logs for connection issues."

      # Alert if Redis connection issues (if metric exists)
      - alert: N8nRedisConnectionFailure
        expr: n8n_redis_connected == 0
        for: 2m
        labels:
          severity: critical
          service: n8n
        annotations:
          summary: "n8n Redis connection failed"
          description: "n8n has lost connection to Redis. Queue mode will not function properly. Check Redis service: 'systemctl status redis-n8n.service'"

      # Alert if no workflows have executed recently (potential issue)
      - alert: N8nNoRecentExecutions
        expr: rate(n8n_workflow_executions_total[30m]) == 0
        for: 1h
        labels:
          severity: info
          service: n8n
        annotations:
          summary: "n8n has no recent workflow executions"
          description: "No workflows have executed in the past hour. This may be normal if workflows are scheduled infrequently, or may indicate an issue with triggers or webhooks."

      # Alert if API response time is high
      - alert: N8nSlowApiResponses
        expr: histogram_quantile(0.95, rate(n8n_api_request_duration_seconds_bucket[5m])) > 5
        for: 10m
        labels:
          severity: warning
          service: n8n
        annotations:
          summary: "n8n API responses are slow"
          description: "95th percentile API response time is {{ $value | humanizeDuration }}. This may impact user experience and workflow performance."

      # Alert if memory usage is high (if metric exists)
      - alert: N8nHighMemoryUsage
        expr: process_resident_memory_bytes{job="n8n"} > 2147483648
        for: 10m
        labels:
          severity: warning
          service: n8n
        annotations:
          summary: "n8n memory usage is high"
          description: "n8n is using {{ $value | humanize1024 }}B of memory (over 2GB). Consider investigating memory leaks or increasing system resources."
  '';
in
{
  # Prometheus alert rules for n8n monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ n8nRulesFile ];
}
