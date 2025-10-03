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
    runtimeInputs = with pkgs; [ zfs systemd jq coreutils gnugrep gawk ];
    text = ''
      echo "=== ZFS Replication Status ==="
      echo ""

      # Get timer information for all syncoid services at once
      TIMER_INFO=$(systemctl list-timers 'syncoid-*' --no-pager --no-legend 2>/dev/null || true)

      # Check each syncoid service
      for service in ${lib.concatStringsSep " " syncoidServices}; do
        echo "Service: $service"

        # Get service status
        STATUS=$(systemctl is-active "$service" 2>/dev/null || echo "inactive")

        # Get result of last run (success/failed)
        RESULT=$(systemctl show -p Result --value "$service" 2>/dev/null || echo "unknown")

        # Get exit code of last run
        EXIT_CODE=$(systemctl show -p ExecMainStatus --value "$service" 2>/dev/null || echo "0")

        # Extract timer info for this service
        TIMER_LINE=$(echo "$TIMER_INFO" | grep "$service.timer" || true)

        if [ -n "$TIMER_LINE" ]; then
          # Extract NEXT and LAST columns from timer output
          # Format: "NEXT (date time tz) LEFT LAST (date time tz) PASSED UNIT ACTIVATES"
          NEXT=$(echo "$TIMER_LINE" | awk '{print $1, $2, $3}')
          PASSED=$(echo "$TIMER_LINE" | awk '{
            # Find "ago" and print what comes before it
            for (i=1; i<=NF; i++) {
              if ($i == "ago") {
                print $(i-1), $i
                break
              }
            }
          }')
          LAST_DATE=$(echo "$TIMER_LINE" | awk '{
            # Find the date/time after LEFT column
            for (i=1; i<=NF; i++) {
              if ($i == "ago") {
                # Print date and time (2-3 fields before "ago")
                if ((i-3) > 0) {
                  print $(i-3), $(i-2)
                }
                break
              }
            }
          }')

          echo "  Status: $STATUS (result: $RESULT)"
          if [ -n "$LAST_DATE" ]; then
            echo "  Last Run: $LAST_DATE ($PASSED)"
          else
            echo "  Last Run: Unknown"
          fi
          echo "  Next Run: $NEXT"
        else
          echo "  Status: $STATUS"
          echo "  Last Run: Unknown"
          echo "  Next Run: Timer not found"
        fi

        # Show exit code only if non-zero
        if [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "unknown" ]; then
          echo "  ⚠ Last Exit Code: $EXIT_CODE"
        fi

        # Get the most recent journal entry about successful transfer
        RECENT_SUCCESS=$(journalctl -u "$service.service" --since "48 hours ago" --no-pager -q 2>/dev/null | \
          grep "INFO: Sending incremental" | tail -1 || true)

        if [ -n "$RECENT_SUCCESS" ]; then
          # Extract and show brief summary
          SIZE_INFO=$(echo "$RECENT_SUCCESS" | grep -oP '\(~ \K[^)]+' || true)
          if [ -n "$SIZE_INFO" ]; then
            echo "  Last transfer: ~$SIZE_INFO"
          fi
        fi

        # Check for actual errors (not just cleanup warnings)
        RECENT_ERRORS=$(journalctl -u "$service.service" --since "48 hours ago" --no-pager -q 2>/dev/null | \
          grep -i "error\|critical\|cannot send" | grep -v "cannot destroy snapshots" | tail -1 || true)

        if [ -n "$RECENT_ERRORS" ]; then
          echo "  ⚠ Recent error: $(echo "$RECENT_ERRORS" | cut -c1-80)"
        fi

        echo ""
      done

      echo "=== ZFS Syncoid Snapshot Status ==="
      for fs in home nix root; do
        echo ""
        echo "Checking rpool/$fs -> tank/Backups/rpool/$fs:"

        # Get latest SYNCOID snapshot on source (ignore autosnap)
        SOURCE_SYNCOID=$(zfs list -H -t snapshot -o name -S creation "rpool/$fs" 2>/dev/null | \
          grep "syncoid_vulcan_" | head -1 || true)

        # Get latest SYNCOID snapshot on destination
        DEST_SYNCOID=$(zfs list -H -t snapshot -o name -S creation "tank/Backups/rpool/$fs" 2>/dev/null | \
          grep "syncoid_vulcan_" | head -1 || true)

        if [ -n "$SOURCE_SYNCOID" ]; then
          SOURCE_SNAP_NAME="''${SOURCE_SYNCOID#*@}"
          SOURCE_DATE=$(echo "$SOURCE_SNAP_NAME" | grep -oP '\d{4}-\d{2}-\d{2}' || echo "unknown")
          echo "  Source latest syncoid: $SOURCE_DATE ($(echo "$SOURCE_SNAP_NAME" | cut -c1-40)...)"
        else
          echo "  ⚠ Source: No syncoid snapshots found"
        fi

        if [ -n "$DEST_SYNCOID" ]; then
          DEST_SNAP_NAME="''${DEST_SYNCOID#*@}"
          DEST_DATE=$(echo "$DEST_SNAP_NAME" | grep -oP '\d{4}-\d{2}-\d{2}' || echo "unknown")
          echo "  Dest latest syncoid:   $DEST_DATE ($(echo "$DEST_SNAP_NAME" | cut -c1-40)...)"
        else
          echo "  ⚠ Dest: No syncoid snapshots found"
        fi

        # Check if they match
        if [ -n "$SOURCE_SYNCOID" ] && [ -n "$DEST_SYNCOID" ]; then
          if [ "$SOURCE_SNAP_NAME" = "$DEST_SYNCOID" ] || [ "$(basename "$SOURCE_SYNCOID")" = "$(basename "$DEST_SYNCOID")" ]; then
            echo "  ✓ Fully synchronized"
          elif [ "$SOURCE_DATE" = "$DEST_DATE" ]; then
            echo "  ✓ Same date (likely in sync, minor time difference)"
          else
            DAYS_BEHIND=$(( ( $(date -d "$SOURCE_DATE" +%s) - $(date -d "$DEST_DATE" +%s) ) / 86400 ))
            if [ "$DAYS_BEHIND" -gt 0 ]; then
              echo "  ⚠ Destination is $DAYS_BEHIND day(s) behind"
            else
              echo "  ⚠ Snapshot mismatch (investigate)"
            fi
          fi
        fi
      done

      echo ""
      echo "=== Recent Replication Activity (Last 48 Hours) ==="

      # Get recent successful replications from journal
      SUCCESS_COUNT=0
      for service in ${lib.concatStringsSep " " syncoidServices}; do
        SERVICE_SHORT="''${service#syncoid-rpool-}"

        # Check for successful runs (strip any whitespace/newlines)
        RUNS=$(journalctl -u "$service.service" --since "48 hours ago" --no-pager -q 2>/dev/null | \
          grep -c "Deactivated successfully" 2>/dev/null || echo "0")
        RUNS=$(echo "$RUNS" | tr -d '\n\r' | grep -oE '[0-9]+' || echo "0")

        if [ "$RUNS" -gt 0 ] 2>/dev/null; then
          SUCCESS_COUNT=$((SUCCESS_COUNT + RUNS))
          LAST_SUCCESS=$(journalctl -u "$service.service" --since "48 hours ago" --no-pager -q 2>/dev/null | \
            grep "Deactivated successfully" | tail -1 | awk '{print $1, $2, $3}' || echo "")
          echo "  ✓ $SERVICE_SHORT: $RUNS successful run(s), last: $LAST_SUCCESS"
        else
          echo "  ⚠ $SERVICE_SHORT: No successful runs in last 48 hours"
        fi
      done

      if [ "$SUCCESS_COUNT" -gt 0 ]; then
        echo ""
        echo "Total: $SUCCESS_COUNT successful replication(s) in last 48 hours"
      fi

      # Show any critical errors from journal (last 48 hours only)
      echo ""
      echo "=== Critical Issues (Last 48 Hours) ==="

      HAS_CRITICAL=0
      for service in ${lib.concatStringsSep " " syncoidServices}; do
        # Look for real errors (excluding cleanup warnings)
        CRITICAL=$(journalctl -u "$service.service" --since "48 hours ago" --no-pager -q 2>/dev/null | \
          grep -i "error\|critical\|failed" | \
          grep -v "cannot destroy snapshots" | \
          grep -v "WARNING:.*zfs destroy" | \
          grep -v "Deactivated successfully" | \
          tail -3 || true)

        if [ -n "$CRITICAL" ]; then
          SERVICE_SHORT="''${service#syncoid-rpool-}"
          echo "  ⚠ $SERVICE_SHORT:"
          echo "$CRITICAL" | while IFS= read -r line; do
            echo "    $(echo "$line" | cut -c1-100)"
          done
          HAS_CRITICAL=1
        fi
      done

      if [ "$HAS_CRITICAL" -eq 0 ]; then
        echo "  ✓ No critical issues detected"
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
            echo "$(date): Manual replication triggered" >> /var/log/zfs-replication.log
            for service in ${lib.concatStringsSep " " syncoidServices}; do
              echo "Triggering $service..."
              ${pkgs.systemd}/bin/systemctl start "$service"
              # Log the trigger
              echo "$(date): Manually triggered $service" >> /var/log/zfs-replication.log
              # Wait a bit between services to avoid overwhelming the system
              sleep 2
            done
            echo "Manual replication triggered. Check status with: systemctl status syncoid-*"
          '';
        };
      };

      # Logging service that monitors syncoid completion
      "zfs-replication-logger@" = {
        description = "Log ZFS replication event for %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "zfs-replication-logger" ''
            SERVICE_NAME="''${1:-$1}"
            RESULT=$(${pkgs.systemd}/bin/systemctl show -p Result --value "$SERVICE_NAME")
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

            if [ "$RESULT" = "success" ]; then
              echo "$TIMESTAMP: $SERVICE_NAME completed successfully" >> /var/log/zfs-replication.log
            else
              echo "$TIMESTAMP: $SERVICE_NAME failed with result: $RESULT" >> /var/log/zfs-replication.log
            fi
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