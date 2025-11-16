{ config, lib, pkgs, ... }:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  # AIDE metrics collection script
  aideMetrics = pkgs.writeShellScript "aide-metrics" ''
    set -euo pipefail

    OUTPUT_FILE="${textfileDir}/aide.prom"
    TEMP_FILE="$OUTPUT_FILE.$$"

    # Write metrics header
    cat > "$TEMP_FILE" <<'HEADER'
# HELP aide_database_age_seconds Age of AIDE database in seconds
# TYPE aide_database_age_seconds gauge
# HELP aide_database_exists Whether AIDE database exists
# TYPE aide_database_exists gauge
# HELP aide_check_status Status of last AIDE check (0=OK, 1=changes, 2=error, 3=unknown)
# TYPE aide_check_status gauge
# HELP aide_added_files Number of files added since last database update
# TYPE aide_added_files gauge
# HELP aide_removed_files Number of files removed since last database update
# TYPE aide_removed_files gauge
# HELP aide_changed_files Number of files changed since last database update
# TYPE aide_changed_files gauge
# HELP aide_total_entries Total number of database entries
# TYPE aide_total_entries gauge
HEADER

    # Check if AIDE database exists
    DB_PATH="/var/lib/aide/aide.db"
    if [[ ! -f "$DB_PATH" ]]; then
      cat >> "$TEMP_FILE" <<EOF
aide_database_exists 0
aide_database_age_seconds 0
aide_check_status 3
aide_added_files 0
aide_removed_files 0
aide_changed_files 0
aide_total_entries 0
EOF
      mv "$TEMP_FILE" "$OUTPUT_FILE"
      exit 0
    fi

    # Database exists
    DB_AGE=$(( $(date +%s) - $(stat -c %Y "$DB_PATH") ))
    echo "aide_database_exists 1" >> "$TEMP_FILE"
    echo "aide_database_age_seconds $DB_AGE" >> "$TEMP_FILE"

    # Run AIDE check and capture output
    CHECK_OUTPUT=$(${pkgs.aide}/bin/aide --check 2>&1 || true)
    EXIT_CODE=$?

    # Parse output (use $NF to get last field, handles tabs)
    # Note: AIDE prints "Number of entries:" when OK, "  Total number of entries:" when changes detected
    TOTAL=$(echo "$CHECK_OUTPUT" | grep "Number of entries:" | head -1 | ${pkgs.gawk}/bin/awk '{print $NF}' || echo "0")
    ADDED=$(echo "$CHECK_OUTPUT" | grep "^  Added entries:" | ${pkgs.gawk}/bin/awk '{print $NF}' || echo "0")
    REMOVED=$(echo "$CHECK_OUTPUT" | grep "^  Removed entries:" | ${pkgs.gawk}/bin/awk '{print $NF}' || echo "0")
    CHANGED=$(echo "$CHECK_OUTPUT" | grep "^  Changed entries:" | ${pkgs.gawk}/bin/awk '{print $NF}' || echo "0")

    # Determine status
    # 0=OK, 1-7=changes detected, 14+=error
    if [[ $EXIT_CODE -eq 0 ]]; then
      STATUS=0  # OK
    elif [[ $EXIT_CODE -ge 1 && $EXIT_CODE -le 7 ]]; then
      STATUS=1  # Changes detected
    else
      STATUS=2  # Error
    fi

    # Write metrics
    cat >> "$TEMP_FILE" <<EOF
aide_check_status $STATUS
aide_added_files $ADDED
aide_removed_files $REMOVED
aide_changed_files $CHANGED
aide_total_entries $TOTAL
EOF

    # Atomic move
    mv "$TEMP_FILE" "$OUTPUT_FILE"
  '';

in {
  # Run AIDE metrics collection daily after AIDE check
  systemd.services.aide-metrics = {
    description = "Collect AIDE metrics for Prometheus";
    after = [ "aide-check.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${aideMetrics}";
      User = "root";
    };
  };

  # Run metrics collection after AIDE check
  systemd.services.aide-check.serviceConfig.ExecStartPost = [
    "${aideMetrics}"
  ];

  # Also run metrics on timer to ensure Prometheus has fresh data
  # Note: This runs AIDE check, so it should match aide-check.timer frequency
  systemd.timers.aide-metrics = {
    description = "Collect AIDE metrics daily";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };

  # Link the service to the timer
  systemd.services.aide-metrics.wantedBy = lib.mkForce [];
}
