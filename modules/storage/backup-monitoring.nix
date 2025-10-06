{ config, lib, pkgs, ... }:

let
  # Get list of all backup names
  backupNames = builtins.attrNames config.services.restic.backups;

  # Create systemd overrides for each backup service
  mkBackupMonitoring = name: {
    "restic-backups-${name}" = {
      unitConfig = {
        # Add failure handling
        OnFailure = "backup-alert@%n.service";
      };
      serviceConfig = {
        # Add automatic restart with backoff
        Restart = lib.mkForce "on-failure";
        RestartSec = "30min";
        RestartSteps = 3;
        RestartMaxDelaySec = "2h";
      };
    };
  };

  # Merge all backup service overrides
  backupServiceOverrides = lib.mkMerge (map mkBackupMonitoring backupNames);

  # Define backup monitoring rules as a separate file
  # Using double backslashes to properly escape dots in regex patterns
  backupRulesFile = pkgs.writeText "backup-alerts.yml" ''
    groups:
      - name: backup_alerts
        interval: 5m
        rules:
          # Alert when backup service fails
          - alert: BackupServiceFailed
            expr: |
              systemd_unit_state{name=~"restic-backups-.*\\.service",state="failed"} == 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Backup service {{ $labels.name }} has failed"
              description: "The backup service {{ $labels.name }} is in failed state and needs attention"

          # Alert when backup hasn't run in 36 hours (should run daily)
          - alert: BackupNotRunning
            expr: |
              time() - systemd_service_last_trigger_timestamp_seconds{unit=~"restic-backups-.*\\.timer"} > 129600
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Backup {{ $labels.unit }} hasn't run in over 36 hours"
              description: "The backup {{ $labels.unit }} last ran {{ $value | humanizeDuration }} ago"

          # Alert when backup timer is not active
          - alert: BackupTimerInactive
            expr: |
              systemd_unit_state{name=~"restic-backups-.*\\.timer",state="active"} == 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Backup timer {{ $labels.name }} is not active"
              description: "The backup timer {{ $labels.name }} is not in active state"
  '';
in
{
  # Merge all systemd services into one definition
  systemd.services = lib.mkMerge [
    # Alert service template
    {
      "backup-alert@" = {
        description = "Backup failure alert for %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "backup-alert" ''
            SERVICE_NAME="$1"
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

            # Log to systemd journal with high priority
            echo "BACKUP FAILURE: $SERVICE_NAME failed at $TIMESTAMP" | \
              ${pkgs.systemd}/bin/systemd-cat -p err -t backup-alert

            # Create a persistent alert file for monitoring
            ALERT_FILE="/var/lib/backup-alerts/$(echo "$SERVICE_NAME" | sed 's/[^a-zA-Z0-9-]/_/g').alert"
            mkdir -p /var/lib/backup-alerts
            echo "$TIMESTAMP" > "$ALERT_FILE"

            # If wallabag is running, create a notification there too
            if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-wallabag; then
              echo "Backup failure: $SERVICE_NAME at $TIMESTAMP" >> /var/log/backup-failures.log
            fi
          '';
        };
      };

    }

    # Apply backup service overrides
    backupServiceOverrides
  ];

  # Add backup monitoring rules as a separate file
  # This avoids YAML structure conflicts with the main rules
  services.prometheus.ruleFiles = [ backupRulesFile ];

  # Create state directory for alerts
  systemd.tmpfiles.rules = [
    "d /var/lib/backup-alerts 0755 root root -"
    "f /var/log/backup-failures.log 0644 root root -"
  ];
}
