{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Custom Nagios check for atd queue status
  checkAtdQueue = pkgs.writeShellScript "check_atd_queue.sh" ''
    set -euo pipefail

    # Nagios exit codes
    STATE_OK=0
    STATE_WARNING=1
    STATE_CRITICAL=2
    STATE_UNKNOWN=3

    # Thresholds
    QUEUE_WARNING=''${1:-50}     # Warn if queue has > 50 jobs
    QUEUE_CRITICAL=''${2:-100}   # Critical if queue has > 100 jobs

    # Check if atd service is running
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet atd; then
      echo "CRITICAL: atd service is not running"
      exit "$STATE_CRITICAL"
    fi

    # Get queue count
    QUEUE_OUTPUT=$(${pkgs.at}/bin/atq 2>&1 || true)

    if echo "$QUEUE_OUTPUT" | grep -q "Cannot open /var/spool/cron/atjobs"; then
      echo "UNKNOWN: Cannot access atd queue (spool directory not accessible)"
      exit "$STATE_UNKNOWN"
    fi

    # Count jobs in queue
    if [ -z "$QUEUE_OUTPUT" ]; then
      QUEUE_COUNT=0
    else
      QUEUE_COUNT=$(echo "$QUEUE_OUTPUT" | wc -l)
    fi

    # Check oldest job age (if queue not empty)
    if [ "$QUEUE_COUNT" -gt 0 ]; then
      # Get oldest job timestamp
      OLDEST_JOB=$(echo "$QUEUE_OUTPUT" | head -1 | awk '{print $2, $3, $4, $5}')
      OLDEST_TIMESTAMP=$(${pkgs.coreutils}/bin/date -d "$OLDEST_JOB" +%s 2>/dev/null || echo "0")
      CURRENT_TIMESTAMP=$(${pkgs.coreutils}/bin/date +%s)

      if [ "$OLDEST_TIMESTAMP" -gt 0 ]; then
        AGE_SECONDS=$((CURRENT_TIMESTAMP - OLDEST_TIMESTAMP))
        AGE_HOURS=$((AGE_SECONDS / 3600))

        # Warn if oldest job is more than 24 hours old
        if [ "$AGE_HOURS" -gt 24 ]; then
          echo "WARNING: $QUEUE_COUNT jobs in queue, oldest job is ''${AGE_HOURS}h old (possible stuck job)"
          exit "$STATE_WARNING"
        fi
      fi
    fi

    # Check queue size thresholds
    if [ "$QUEUE_COUNT" -ge "$QUEUE_CRITICAL" ]; then
      echo "CRITICAL: $QUEUE_COUNT jobs in atd queue (threshold: $QUEUE_CRITICAL)"
      exit "$STATE_CRITICAL"
    elif [ "$QUEUE_COUNT" -ge "$QUEUE_WARNING" ]; then
      echo "WARNING: $QUEUE_COUNT jobs in atd queue (threshold: $QUEUE_WARNING)"
      exit "$STATE_WARNING"
    fi

    # All good
    echo "OK: $QUEUE_COUNT jobs in atd queue, service running normally"
    exit "$STATE_OK"
  '';
  # Nagios object definitions for atd monitoring
  atdNagiosObjectDefs = pkgs.writeText "atd-nagios.cfg" ''
    # ============================================================================
    # ATD Commands
    # ============================================================================

    define command {
      command_name    check_atd_queue
      command_line    ${checkAtdQueue} $ARG1$ $ARG2$
    }

    define command {
      command_name    check_atd_web
      command_line    ${pkgs.monitoring-plugins}/bin/check_http -H $HOSTADDRESS$ -p $ARG1$ -u /health -e "HTTP/1.0 200" -w 5 -c 10
    }

    # ============================================================================
    # ATD Services
    # ============================================================================

    # ATD Service Status
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     ATD Service
      check_command           check_systemd_service!atd.service
      service_groups          critical-infrastructure
    }

    # ATD Web Interface
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     ATD Web Interface
      check_command           check_systemd_service!atd-web.service
      service_groups          critical-infrastructure
    }

    # ATD Web Health Check
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     ATD Web Health
      check_command           check_atd_web!9281
      service_groups          critical-infrastructure
    }

    # ATD Queue Monitoring
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     ATD Queue Status
      check_command           check_atd_queue!50!100
      service_groups          critical-infrastructure
    }

    # ATD Exporter Timer
    define service {
      use                     low-priority-service
      host_name               vulcan
      service_description     ATD Exporter Timer
      check_command           check_systemd_service!atd-exporter.timer
      service_groups          monitoring-stack
    }

    # ATD Exporter Service
    define service {
      use                     low-priority-service
      host_name               vulcan
      service_description     ATD Exporter Service
      check_command           check_systemd_service_ondemand!atd-exporter.service
      service_groups          monitoring-stack
    }

    # ATD HTTPS Virtual Host
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     ATD HTTPS (atd.vulcan.lan)
      check_command           check_https!atd.vulcan.lan!/
      service_groups          application-services
    }

    # ATD SSL Certificate
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     ATD SSL Certificate
      check_command           check_ssl_cert!atd.vulcan.lan
      service_groups          ssl-certificates
    }
  '';
in
{
  # ============================================================================
  # ATD Nagios Monitoring Configuration
  # ============================================================================

  # Add ATD object definitions to Nagios
  services.nagios.objectDefs = [ atdNagiosObjectDefs ];
}
