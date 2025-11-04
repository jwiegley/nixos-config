{ config, lib, pkgs, ... }:

let
  # Define vdirsyncer monitoring rules as a separate file
  vdirsyncerRulesFile = pkgs.writeText "vdirsyncer-alerts.yml" ''
    groups:
    - name: vdirsyncer_alerts
      interval: 60s
      rules:
      # Alert if vdirsyncer hasn't synced successfully in 30 minutes
      - alert: VdirsyncerNotSyncing
        expr: (time() - vdirsyncer_last_sync_timestamp) > 1800
        for: 5m
        labels:
          severity: warning
          service: vdirsyncer
        annotations:
          summary: "vdirsyncer hasn't synced in {{ $value | humanizeDuration }}"
          description: "The vdirsyncer service hasn't successfully synced contacts in over 30 minutes. Last successful sync was {{ $value | humanizeDuration }} ago. Expected sync every 15 minutes."

      # Alert if vdirsyncer sync is unhealthy
      - alert: VdirsyncerSyncUnhealthy
        expr: vdirsyncer_sync_healthy == 0
        for: 10m
        labels:
          severity: warning
          service: vdirsyncer
        annotations:
          summary: "vdirsyncer sync status is unhealthy"
          description: "The vdirsyncer sync health check has been failing for over 10 minutes. Check the status dashboard at https://vdirsyncer.vulcan.lan or logs with 'journalctl -u vdirsyncer.service -f'"

      # Alert if vdirsyncer sync hasn't run in 1 hour (critical)
      - alert: VdirsyncerNotSyncingCritical
        expr: (time() - vdirsyncer_last_sync_timestamp) > 3600
        for: 5m
        labels:
          severity: critical
          service: vdirsyncer
        annotations:
          summary: "vdirsyncer sync has been down for over 1 hour"
          description: "The vdirsyncer service hasn't successfully synced contacts in over 1 hour. Last successful sync was {{ $value | humanizeDuration }} ago. This may indicate a service failure or authentication issue."

      # Alert if vdirsyncer collections are missing (potential configuration issue)
      - alert: VdirsyncerNoCollections
        expr: vdirsyncer_collections_total == 0
        for: 15m
        labels:
          severity: critical
          service: vdirsyncer
        annotations:
          summary: "vdirsyncer has no collections configured"
          description: "No collections are being synced by vdirsyncer. This may indicate a discovery issue or authentication problem. Run 'sudo -u vdirsyncer vdirsyncer --config /etc/vdirsyncer/config discover' to troubleshoot."

      # Alert if sync duration is unusually long (potential performance issue)
      - alert: VdirsyncerSlowSync
        expr: vdirsyncer_last_sync_duration_seconds > 300
        for: 5m
        labels:
          severity: warning
          service: vdirsyncer
        annotations:
          summary: "vdirsyncer sync is taking unusually long"
          description: "The last vdirsyncer sync took {{ $value }} seconds (over 5 minutes). This may indicate network issues, large data sync, or service problems."

      # Alert if vdirsyncer status service is down
      - alert: VdirsyncerStatusServiceDown
        expr: up{job="vdirsyncer"} == 0
        for: 5m
        labels:
          severity: warning
          service: vdirsyncer
        annotations:
          summary: "vdirsyncer status service is down"
          description: "The vdirsyncer status dashboard and metrics exporter is not responding. Check service with 'systemctl status vdirsyncer-status.service'"
  '';
in
{
  # Prometheus alert rules for vdirsyncer monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ vdirsyncerRulesFile ];
}
