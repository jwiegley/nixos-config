{ config, lib, pkgs, ... }:

let
  # Define the syncoid services we're monitoring
  syncoidServices = [
    "syncoid-rpool-home"
    "syncoid-rpool-nix"
    "syncoid-rpool-root"
  ];

  # Create systemd overrides for each syncoid service
  mkSyncoidMonitoring = name: {
    "${name}" = {
      unitConfig = {
        # Add failure handling
        OnFailure = "zfs-replication-alert@%n.service";
      };
      serviceConfig = {
        # Add success/failure hooks for monitoring
        ExecStartPost = "${pkgs.bash}/bin/bash -c 'echo \"$(date): Replication started\" >> /var/log/zfs-replication.log'";
        ExecStopPost = "${pkgs.bash}/bin/bash -c 'if [ \"$SERVICE_RESULT\" = \"success\" ]; then echo \"$(date): Replication completed successfully\" >> /var/log/zfs-replication.log; else echo \"$(date): Replication failed with result $SERVICE_RESULT\" >> /var/log/zfs-replication.log; fi'";
      };
    };
  };

  # Merge all syncoid service overrides
  syncoidServiceOverrides = lib.mkMerge (map mkSyncoidMonitoring syncoidServices);

  # Define ZFS replication monitoring rules for Prometheus
  replicationRulesFile = pkgs.writeText "zfs-replication-alerts.yml" ''
    groups:
      - name: zfs_replication_alerts
        interval: 5m
        rules:
          # Alert when syncoid service fails
          - alert: ZFSReplicationFailed
            expr: |
              systemd_unit_state{name=~"syncoid-rpool-.*\\.service",state="failed"} == 1
            for: 5m
            labels:
              severity: critical
              component: zfs_replication
            annotations:
              summary: "ZFS replication service {{ $labels.name }} has failed"
              description: "The ZFS replication service {{ $labels.name }} is in failed state and needs immediate attention"

          # Alert when replication hasn't run in 30 hours (should run daily at 4am)
          - alert: ZFSReplicationNotRunning
            expr: |
              time() - systemd_service_last_trigger_timestamp_seconds{unit=~"syncoid-rpool-.*\\.timer"} > 108000
            for: 5m
            labels:
              severity: warning
              component: zfs_replication
            annotations:
              summary: "ZFS replication {{ $labels.unit }} hasn't run in over 30 hours"
              description: "The ZFS replication {{ $labels.unit }} last ran {{ $value | humanizeDuration }} ago (scheduled daily at 4am)"

          # Alert when replication timer is not active
          - alert: ZFSReplicationTimerInactive
            expr: |
              systemd_unit_state{name=~"syncoid-rpool-.*\\.timer",state="active"} == 0
            for: 5m
            labels:
              severity: warning
              component: zfs_replication
            annotations:
              summary: "ZFS replication timer {{ $labels.name }} is not active"
              description: "The ZFS replication timer {{ $labels.name }} is not in active state, replication won't run automatically"

          # Alert when ZFS pool has errors (affects replication reliability)
          - alert: ZFSPoolErrorsDetected
            expr: |
              node_zfs_zpool_read_errors > 0 or node_zfs_zpool_write_errors > 0 or node_zfs_zpool_checksum_errors > 0
            for: 5m
            labels:
              severity: warning
              component: zfs_replication
            annotations:
              summary: "ZFS pool {{ $labels.pool }} has errors"
              description: "ZFS pool {{ $labels.pool }} has read/write/checksum errors which may affect replication reliability"

          # Alert if destination dataset is running low on space
          - alert: ZFSReplicationDestinationLowSpace
            expr: |
              node_zfs_dataset_available_bytes{dataset=~"tank/Backups/rpool/.*"} < 10737418240
            for: 5m
            labels:
              severity: warning
              component: zfs_replication
            annotations:
              summary: "ZFS replication destination has less than 10GB free"
              description: "Dataset {{ $labels.dataset }} has only {{ $value | humanize1024 }}B free space"
  '';

  # Script to check replication status
  replicationStatusScript = pkgs.writeShellApplication {
    name = "check-zfs-replication";
    runtimeInputs = with pkgs; [ zfs systemd jq ];
    text = ''
      echo "=== ZFS Replication Status ==="
      echo ""

      # Check each syncoid service
      for service in ${lib.concatStringsSep " " syncoidServices}; do
        echo "Service: $service"

        # Get service status
        STATUS=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

        # Get last run time from timer
        TIMER_LAST_RUN=$(systemctl show -p LastTriggerUSec --value "$service.timer" 2>/dev/null || echo "never")

        # Get next run time from timer
        TIMER_NEXT_RUN=$(systemctl show -p NextElapseUSecRealtime --value "$service.timer" 2>/dev/null || echo "never")

        # Get last exit status
        EXIT_STATUS=$(systemctl show -p ExecMainStatus --value "$service" 2>/dev/null || echo "unknown")

        echo "  Status: $STATUS"
        if [ "$TIMER_LAST_RUN" != "never" ] && [ "$TIMER_LAST_RUN" != "n/a" ]; then
          echo "  Last Run: $(date -d "@$((''${TIMER_LAST_RUN%000000}/1000000))" 2>/dev/null || echo "$TIMER_LAST_RUN")"
        else
          echo "  Last Run: Never"
        fi

        if [ "$TIMER_NEXT_RUN" != "never" ] && [ "$TIMER_NEXT_RUN" != "n/a" ] && [ "$TIMER_NEXT_RUN" != "" ]; then
          echo "  Next Run: $(date -d "@$((''${TIMER_NEXT_RUN%000000}/1000000))" 2>/dev/null || echo "$TIMER_NEXT_RUN")"
        else
          echo "  Next Run: Not scheduled"
        fi

        if [ "$EXIT_STATUS" != "0" ] && [ "$EXIT_STATUS" != "unknown" ]; then
          echo "  ⚠ Last Exit Code: $EXIT_STATUS"
        fi
        echo ""
      done

      echo "=== ZFS Snapshot Differences ==="
      for fs in home nix root; do
        echo ""
        echo "Checking rpool/$fs -> tank/Backups/rpool/$fs:"

        # Get latest snapshot on source
        SOURCE_SNAP=$(zfs list -H -t snapshot -o name -S creation "rpool/$fs" 2>/dev/null | head -1)

        # Get latest snapshot on destination
        DEST_SNAP=$(zfs list -H -t snapshot -o name -S creation "tank/Backups/rpool/$fs" 2>/dev/null | head -1)

        if [ -n "$SOURCE_SNAP" ]; then
          SOURCE_SNAP_NAME="''${SOURCE_SNAP#*/}"
          echo "  Source latest: $SOURCE_SNAP_NAME"
        else
          echo "  Source: No snapshots found"
        fi

        if [ -n "$DEST_SNAP" ]; then
          DEST_SNAP_NAME="''${DEST_SNAP#*/}"
          echo "  Dest latest:   $DEST_SNAP_NAME"

          # Check if snapshots match (same snapshot name exists on both)
          if [ -n "$SOURCE_SNAP" ]; then
            SOURCE_BASE="''${SOURCE_SNAP_NAME#*@}"
            DEST_BASE="''${DEST_SNAP_NAME#*@}"
            if [ "$SOURCE_BASE" = "$DEST_BASE" ]; then
              echo "  ✓ In sync"
            else
              echo "  ⚠ Out of sync - replication needed"
            fi
          fi
        else
          echo "  Dest: No snapshots found (initial replication needed)"
        fi
      done

      echo ""
      echo "=== Recent Replication Log Entries ==="
      if [ -f /var/log/zfs-replication.log ]; then
        tail -10 /var/log/zfs-replication.log 2>/dev/null || echo "No recent entries"
      else
        echo "Log file not yet created"
      fi
    '';
  };
in
{
  # Merge all systemd services into one definition
  systemd.services = lib.mkMerge [
    # Alert service template for ZFS replication failures
    {
      "zfs-replication-alert@" = {
        description = "ZFS replication failure alert for %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "zfs-replication-alert" ''
            SERVICE_NAME="$1"
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

            # Log to systemd journal with high priority
            echo "ZFS REPLICATION FAILURE: $SERVICE_NAME failed at $TIMESTAMP" | \
              ${pkgs.systemd}/bin/systemd-cat -p err -t zfs-replication-alert

            # Create a persistent alert file for monitoring
            ALERT_FILE="/var/lib/zfs-replication-alerts/$(echo "$SERVICE_NAME" | sed 's/[^a-zA-Z0-9-]/_/g').alert"
            mkdir -p /var/lib/zfs-replication-alerts
            echo "$TIMESTAMP - $SERVICE_NAME failed" > "$ALERT_FILE"

            # Log to replication log
            echo "$TIMESTAMP: ALERT - $SERVICE_NAME failed" >> /var/log/zfs-replication.log

            # Send email alert via logwatch mechanism (will be included in daily report)
            echo "Subject: [CRITICAL] ZFS Replication Failure on vulcan" > /tmp/replication-alert.txt
            echo "From: root@vulcan.lan" >> /tmp/replication-alert.txt
            echo "" >> /tmp/replication-alert.txt
            echo "ZFS Replication service $SERVICE_NAME has failed at $TIMESTAMP" >> /tmp/replication-alert.txt
            echo "" >> /tmp/replication-alert.txt
            echo "Please check the service with:" >> /tmp/replication-alert.txt
            echo "  systemctl status $SERVICE_NAME" >> /tmp/replication-alert.txt
            echo "  journalctl -u $SERVICE_NAME -n 50" >> /tmp/replication-alert.txt

            # If sendmail is available, send immediate alert
            if command -v sendmail >/dev/null 2>&1; then
              sendmail johnw@newartisans.com < /tmp/replication-alert.txt
            fi
            rm -f /tmp/replication-alert.txt
          '';
        };
      };

      # Daily ZFS replication status check
      zfs-replication-status-check = {
        description = "Daily ZFS replication status check";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "zfs-replication-status-check" ''
            echo "=== ZFS Replication Status Check ===" | ${pkgs.systemd}/bin/systemd-cat -t zfs-replication-status

            # Check each syncoid service
            for service in ${lib.concatStringsSep " " syncoidServices}; do
              STATUS=$(${pkgs.systemd}/bin/systemctl is-active "$service" || echo "unknown")
              LAST_RUN=$(${pkgs.systemd}/bin/systemctl show -p ExecMainExitTimestamp --value "$service")

              if [ "$STATUS" = "failed" ]; then
                echo "❌ $service: FAILED (last attempt: $LAST_RUN)" | ${pkgs.systemd}/bin/systemd-cat -p err -t zfs-replication-status
              elif [ -n "$LAST_RUN" ] && [ "$LAST_RUN" != "n/a" ]; then
                echo "✓ $service: OK (last success: $LAST_RUN)" | ${pkgs.systemd}/bin/systemd-cat -t zfs-replication-status
              else
                echo "⚠ $service: Never run" | ${pkgs.systemd}/bin/systemd-cat -p warning -t zfs-replication-status
              fi
            done

            # Check for any alert files
            if [ -d /var/lib/zfs-replication-alerts ]; then
              ALERTS=$(find /var/lib/zfs-replication-alerts -name "*.alert" -mtime -1 2>/dev/null | wc -l)
              if [ "$ALERTS" -gt 0 ]; then
                echo "⚠ $ALERTS ZFS replication failure(s) in the last 24 hours" | ${pkgs.systemd}/bin/systemd-cat -p warning -t zfs-replication-status
                find /var/lib/zfs-replication-alerts -name "*.alert" -mtime -1 -exec cat {} \; | ${pkgs.systemd}/bin/systemd-cat -p warning -t zfs-replication-status
              fi
            fi

            # Log status to file for logwatch
            ${lib.getExe replicationStatusScript} >> /var/log/zfs-replication-status.log 2>&1
          '';
        };
      };

      # Manual replication trigger (useful for testing)
      zfs-replication-manual = {
        description = "Manual trigger for ZFS replication";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "zfs-replication-manual" ''
            echo "Starting manual ZFS replication..."
            for service in ${lib.concatStringsSep " " syncoidServices}; do
              echo "Triggering $service..."
              ${pkgs.systemd}/bin/systemctl start "$service"
              # Wait a bit between services to avoid overwhelming the system
              sleep 2
            done
            echo "Manual replication triggered. Check status with: systemctl status syncoid-*"
          '';
        };
      };
    }

    # Apply syncoid service overrides
    syncoidServiceOverrides
  ];

  # Timer for daily replication status check (runs at 6am, 2 hours after replication)
  systemd.timers.zfs-replication-status-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00";
      OnBootSec = "15min";
      Persistent = true;
    };
  };

  # Add ZFS replication monitoring rules to Prometheus
  services.prometheus.ruleFiles = [ replicationRulesFile ];

  # Add custom logwatch service for ZFS replication
  services.logwatch.customServices = [
    {
      name = "zfs-replication";
      title = "ZFS Replication Status";
      script = lib.getExe replicationStatusScript;
    }
  ];

  # Create state directories and log files
  systemd.tmpfiles.rules = [
    "d /var/lib/zfs-replication-alerts 0755 root root -"
    "f /var/log/zfs-replication.log 0644 root root -"
    "f /var/log/zfs-replication-status.log 0644 root root -"
  ];

  # Add monitoring check script to system packages
  environment.systemPackages = [ replicationStatusScript ];
}