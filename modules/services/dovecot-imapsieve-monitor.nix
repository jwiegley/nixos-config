{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Script to monitor imapsieve health by checking Dovecot logs
  imapsieveHealthCheckScript = pkgs.writeShellScript "imapsieve-health-check" ''
    set -euo pipefail

    METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/imapsieve.prom"
    LOG_SINCE="5 minutes ago"

    # Initialize counters
    SIEVE_ERRORS=0
    SIEVE_WARNINGS=0
    PERMISSION_ERRORS=0
    COMPILATION_ERRORS=0
    RUNTIME_ERRORS=0

    # Check for Sieve-related errors in Dovecot logs
    if LOGS=$(${pkgs.systemd}/bin/journalctl -u dovecot2 --since "$LOG_SINCE" 2>/dev/null); then
      # Count permission errors (should trigger alerts if affecting message delivery)
      PERMISSION_ERRORS=$(echo "$LOGS" | { grep -i "sieve.*permission denied" || true; } | wc -l)

      # Check if permission errors are blocking message processing (critical)
      PERMISSION_BLOCKING=$(echo "$LOGS" | { grep -i "sieve.*permission denied.*process-good" || true; } | wc -l)

      # Count compilation errors (critical)
      COMPILATION_ERRORS=$(echo "$LOGS" | { grep -i "sieve.*validation failed\|sieve.*compile.*fail" || true; } | wc -l)

      # Count runtime errors (critical)
      RUNTIME_ERRORS=$(echo "$LOGS" | { grep -i "sieve.*error" || true; } | { grep -iv "permission denied" || true; } | wc -l)

      # Count warnings
      SIEVE_WARNINGS=$(echo "$LOGS" | { grep -i "sieve.*warning" || true; } | wc -l)

      # Total errors (include permission errors if they're blocking message processing)
      if [ "$PERMISSION_BLOCKING" -gt 0 ]; then
        SIEVE_ERRORS=$((COMPILATION_ERRORS + RUNTIME_ERRORS + PERMISSION_BLOCKING))
      else
        SIEVE_ERRORS=$((COMPILATION_ERRORS + RUNTIME_ERRORS))
      fi
    fi

    # Write metrics to Prometheus textfile collector
    {
      echo "# HELP imapsieve_errors_total Total number of critical imapsieve/Sieve errors"
      echo "# TYPE imapsieve_errors_total counter"
      echo "imapsieve_errors_total $SIEVE_ERRORS"

      echo "# HELP imapsieve_permission_errors_total Total number of Sieve permission errors"
      echo "# TYPE imapsieve_permission_errors_total counter"
      echo "imapsieve_permission_errors_total $PERMISSION_ERRORS"

      echo "# HELP imapsieve_permission_blocking_total Total number of permission errors blocking message processing"
      echo "# TYPE imapsieve_permission_blocking_total counter"
      echo "imapsieve_permission_blocking_total $PERMISSION_BLOCKING"

      echo "# HELP imapsieve_compilation_errors_total Total number of Sieve compilation errors"
      echo "# TYPE imapsieve_compilation_errors_total counter"
      echo "imapsieve_compilation_errors_total $COMPILATION_ERRORS"

      echo "# HELP imapsieve_runtime_errors_total Total number of Sieve runtime errors"
      echo "# TYPE imapsieve_runtime_errors_total counter"
      echo "imapsieve_runtime_errors_total $RUNTIME_ERRORS"

      echo "# HELP imapsieve_warnings_total Total number of Sieve warnings"
      echo "# TYPE imapsieve_warnings_total counter"
      echo "imapsieve_warnings_total $SIEVE_WARNINGS"

      echo "# HELP imapsieve_last_check_timestamp_seconds Timestamp of last health check"
      echo "# TYPE imapsieve_last_check_timestamp_seconds gauge"
      echo "imapsieve_last_check_timestamp_seconds $(date +%s)"

      echo "# HELP imapsieve_health_status Health status (1 = healthy, 0 = errors detected)"
      echo "# TYPE imapsieve_health_status gauge"
      if [ "$SIEVE_ERRORS" -eq 0 ]; then
        echo "imapsieve_health_status 1"
      else
        echo "imapsieve_health_status 0"
      fi
    } > "$METRICS_FILE.tmp"

    mv "$METRICS_FILE.tmp" "$METRICS_FILE"
    chmod 644 "$METRICS_FILE"

    # Output status for systemd
    if [ "$SIEVE_ERRORS" -gt 0 ]; then
      echo "CRITICAL: Found $SIEVE_ERRORS critical Sieve errors in last 5 minutes"
      echo "  Compilation errors: $COMPILATION_ERRORS"
      echo "  Runtime errors: $RUNTIME_ERRORS"
      if [ "$PERMISSION_BLOCKING" -gt 0 ]; then
        echo "  Permission errors blocking message processing: $PERMISSION_BLOCKING"
      fi
      exit 2
    elif [ "$PERMISSION_ERRORS" -gt 0 ]; then
      if [ "$PERMISSION_BLOCKING" -gt 0 ]; then
        echo "CRITICAL: Permission errors are blocking message processing"
        echo "  Permission errors affecting process-good.sieve: $PERMISSION_BLOCKING"
        exit 2
      else
        echo "INFO: Found $PERMISSION_ERRORS benign permission errors (compilation cache)"
        exit 0
      fi
    else
      echo "OK: No Sieve errors detected"
      exit 0
    fi
  '';
in
{
  # Systemd service to check imapsieve health
  systemd.services.dovecot-imapsieve-health-check = {
    description = "Monitor Dovecot imapsieve health";
    after = [ "dovecot2.service" ];
    wants = [ "dovecot2.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${imapsieveHealthCheckScript}";
      User = "root"; # Need root to read journalctl
      Group = "root";

      # Don't fail the service on exit codes 1 or 2 (warnings/critical)
      # We want to export metrics even when there are errors
      SuccessExitStatus = "0 1 2";
    };

    path = with pkgs; [
      systemd
      coreutils
    ];
  };

  # Timer to run health check every 5 minutes
  systemd.timers.dovecot-imapsieve-health-check = {
    description = "Timer for dovecot-imapsieve-health-check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };

  # Prometheus alerting rules for imapsieve
  services.prometheus.ruleFiles = [
    (pkgs.writeText "imapsieve-alerts.yml" ''
      groups:
        - name: imapsieve
          interval: 1m
          rules:
            # Alert on critical Sieve errors
            - alert: ImapsieveCriticalErrors
              expr: increase(imapsieve_errors_total[10m]) > 0
              for: 5m
              labels:
                severity: critical
                component: mail
              annotations:
                summary: "Critical imapsieve/Sieve errors detected"
                description: "{{ $value }} critical Sieve errors detected in the last 10 minutes. Check Dovecot logs with: journalctl -u dovecot2 --since '10 minutes ago' | grep -i sieve"

            # Alert on Sieve runtime errors
            - alert: ImapsieveRuntimeErrors
              expr: increase(imapsieve_runtime_errors_total[10m]) > 0
              for: 5m
              labels:
                severity: critical
                component: mail
              annotations:
                summary: "imapsieve runtime errors detected"
                description: "{{ $value }} Sieve runtime errors detected in the last 10 minutes. Mail filtering may not be working correctly."

            # Alert on Sieve compilation errors
            - alert: ImapsieveCompilationErrors
              expr: increase(imapsieve_compilation_errors_total[10m]) > 0
              for: 5m
              labels:
                severity: critical
                component: mail
              annotations:
                summary: "Sieve script compilation errors detected"
                description: "{{ $value }} Sieve compilation errors detected. Scripts may have syntax errors or missing dependencies."

            # Alert if health check hasn't run recently
            - alert: ImapsieveHealthCheckStale
              expr: (time() - imapsieve_last_check_timestamp_seconds) > 600
              for: 5m
              labels:
                severity: warning
                component: mail
              annotations:
                summary: "imapsieve health check is stale"
                description: "imapsieve health check hasn't run in {{ $value }}s. Check if the timer is working: systemctl status dovecot-imapsieve-health-check.timer"

            # Critical alert for permission errors blocking message processing
            - alert: ImapsievePermissionBlocking
              expr: increase(imapsieve_permission_blocking_total[10m]) > 0
              for: 2m
              labels:
                severity: critical
                component: mail
              annotations:
                summary: "Sieve permission errors blocking message processing"
                description: "{{ $value }} permission errors are preventing process-good.sieve from working. Messages are not being filtered correctly. Check: journalctl --since '10 minutes ago' | grep 'sieve.*permission'"

            # Info alert for excessive permission errors (not critical but worth noting)
            - alert: ImapsievePermissionErrorsHigh
              expr: increase(imapsieve_permission_errors_total[1h]) > 100
              for: 10m
              labels:
                severity: info
                component: mail
              annotations:
                summary: "High number of Sieve permission errors"
                description: "{{ $value }} Sieve permission errors in the last hour. These may be benign compilation cache errors."
    '')
  ];
}
