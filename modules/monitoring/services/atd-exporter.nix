{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Custom Prometheus exporter for atd job queue monitoring
  atd-exporter = pkgs.writeShellApplication {
    name = "atd-exporter";
    runtimeInputs = with pkgs; [
      at
      coreutils
      gawk
      gnugrep
    ];
    text = ''
            # Prometheus textfile exporter for atd queue metrics
            # Outputs metrics to /var/lib/prometheus-node-exporter-textfiles/atd.prom

            TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"
            TEMP_FILE="$TEXTFILE_DIR/atd.prom.$$"
            OUTPUT_FILE="$TEXTFILE_DIR/atd.prom"

            # Ensure directory exists
            mkdir -p "$TEXTFILE_DIR"

            # Get queue statistics
            queue_output=$(atq 2>&1 || echo "")

            # Count total jobs in queue
            if [ -z "$queue_output" ] || echo "$queue_output" | grep -q "Cannot open /var/spool/cron/atjobs"; then
              # atd not ready or no jobs
              total_jobs=0
            else
              total_jobs=$(echo "$queue_output" | wc -l)
            fi

            # Count jobs by queue (a-z, A-Z)
            # atq output format: job# date time queue user
            declare -A queue_counts
            if [ "$total_jobs" -gt 0 ]; then
              while read -r line; do
                queue=$(echo "$line" | awk '{print $6}')
                if [ -n "$queue" ]; then
                  queue_counts["$queue"]=$((''${queue_counts[$queue]:-0} + 1))
                fi
              done <<< "$queue_output"
            fi

            # Get oldest job timestamp (for alerting on stuck jobs)
            if [ "$total_jobs" -gt 0 ]; then
              oldest_job_date=$(echo "$queue_output" | head -1 | awk '{print $2, $3}')
              oldest_job_timestamp=$(date -d "$oldest_job_date" +%s 2>/dev/null || echo "0")
            else
              oldest_job_timestamp=0
            fi

            # Check if atd service is running
            if systemctl is-active --quiet atd; then
              atd_running=1
            else
              atd_running=0
            fi

            # Write metrics to temp file
            cat > "$TEMP_FILE" << EOF
      # HELP atd_queue_total Total number of jobs in atd queue
      # TYPE atd_queue_total gauge
      atd_queue_total $total_jobs

      # HELP atd_queue_jobs Number of jobs in each queue (a-z, A-Z)
      # TYPE atd_queue_jobs gauge
      EOF

            # Add per-queue metrics
            for queue in "''${!queue_counts[@]}"; do
              echo "atd_queue_jobs{queue=\"$queue\"} ''${queue_counts[$queue]}" >> "$TEMP_FILE"
            done

            # Add oldest job timestamp
            cat >> "$TEMP_FILE" << EOF

      # HELP atd_oldest_job_timestamp Unix timestamp of oldest job in queue (0 if no jobs)
      # TYPE atd_oldest_job_timestamp gauge
      atd_oldest_job_timestamp $oldest_job_timestamp

      # HELP atd_service_running ATD service status (1=running, 0=not running)
      # TYPE atd_service_running gauge
      atd_service_running $atd_running

      # HELP atd_exporter_last_run_timestamp Unix timestamp of last successful exporter run
      # TYPE atd_exporter_last_run_timestamp gauge
      atd_exporter_last_run_timestamp $(date +%s)
      EOF

            # Atomic move to prevent partial reads
            mv "$TEMP_FILE" "$OUTPUT_FILE"
            chmod 644 "$OUTPUT_FILE"
    '';
  };
in
{
  # ============================================================================
  # ATD Prometheus Exporter
  # Custom exporter using textfile collector
  # ============================================================================

  # Systemd timer to run exporter every minute
  systemd.timers."atd-exporter" = {
    description = "ATD Prometheus Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      Unit = "atd-exporter.service";
    };
  };

  systemd.services."atd-exporter" = {
    description = "ATD Prometheus Exporter";
    after = [
      "atd.service"
      "prometheus-node-exporter.service"
    ];
    wants = [ "atd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe atd-exporter}";
      User = "root"; # Needs root to run atq and check systemd status
      Group = "root";
      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
    };
  };
}
