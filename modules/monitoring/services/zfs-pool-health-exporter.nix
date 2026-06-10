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
      pkgs.gnused
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
      # HELP zfs_pool_suspended 1 if the pool is in the SUSPENDED state (I/O frozen, e.g. UAS-enclosure cascade), 0 otherwise
      # TYPE zfs_pool_suspended gauge
      # HELP zfs_pool_unavail 1 if the pool top-level state is UNAVAIL (devices missing/unreadable), 0 otherwise
      # TYPE zfs_pool_unavail gauge
      # HELP zfs_pool_last_scrub_timestamp_seconds Unix timestamp the last completed scrub finished (0 if never scrubbed)
      # TYPE zfs_pool_last_scrub_timestamp_seconds gauge
      # HELP zfs_pool_last_scrub_errors Number of errors reported by the last completed scrub (0 = clean)
      # TYPE zfs_pool_last_scrub_errors gauge
      # HELP zfs_newest_snapshot_timestamp_seconds Creation time of the newest snapshot anywhere under the pool (0 if none)
      # TYPE zfs_newest_snapshot_timestamp_seconds gauge
      # HELP zfs_pool_health_collector_run_timestamp_seconds Unix timestamp this textfile collector last ran to completion
      # TYPE zfs_pool_health_collector_run_timestamp_seconds gauge
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

              # Pool I/O frozen? "zpool status" prints a "state: SUSPENDED" line and a
              # "status:" warning when ZFS has suspended I/O (the UAS-enclosure cascade:
              # see project_tank_uas_enclosure_failure). Detect it directly from the
              # status text rather than relying on node-exporter's zpool_state, which
              # has reported the pool ONLINE while the underlying bridge hung.
              if echo "$STATUS" | grep -qE "^[[:space:]]*state:[[:space:]]+SUSPENDED"; then
                echo "zfs_pool_suspended{pool=\"$pool\"} 1" >> "$TEMP_FILE"
              else
                echo "zfs_pool_suspended{pool=\"$pool\"} 0" >> "$TEMP_FILE"
              fi

              # Pool top-level UNAVAIL (devices missing/unreadable) — suspended-equivalent
              # for alerting purposes but emitted separately for diagnosis.
              if echo "$STATUS" | grep -qE "^[[:space:]]*state:[[:space:]]+UNAVAIL"; then
                echo "zfs_pool_unavail{pool=\"$pool\"} 1" >> "$TEMP_FILE"
              else
                echo "zfs_pool_unavail{pool=\"$pool\"} 0" >> "$TEMP_FILE"
              fi

              # Last completed scrub timestamp + error count. The "scan:" line of a
              # finished scrub reads e.g.
              #   scan: scrub repaired 0B in 15:13:45 with 0 errors on Mon Jun  1 19:03:39 2026
              # Scrubs run monthly (zfs-scrub.timer), so a stale scrub means the
              # monthly integrity sweep stopped happening. Only parse the completed
              # form: a scrub IN PROGRESS ("scrub in progress since ...") or a pool
              # never scrubbed ("none requested") leaves the previous value at 0,
              # which the ZFSScrubStale rule tolerates via the for: window.
              SCAN_LINE=$(echo "$STATUS" | grep -E "^[[:space:]]*scan:" || true)
              SCRUB_TS=0
              SCRUB_ERRORS=0
              if echo "$SCAN_LINE" | grep -q "scrub repaired"; then
                # Date tail follows the last " on " in the completed-scrub line.
                SCRUB_DATE=$(echo "$SCAN_LINE" | sed -E 's/.* on //')
                if [ -n "$SCRUB_DATE" ]; then
                  SCRUB_TS=$(date -d "$SCRUB_DATE" +%s 2>/dev/null || echo 0)
                fi
                # "with N errors" -> N; absent/unparsable defaults to 0.
                SCRUB_ERRORS=$(echo "$SCAN_LINE" | grep -oP '\d+(?= errors)' || echo 0)
              fi
              echo "zfs_pool_last_scrub_timestamp_seconds{pool=\"$pool\"} ''${SCRUB_TS:-0}" >> "$TEMP_FILE"
              echo "zfs_pool_last_scrub_errors{pool=\"$pool\"} ''${SCRUB_ERRORS:-0}" >> "$TEMP_FILE"

              # Newest snapshot anywhere under this pool. Sanoid (sanoid.timer,
              # hourly) takes the snapshots; if it stalls the newest creation time
              # stops advancing. `zfs list -t snapshot` with -p gives the creation
              # time as a raw epoch, sorted ascending, so the last line is newest.
              # Recursing on the pool root covers every dataset cheaply (one call).
              NEWEST_SNAP_TS=$(zfs list -t snapshot -r -H -p -o creation -s creation "$pool" 2>/dev/null | tail -n1 || true)
              echo "zfs_newest_snapshot_timestamp_seconds{pool=\"$pool\"} ''${NEWEST_SNAP_TS:-0}" >> "$TEMP_FILE"

            done < <(zpool list -H -o name 2>/dev/null)

            # Collector liveness: record when this run finished so a stalled or
            # crashed collector (no fresh textfile) is detectable even while the
            # last-written values look healthy. Emitted once (no pool label).
            echo "zfs_pool_health_collector_run_timestamp_seconds $(date +%s)" >> "$TEMP_FILE"

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
