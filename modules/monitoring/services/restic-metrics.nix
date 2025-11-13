{ config, lib, pkgs, ... }:

let
  # Shared restic metrics collection script
  # Used by both CLI tool and systemd service
  resticMetricsScript = pkgs.writeShellScript "collect-restic-metrics" ''
        #!/usr/bin/env bash
        set -euo pipefail

        OUTPUT_FILE="/var/lib/prometheus-node-exporter-textfiles/restic.prom"
        TEMP_FILE="$OUTPUT_FILE.$$"
        S3_BASE="s3:s3.us-west-001.backblazeb2.com"

        REPOSITORIES=(
          "Audio"
          "Backups"
          "Databases"
          "Home"
          "Photos"
          "Video"
          "doc"
          "src"
        )

        if [ -f /run/secrets/aws-keys ]; then
          source /run/secrets/aws-keys
          export AWS_ACCESS_KEY_ID
          export AWS_SECRET_ACCESS_KEY
        fi

        if [ -f /run/secrets/restic-password ]; then
          export RESTIC_PASSWORD=$(cat /run/secrets/restic-password)
        fi

        cat > "$TEMP_FILE" <<'HEADER'
# HELP restic_check_success Whether the last restic check was successful (1 = success, 0 = failure)
# TYPE restic_check_success gauge
# HELP restic_snapshots_total Total number of snapshots in the repository
# TYPE restic_snapshots_total gauge
# HELP restic_repo_size_bytes Total size of the repository (raw data) in bytes
# TYPE restic_repo_size_bytes gauge
# HELP restic_repo_files_total Total number of files in the repository
# TYPE restic_repo_files_total gauge
# HELP restic_restore_size_bytes Total size of files if restored
# TYPE restic_restore_size_bytes gauge
# HELP restic_unique_files_total Total number of unique files (by contents)
# TYPE restic_unique_files_total gauge
# HELP restic_unique_size_bytes Total size of unique file contents
# TYPE restic_unique_size_bytes gauge
# HELP restic_last_snapshot_timestamp_seconds Timestamp of the most recent snapshot
# TYPE restic_last_snapshot_timestamp_seconds gauge
# HELP restic_last_check_timestamp_seconds Timestamp of the last check operation
# TYPE restic_last_check_timestamp_seconds gauge
# HELP restic_scrape_duration_seconds Time taken to collect metrics for this repository
# TYPE restic_scrape_duration_seconds gauge
HEADER

        for repo in "''${REPOSITORIES[@]}"; do
          START_TIME=$(date +%s)
          echo "Checking repository: $repo" >&2

          # Map repository name to bucket name (Backups uses Backups-Misc)
          case "$repo" in
            "Backups")
              BUCKET="Backups-Misc"
              ;;
            *)
              BUCKET="$repo"
              ;;
          esac

          REPO_URL="$S3_BASE/jwiegley-$BUCKET"
          CHECK_SUCCESS=0
          SNAPSHOT_COUNT=0
          REPO_SIZE=0
          REPO_FILES=0
          RESTORE_SIZE=0
          UNIQUE_FILES=0
          UNIQUE_SIZE=0
          LAST_SNAPSHOT_TIME=0
          TIMESTAMP=$(date +%s)

          # Try to collect comprehensive stats
          if SNAPSHOTS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" snapshots --json 2>/dev/null); then
            # Check if we got valid JSON
            if echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq -e . >/dev/null 2>&1; then
              CHECK_SUCCESS=1

              # Count snapshots
              SNAPSHOT_COUNT=$(echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq 'length // 0')

              # Get latest snapshot timestamp
              if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
                # Get the latest timestamp string and convert to epoch using date command
                LATEST_TIME_STR=$(echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq -r 'map(.time) | sort | last // empty')
                if [ -n "$LATEST_TIME_STR" ]; then
                  LAST_SNAPSHOT_TIME=$(${pkgs.coreutils}/bin/date -d "$LATEST_TIME_STR" +%s 2>/dev/null || echo "0")
                fi
              fi

              # Get raw data stats (total repository size)
              if RAW_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode raw-data --json 2>/dev/null); then
                REPO_SIZE=$(echo "$RAW_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
                REPO_FILES=$(echo "$RAW_STATS" | ${pkgs.jq}/bin/jq -r '.total_file_count // 0')
              fi

              # Get restore size stats (size if all files were restored)
              if RESTORE_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode restore-size --json 2>/dev/null); then
                RESTORE_SIZE=$(echo "$RESTORE_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
              fi

              # Get unique files stats (deduplication info)
              if UNIQUE_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode files-by-contents --json 2>/dev/null); then
                UNIQUE_FILES=$(echo "$UNIQUE_STATS" | ${pkgs.jq}/bin/jq -r '.total_file_count // 0')
                UNIQUE_SIZE=$(echo "$UNIQUE_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
              fi
            else
              echo "Failed to parse snapshots JSON for repository: $repo" >&2
            fi
          else
            echo "Failed to list snapshots for repository: $repo" >&2
          fi

          # Calculate scrape duration
          END_TIME=$(date +%s)
          SCRAPE_DURATION=$((END_TIME - START_TIME))

          # Write all metrics for this repository
          cat >> "$TEMP_FILE" <<EOF
restic_check_success{repository="$repo"} $CHECK_SUCCESS
restic_snapshots_total{repository="$repo"} $SNAPSHOT_COUNT
restic_repo_size_bytes{repository="$repo"} $REPO_SIZE
restic_repo_files_total{repository="$repo"} $REPO_FILES
restic_restore_size_bytes{repository="$repo"} $RESTORE_SIZE
restic_unique_files_total{repository="$repo"} $UNIQUE_FILES
restic_unique_size_bytes{repository="$repo"} $UNIQUE_SIZE
restic_last_snapshot_timestamp_seconds{repository="$repo"} $LAST_SNAPSHOT_TIME
restic_last_check_timestamp_seconds{repository="$repo"} $TIMESTAMP
restic_scrape_duration_seconds{repository="$repo"} $SCRAPE_DURATION
EOF
        done

        mv "$TEMP_FILE" "$OUTPUT_FILE"
        chmod 644 "$OUTPUT_FILE"
        echo "Restic metrics collection complete" >&2
      '';
in
{
  # Make CLI tool available for manual execution
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "collect-restic-metrics" ''
      exec ${resticMetricsScript}
    '')
  ];

  # Restic metrics collection for multiple repositories
  # Systemd service to collect restic metrics
  # Auto-start when tank mount becomes available
  # ConditionPathIsMountPoint prevents "failed" status during rebuild when mount unavailable
  systemd.services.restic-metrics = {
    description = "Collect Restic Repository Metrics";
    wants = [ "network-online.target" "zfs.target" "zfs-import-tank.service" ];
    after = [ "network-online.target" "zfs.target" "zfs-import-tank.service" ];
    # No wantedBy - service only runs via timer
    unitConfig = {
      RequiresMountsFor = [ "/tank" ];
      ConditionPathIsMountPoint = "/tank";
    };

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${resticMetricsScript}";
      User = "root";
      Group = "root";
      # Increase timeout since checking multiple repositories can take time
      TimeoutSec = "30m";
    };
  };

  # Systemd timer to periodically collect restic metrics
  # Auto-start when tank mount becomes available
  systemd.timers.restic-metrics = {
    description = "Timer for Restic Repository Metrics Collection";
    wantedBy = [ "timers.target" "tank.mount" ];
    timerConfig = {
      OnBootSec = "5min";       # Run 5 minutes after boot
      OnUnitActiveSec = "6h";   # Run every 6 hours
      Persistent = true;        # Run missed timers on boot
    };
  };
}
