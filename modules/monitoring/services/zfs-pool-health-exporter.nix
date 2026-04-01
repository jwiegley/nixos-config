{
  config,
  lib,
  pkgs,
  ...
}:

let
  zfsPoolHealthScript = pkgs.writeShellApplication {
    name = "collect-zfs-pool-health";
    runtimeInputs = [
      pkgs.zfs
      pkgs.gawk
      pkgs.gnugrep
      pkgs.coreutils
    ];
    text = ''
            OUTPUT_FILE="/var/lib/prometheus-node-exporter-textfiles/zfs_pool_health.prom"
            TEMP_FILE="$OUTPUT_FILE.$$"

            cat > "$TEMP_FILE" <<'HEADER'
      # HELP zfs_pool_scrub_active 1 if a scrub is currently in progress for the pool, 0 otherwise
      # TYPE zfs_pool_scrub_active gauge
      # HELP zfs_pool_data_errors Number of permanent data errors detected in the pool (0 = clean)
      # TYPE zfs_pool_data_errors gauge
      # HELP zfs_pool_device_read_errors Total read errors across all devices in the pool
      # TYPE zfs_pool_device_read_errors gauge
      # HELP zfs_pool_device_checksum_errors Total checksum errors across all devices in the pool
      # TYPE zfs_pool_device_checksum_errors gauge
      HEADER

            while IFS= read -r pool; do
              STATUS=$(zpool status -p "$pool" 2>/dev/null) || continue

              # Scrub active?
              if echo "$STATUS" | grep -q "scrub in progress"; then
                echo "zfs_pool_scrub_active{pool=\"$pool\"} 1" >> "$TEMP_FILE"
              else
                echo "zfs_pool_scrub_active{pool=\"$pool\"} 0" >> "$TEMP_FILE"
              fi

              # Data error count from "errors: N data errors" or "errors: No known data errors"
              ERRORS_LINE=$(echo "$STATUS" | grep "^errors:" || true)
              if echo "$ERRORS_LINE" | grep -q "No known data errors"; then
                DATA_ERRORS=0
              else
                DATA_ERRORS=$(echo "$ERRORS_LINE" | grep -oP '\d+(?= data errors)' || echo "")
                # If the errors line exists but we couldn't parse a count, pool has errors
                if [ -z "$DATA_ERRORS" ] && ! echo "$ERRORS_LINE" | grep -q "No known data errors"; then
                  DATA_ERRORS=1
                fi
              fi
              echo "zfs_pool_data_errors{pool=\"$pool\"} ''${DATA_ERRORS:-0}" >> "$TEMP_FILE"

              # Sum device-level READ and CKSUM errors from the vdev config table
              # Lines in config section are tab-indented with format: name STATE READ WRITE CKSUM
              # Use state keywords to identify device rows (skips pool/vdev group rows with 0s)
              READ_ERRORS=$(echo "$STATUS" | awk '
                /^config:/ { in_config=1; next }
                in_config && /^errors:/ { in_config=0 }
                in_config && /\tSTATE/ { next }
                in_config && /ONLINE|DEGRADED|FAULTED|OFFLINE|REMOVED|UNAVAIL/ && NF>=5 { sum += $3 }
                END { print sum+0 }
              ')
              CKSUM_ERRORS=$(echo "$STATUS" | awk '
                /^config:/ { in_config=1; next }
                in_config && /^errors:/ { in_config=0 }
                in_config && /\tSTATE/ { next }
                in_config && /ONLINE|DEGRADED|FAULTED|OFFLINE|REMOVED|UNAVAIL/ && NF>=5 { sum += $5 }
                END { print sum+0 }
              ')

              echo "zfs_pool_device_read_errors{pool=\"$pool\"} ''${READ_ERRORS:-0}" >> "$TEMP_FILE"
              echo "zfs_pool_device_checksum_errors{pool=\"$pool\"} ''${CKSUM_ERRORS:-0}" >> "$TEMP_FILE"

            done < <(zpool list -H -o name 2>/dev/null)

            mv "$TEMP_FILE" "$OUTPUT_FILE"
    '';
  };
in

{
  systemd.services."zfs-pool-health-metrics" = {
    description = "Collect ZFS pool health metrics for Prometheus textfile exporter";
    after = [
      "zfs.target"
      "zfs-import-tank.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${zfsPoolHealthScript}/bin/collect-zfs-pool-health";
      User = "root";
    };
  };

  systemd.timers."zfs-pool-health-metrics" = {
    description = "Periodically collect ZFS pool health metrics";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
      Persistent = true;
    };
  };
}
