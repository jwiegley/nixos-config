{ config, lib, pkgs, ... }:

let
  # Define aria2 monitoring rules as a separate file
  aria2RulesFile = pkgs.writeText "aria2-alerts.yml" ''
    groups:
    - name: aria2_alerts
      interval: 60s
      rules:
      # Alert if aria2 service is down
      - alert: Aria2ServiceDown
        expr: up{job="aria2"} == 0
        for: 2m
        labels:
          severity: critical
          service: aria2
        annotations:
          summary: "aria2 download manager is down"
          description: "The aria2 download manager service is not responding. Check service status with 'systemctl status aria2.service' and logs with 'journalctl -u aria2.service -f'"

      # Alert if aria2 RPC is not responding
      - alert: Aria2RpcNotResponding
        expr: aria2_up == 0
        for: 2m
        labels:
          severity: critical
          service: aria2
        annotations:
          summary: "aria2 RPC interface is not responding"
          description: "The aria2 RPC interface is not responding to queries. Check if the service is running and the RPC secret is correctly configured."

      # Alert if there are many error downloads
      - alert: Aria2HighErrorRate
        expr: aria2_error_downloads > 10
        for: 10m
        labels:
          severity: warning
          service: aria2
        annotations:
          summary: "aria2 has many failed downloads"
          description: "aria2 has {{ $value }} failed downloads. Check the aria2 web UI at https://aria.vulcan.lan to investigate errors."

      # Alert if download queue is backing up
      - alert: Aria2QueueBacklog
        expr: aria2_waiting_downloads > 50
        for: 15m
        labels:
          severity: warning
          service: aria2
        annotations:
          summary: "aria2 download queue is backing up"
          description: "aria2 has {{ $value }} downloads waiting in queue. This may indicate slow download speeds, network issues, or resource constraints."

      # Alert if no active downloads but queue exists
      - alert: Aria2StuckQueue
        expr: aria2_active_downloads == 0 and aria2_waiting_downloads > 5
        for: 30m
        labels:
          severity: warning
          service: aria2
        annotations:
          summary: "aria2 queue is stuck"
          description: "aria2 has {{ $value }} downloads waiting but none are active. The service may be stuck or experiencing issues. Check logs with 'journalctl -u aria2.service -f'"

      # Alert if download speed is unusually low with active downloads
      - alert: Aria2SlowDownloads
        expr: aria2_download_speed_bytes < 100000 and aria2_active_downloads > 0
        for: 10m
        labels:
          severity: info
          service: aria2
        annotations:
          summary: "aria2 download speed is very low"
          description: "aria2 download speed is {{ $value | humanize }}B/s with active downloads. This may indicate network issues, slow servers, or bandwidth limitations."

      # Alert if exporter is behind (stale metrics)
      - alert: Aria2ExporterStale
        expr: time() - aria2_exporter_last_scrape_timestamp_seconds > 300
        for: 5m
        labels:
          severity: warning
          service: aria2
        annotations:
          summary: "aria2 metrics exporter is stale"
          description: "The aria2 Prometheus exporter hasn't updated metrics in {{ $value | humanizeDuration }}. Check 'systemctl status aria2-exporter.service'"

      # Alert if AriaNG web UI is not accessible
      - alert: Aria2WebUiDown
        expr: probe_success{job="blackbox-https", instance="https://aria.vulcan.lan"} == 0
        for: 5m
        labels:
          severity: warning
          service: aria2
        annotations:
          summary: "aria2 web interface is not accessible"
          description: "The AriaNG web interface at https://aria.vulcan.lan is not responding. Check nginx configuration and certificate status."
  '';
in
{
  # Prometheus alert rules for aria2 monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ aria2RulesFile ];
}
