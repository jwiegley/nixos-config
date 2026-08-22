{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Every S3-backed restic repository, DERIVED from services.restic.backups
  # rather than listed by hand.
  #
  # This replaced a hardcoded REPOSITORIES array on 2026-08-22. That array was
  # the known-bad pattern in this repo, and modules/services/monitoring.nix:40
  # already cites it by name as "the cautionary tale": "Public" was simply
  # missing from it, so that repo had zero B2-side coverage — no snapshot
  # freshness, no check, no size sanity — until a census caught it in 2026-06-09.
  # Adding /tank/Machines would have re-armed exactly that trap, so the list is
  # now computed and the drift is structurally impossible.
  #
  # The attribute names are unchanged by this (verified: Audio, Backups,
  # Databases, Documents, Home, Machines, Photos, Public, Video, doc, src), so
  # the repository="..." label on every metric keeps its existing values and no
  # alert rule or dashboard needs touching.
  #
  # Taking the URL straight from the backup also retires the old name->bucket
  # `case` statement: the only special case, Backups -> jwiegley-Backups-Misc,
  # is already spelled out in that backup's own `repository`, so the mapping had
  # been a second place to get the same fact wrong.
  resticRepos = lib.filterAttrs (
    _name: b: b.repository != null && lib.hasPrefix "s3:" b.repository
  ) config.services.restic.backups;

  # Emitted on one line apiece: a multi-line interpolation would not be subject
  # to the '' string's indentation stripping and would misalign the generated
  # script against the literal body around it.
  repoNamesBash = lib.concatMapStringsSep " " (n: ''"${n}"'') (lib.attrNames resticRepos);
  repoUrlsBash = lib.concatMapStringsSep " " (n: ''["${n}"]="${resticRepos.${n}.repository}"'') (
    lib.attrNames resticRepos
  );

  # Shared restic metrics collection script
  # Used by both CLI tool and systemd service
  resticMetricsScript = pkgs.writeShellScript "collect-restic-metrics" ''
            #!/usr/bin/env bash
            set -euo pipefail

            OUTPUT_FILE="/var/lib/prometheus-node-exporter-textfiles/restic.prom"
            TEMP_FILE="$OUTPUT_FILE.$$"

            # Both generated from services.restic.backups at build time; see the
            # note by resticRepos above. REPO_NAMES fixes the iteration order
            # (Nix attribute order is sorted, a bash associative array's is not)
            # so the generated .prom file stays byte-stable between runs.
            REPO_NAMES=( ${repoNamesBash} )
            declare -A REPO_URLS=( ${repoUrlsBash} )

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
    # HELP restic_last_check_timestamp_seconds Timestamp of the last restic-metrics COLLECTOR PASS for this repository (NOT a restic integrity check)
    # TYPE restic_last_check_timestamp_seconds gauge
    # HELP restic_scrape_duration_seconds Time taken to collect metrics for this repository
    # TYPE restic_scrape_duration_seconds gauge
    HEADER

            for repo in "''${REPO_NAMES[@]}"; do
              START_TIME=$(date +%s)
              echo "Checking repository: $repo" >&2

              REPO_URL="''${REPO_URLS[$repo]}"
              CHECK_SUCCESS=0
              SNAPSHOT_COUNT=0
              REPO_SIZE=0
              REPO_FILES=0
              RESTORE_SIZE=0
              UNIQUE_FILES=0
              UNIQUE_SIZE=0
              LAST_SNAPSHOT_TIME=0
              TIMESTAMP=$(date +%s)

              # Try to collect comprehensive stats.
              # --no-lock on every read-only call: a metrics query needs no lock,
              # and taking one is what caused the 2026-07-16 cascade — a run killed
              # at the 30m TimeoutSec left a stale lock on a slow B2 repo (Databases),
              # which hung every subsequent run into another timeout+lock. Lockless
              # reads can neither leave a lock nor block on a stale one, so a transient
              # B2 hang now fails at most one run and self-heals.
              if SNAPSHOTS=$(${pkgs.restic}/bin/restic --no-lock -r "$REPO_URL" snapshots --json 2>/dev/null); then
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
                  #
                  # NOTE: total_file_count is deliberately NOT read here. `--mode raw-data`
                  # counts BLOBS, not files -- restic's own help says it "Counts the size of
                  # blobs in the repository" -- so the field is simply absent from this
                  # mode's JSON and `// 0` silently produced 0. That made
                  # restic_repo_files_total read 0 for all nine repos for its entire life,
                  # while its siblings from the other two modes populated correctly
                  # (restic_unique_files_total is in the thousands). Fixed 2026-07-29 by
                  # sourcing the count from restore-size below.
                  if RAW_STATS=$(${pkgs.restic}/bin/restic --no-lock -r "$REPO_URL" stats --mode raw-data --json 2>/dev/null); then
                    REPO_SIZE=$(echo "$RAW_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
                  fi

                  # Get restore size stats (size if all files were restored).
                  # restore-size is the mode that reports total_file_count as a FILE count
                  # (files summed across all snapshots), which is what
                  # restic_repo_files_total is documented to mean. The unique-by-content
                  # count is tracked separately as restic_unique_files_total below, so the
                  # two are complementary rather than redundant.
                  if RESTORE_STATS=$(${pkgs.restic}/bin/restic --no-lock -r "$REPO_URL" stats --mode restore-size --json 2>/dev/null); then
                    RESTORE_SIZE=$(echo "$RESTORE_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
                    REPO_FILES=$(echo "$RESTORE_STATS" | ${pkgs.jq}/bin/jq -r '.total_file_count // 0')
                  fi

                  # Get unique files stats (deduplication info)
                  if UNIQUE_STATS=$(${pkgs.restic}/bin/restic --no-lock -r "$REPO_URL" stats --mode files-by-contents --json 2>/dev/null); then
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
  # Started only by restic-metrics.timer (its wantedBy was dropped 2025-11-05);
  # the timer below is what carries the tank.mount wantedBy
  # ConditionPathIsMountPoint prevents "failed" status during rebuild when mount unavailable
  systemd.services.restic-metrics = {
    description = "Collect Restic Repository Metrics";
    wants = [
      "network-online.target"
      "zfs.target"
      "zfs-import-tank.service"
    ];
    after = [
      "network-online.target"
      "zfs.target"
      "zfs-import-tank.service"
    ];
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
    wantedBy = [
      "timers.target"
      "tank.mount"
    ];
    timerConfig = {
      # Was OnBootSec=5min. Running this ~9.5min sweep over the USB tank during the
      # boot window held is-system-running in "starting" for ~15min (boot reached
      # multi-user.target at ~3min — system was usable then) and caused boot-window
      # I/O contention. Defer the post-boot run well past boot-settle; the periodic
      # 6h cadence is unchanged. RCA: docs/BOOT_SLOWNESS_RCA_2026-06-24.md.
      OnBootSec = "30min"; # First post-boot run, safely after boot has settled
      OnUnitActiveSec = "6h"; # Run every 6 hours
      RandomizedDelaySec = "10min"; # Spread load, avoid herding with other timers
      Persistent = true; # Run missed timers on boot
    };
  };
}
