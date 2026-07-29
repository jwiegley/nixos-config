{
  config,
  lib,
  pkgs,
  ...
}:

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
      # Aria2HighErrorRate DELETED 2026-07-28: it selected `aria2_error_downloads`, which
      #   this exporter does not publish -- 0 series now AND 0 across 30 days, while the
      #   exporter is demonstrably healthy (aria2_up=1, up{job="aria2"}=1) and publishing 8
      #   other aria2_* metrics.
      #   DIAGNOSIS CORRECTED 2026-07-29: I called this "a wrong metric NAME". It was not.
      #   aria2_error_downloads has 54,937 samples over 365d, existing 2026-01-10 to 01-19 and
      #   then vanishing along with aria2_completed_downloads and aria2_removed_downloads. The
      #   name was RIGHT for a January exporter that has since regressed and stopped
      #   publishing those three counters. The deletion still stands (0 series now and across
      #   30d), but the real follow-up is restoring the exporter's counters, not renaming.
      #   No replacement exists: the full published set is aria2_up, aria2_version_info,
      #   aria2_download_speed_bytes, aria2_upload_speed_bytes, aria2_active_downloads,
      #   aria2_waiting_downloads, aria2_stopped_downloads and aria2_stopped_total_downloads
      #   -- none of which distinguishes an errored download from a completed one
      #   ("stopped" covers both), so an error RATE cannot be derived. Reinstating this
      #   needs an exporter change to publish an error counter first.
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
      # Aria2ExporterStale DELETED 2026-07-28: it selected
      #   `aria2_exporter_last_scrape_timestamp_seconds`, which does not exist -- 0 series
      #   now and 0 across 30 days. Nor is a replacement needed: this exporter is scraped
      #   as its own Prometheus job, so `up{job="aria2"}` already distinguishes "not
      #   responding" and is what Aria2ServiceDown / Aria2RpcNotResponding above use. The
      #   "up but silently frozen" case that a last-scrape timestamp would catch does not
      #   apply to an HTTP-scraped exporter: if it cannot answer, the scrape fails and `up`
      #   goes to 0. (Textfile collectors DO need such a timestamp -- that is why
      #   TextfileCollectorStale exists -- but this is not one.)
      - alert: Aria2WebUiDown
        expr: probe_success{job="blackbox_https_local", instance="https://aria.vulcan.lan"} == 0
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
