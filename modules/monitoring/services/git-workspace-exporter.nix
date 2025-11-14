{ config, lib, pkgs, ... }:

let
  # Fast metrics collector - reads from state file only (no filesystem scan)
  gitWorkspaceMetricsFast = pkgs.writeShellScript "collect-git-workspace-metrics-fast" ''
    #!/usr/bin/env bash
    set -euo pipefail

    WORKSPACE_DIR="/var/lib/git-workspace-archive"
    STATE_FILE="$WORKSPACE_DIR/.sync-state.json"
    OUTPUT_FILE="/var/lib/prometheus-node-exporter-textfiles/git_workspace.prom"
    TEMP_FILE="$OUTPUT_FILE.$$"

    # Prometheus metric definitions
    cat > "$TEMP_FILE" <<'HEADER'
# HELP git_workspace_last_sync_timestamp_seconds Unix timestamp of the last completed sync
# TYPE git_workspace_last_sync_timestamp_seconds gauge
# HELP git_workspace_sync_duration_seconds Duration of the last sync in seconds
# TYPE git_workspace_sync_duration_seconds gauge
# HELP git_workspace_repos_total Total number of repositories configured
# TYPE git_workspace_repos_total gauge
# HELP git_workspace_repos_successful Number of repositories successfully synced
# TYPE git_workspace_repos_successful gauge
# HELP git_workspace_repos_failed Number of repositories that failed to sync
# TYPE git_workspace_repos_failed gauge
# HELP git_workspace_stale_repos_total Number of repositories not updated in >3 days
# TYPE git_workspace_stale_repos_total gauge
# HELP git_workspace_repo_last_fetch_timestamp_seconds Unix timestamp of last fetch for each repository
# TYPE git_workspace_repo_last_fetch_timestamp_seconds gauge
# HELP git_workspace_repo_age_seconds Age of repository since last fetch in seconds
# TYPE git_workspace_repo_age_seconds gauge
# HELP git_workspace_scrape_success Whether the metric collection succeeded (1=success, 0=failure)
# TYPE git_workspace_scrape_success gauge
# HELP git_workspace_scrape_timestamp_seconds Unix timestamp of this metric collection
# TYPE git_workspace_scrape_timestamp_seconds gauge
# HELP git_workspace_scrape_duration_seconds Time taken to collect all metrics
# TYPE git_workspace_scrape_duration_seconds gauge
HEADER

    SCRAPE_START=$(${pkgs.coreutils}/bin/date +%s)
    SCRAPE_SUCCESS=0

    # Check if state file exists and parse it
    if [[ -f "$STATE_FILE" ]]; then
      # Validate JSON
      if ${pkgs.jq}/bin/jq . "$STATE_FILE" >/dev/null 2>&1; then
        # Extract metrics from state file
        LAST_RUN_END=$(${pkgs.jq}/bin/jq -r '.last_run_end' "$STATE_FILE")
        DURATION=$(${pkgs.jq}/bin/jq -r '.duration_seconds' "$STATE_FILE")
        TOTAL_REPOS=$(${pkgs.jq}/bin/jq -r '.total_repos' "$STATE_FILE")
        SUCCESSFUL=$(${pkgs.jq}/bin/jq -r '.successful' "$STATE_FILE")
        FAILED=$(${pkgs.jq}/bin/jq -r '.failed' "$STATE_FILE")
        STALE_COUNT=$(${pkgs.jq}/bin/jq -r '.stale_repos_count // 0' "$STATE_FILE")

        # Convert ISO timestamp to Unix epoch
        LAST_SYNC_TIMESTAMP=$(${pkgs.coreutils}/bin/date -d "$LAST_RUN_END" +%s 2>/dev/null || echo "0")

        # Write state file metrics
        cat >> "$TEMP_FILE" <<EOF
git_workspace_last_sync_timestamp_seconds $LAST_SYNC_TIMESTAMP
git_workspace_sync_duration_seconds $DURATION
git_workspace_repos_total $TOTAL_REPOS
git_workspace_repos_successful $SUCCESSFUL
git_workspace_repos_failed $FAILED
git_workspace_stale_repos_total $STALE_COUNT
EOF

        # Export per-repo metrics from state file (top 50 stalest)
        ${pkgs.jq}/bin/jq -r '.stale_repos_detail[]? | "git_workspace_repo_last_fetch_timestamp_seconds{repository=\"\(.repo)\"} \(.last_fetch)\ngit_workspace_repo_age_seconds{repository=\"\(.repo)\"} \(.age)"' "$STATE_FILE" >> "$TEMP_FILE" || true

        SCRAPE_SUCCESS=1
      else
        echo "ERROR: Invalid JSON in state file" >&2
        SCRAPE_SUCCESS=0
      fi
    else
      echo "WARNING: State file not found at $STATE_FILE" >&2
      # Write zeros for missing state file
      cat >> "$TEMP_FILE" <<EOF
git_workspace_last_sync_timestamp_seconds 0
git_workspace_sync_duration_seconds 0
git_workspace_repos_total 0
git_workspace_repos_successful 0
git_workspace_repos_failed 0
git_workspace_stale_repos_total 0
EOF
    fi

    # Calculate scrape duration
    SCRAPE_END=$(${pkgs.coreutils}/bin/date +%s)
    SCRAPE_DURATION=$((SCRAPE_END - SCRAPE_START))

    # Write scrape metadata
    cat >> "$TEMP_FILE" <<EOF
git_workspace_scrape_success $SCRAPE_SUCCESS
git_workspace_scrape_timestamp_seconds $SCRAPE_END
git_workspace_scrape_duration_seconds $SCRAPE_DURATION
EOF

    # Atomically replace the output file
    ${pkgs.coreutils}/bin/mv "$TEMP_FILE" "$OUTPUT_FILE"
    ${pkgs.coreutils}/bin/chmod 644 "$OUTPUT_FILE"

    echo "Git workspace metrics collected successfully (fast mode: state file only)"
  '';

  # Slow metrics collector - full filesystem scan for detailed repo metrics
  gitWorkspaceMetricsSlow = pkgs.writeShellScript "collect-git-workspace-metrics-slow" ''
    #!/usr/bin/env bash
    set -euo pipefail

    WORKSPACE_DIR="/var/lib/git-workspace-archive"
    STATE_FILE="$WORKSPACE_DIR/.sync-state.json"
    OUTPUT_FILE="/var/lib/prometheus-node-exporter-textfiles/git_workspace.prom"
    TEMP_FILE="$OUTPUT_FILE.$$"

    # Prometheus metric definitions
    cat > "$TEMP_FILE" <<'HEADER'
# HELP git_workspace_last_sync_timestamp_seconds Unix timestamp of the last completed sync
# TYPE git_workspace_last_sync_timestamp_seconds gauge
# HELP git_workspace_sync_duration_seconds Duration of the last sync in seconds
# TYPE git_workspace_sync_duration_seconds gauge
# HELP git_workspace_repos_total Total number of repositories configured
# TYPE git_workspace_repos_total gauge
# HELP git_workspace_repos_successful Number of repositories successfully synced
# TYPE git_workspace_repos_successful gauge
# HELP git_workspace_repos_failed Number of repositories that failed to sync
# TYPE git_workspace_repos_failed gauge
# HELP git_workspace_repo_last_fetch_timestamp_seconds Unix timestamp of last fetch for each repository
# TYPE git_workspace_repo_last_fetch_timestamp_seconds gauge
# HELP git_workspace_repo_age_seconds Age of repository since last fetch in seconds
# TYPE git_workspace_repo_age_seconds gauge
# HELP git_workspace_stale_repos_total Number of repositories not updated in >3 days
# TYPE git_workspace_stale_repos_total gauge
# HELP git_workspace_scrape_success Whether the metric collection succeeded (1=success, 0=failure)
# TYPE git_workspace_scrape_success gauge
# HELP git_workspace_scrape_timestamp_seconds Unix timestamp of this metric collection
# TYPE git_workspace_scrape_timestamp_seconds gauge
# HELP git_workspace_scrape_duration_seconds Time taken to collect all metrics
# TYPE git_workspace_scrape_duration_seconds gauge
HEADER

    SCRAPE_START=$(${pkgs.coreutils}/bin/date +%s)
    SCRAPE_SUCCESS=0
    CURRENT_TIME=$(${pkgs.coreutils}/bin/date +%s)
    STALE_THRESHOLD=$((3 * 86400))  # 3 days in seconds
    STALE_COUNT=0

    # Check if state file exists and parse it
    if [[ -f "$STATE_FILE" ]]; then
      # Validate JSON
      if ${pkgs.jq}/bin/jq . "$STATE_FILE" >/dev/null 2>&1; then
        # Extract metrics from state file
        LAST_RUN_END=$(${pkgs.jq}/bin/jq -r '.last_run_end' "$STATE_FILE")
        DURATION=$(${pkgs.jq}/bin/jq -r '.duration_seconds' "$STATE_FILE")
        TOTAL_REPOS=$(${pkgs.jq}/bin/jq -r '.total_repos' "$STATE_FILE")
        SUCCESSFUL=$(${pkgs.jq}/bin/jq -r '.successful' "$STATE_FILE")
        FAILED=$(${pkgs.jq}/bin/jq -r '.failed' "$STATE_FILE")

        # Convert ISO timestamp to Unix epoch
        LAST_SYNC_TIMESTAMP=$(${pkgs.coreutils}/bin/date -d "$LAST_RUN_END" +%s 2>/dev/null || echo "0")

        # Write state file metrics
        cat >> "$TEMP_FILE" <<EOF
git_workspace_last_sync_timestamp_seconds $LAST_SYNC_TIMESTAMP
git_workspace_sync_duration_seconds $DURATION
git_workspace_repos_total $TOTAL_REPOS
git_workspace_repos_successful $SUCCESSFUL
git_workspace_repos_failed $FAILED
EOF
        SCRAPE_SUCCESS=1
      else
        echo "ERROR: Invalid JSON in state file" >&2
        SCRAPE_SUCCESS=0
      fi
    else
      echo "WARNING: State file not found at $STATE_FILE" >&2
      # Write zeros for missing state file
      cat >> "$TEMP_FILE" <<EOF
git_workspace_last_sync_timestamp_seconds 0
git_workspace_sync_duration_seconds 0
git_workspace_repos_total 0
git_workspace_repos_successful 0
git_workspace_repos_failed 0
EOF
    fi

    # Scan all repositories for FETCH_HEAD timestamps
    # This gives us per-repo freshness metrics
    REPO_COUNT=0
    if [[ -d "$WORKSPACE_DIR/github" ]]; then
      # Use find -printf to get mtime without separate stat calls (much faster)
      while IFS= read -r -d $'\0' line; do
        REPO_COUNT=$((REPO_COUNT + 1))

        # Parse the find output: "mtime path"
        FETCH_TIME=''${line%% *}
        fetch_head=''${line#* }

        # Convert fractional timestamp to integer
        FETCH_TIME=''${FETCH_TIME%.*}

        # Extract repo path relative to workspace using bash built-ins
        # (avoids spawning 3 processes per repo: dirname + 2 sed)
        # fetch_head format: /path/to/workspace/github/owner/repo/.git/FETCH_HEAD
        git_dir="''${fetch_head%/FETCH_HEAD}"      # Remove /FETCH_HEAD suffix
        REPO_PATH="''${git_dir%/.git}"             # Remove /.git suffix
        REPO_NAME="''${REPO_PATH#$WORKSPACE_DIR/}" # Remove workspace prefix

        # Calculate age
        AGE_SECONDS=$((CURRENT_TIME - FETCH_TIME))

        # Track stale repos
        if [[ $AGE_SECONDS -gt $STALE_THRESHOLD && $FETCH_TIME -gt 0 ]]; then
          STALE_COUNT=$((STALE_COUNT + 1))
        fi

        # Only export per-repo metrics for a sample (top 50 by staleness)
        # Full scan would be too many metrics for Prometheus
        # We'll export the 50 stalest repos
        echo "$AGE_SECONDS $FETCH_TIME $REPO_NAME" >> "$TEMP_FILE.repos"

      done < <(${pkgs.findutils}/bin/find "$WORKSPACE_DIR/github" -name "FETCH_HEAD" -path "*/.git/FETCH_HEAD" -printf '%T@ %p\0' 2>/dev/null)

      # Sort by age (descending) and take top 50 stalest repos
      # Disable pipefail temporarily to prevent SIGPIPE when head closes the pipe
      if [[ -f "$TEMP_FILE.repos" ]]; then
        set +o pipefail
        ${pkgs.coreutils}/bin/sort -rn "$TEMP_FILE.repos" | ${pkgs.coreutils}/bin/head -50 | while read age fetch_time repo_name; do
          # Escape repo name for Prometheus label (replace special chars with _)
          SAFE_REPO_NAME=$(echo "$repo_name" | ${pkgs.gnused}/bin/sed 's/[^a-zA-Z0-9_\/]/_/g')
          cat >> "$TEMP_FILE" <<EOF
git_workspace_repo_last_fetch_timestamp_seconds{repository="$SAFE_REPO_NAME"} $fetch_time
git_workspace_repo_age_seconds{repository="$SAFE_REPO_NAME"} $age
EOF
        done
        set -o pipefail
        ${pkgs.coreutils}/bin/rm -f "$TEMP_FILE.repos"
      fi
    fi

    # Write stale repo count
    echo "git_workspace_stale_repos_total $STALE_COUNT" >> "$TEMP_FILE"

    # Calculate scrape duration
    SCRAPE_END=$(${pkgs.coreutils}/bin/date +%s)
    SCRAPE_DURATION=$((SCRAPE_END - SCRAPE_START))

    # Write scrape metadata
    cat >> "$TEMP_FILE" <<EOF
git_workspace_scrape_success $SCRAPE_SUCCESS
git_workspace_scrape_timestamp_seconds $SCRAPE_END
git_workspace_scrape_duration_seconds $SCRAPE_DURATION
EOF

    # Atomically replace the output file
    ${pkgs.coreutils}/bin/mv "$TEMP_FILE" "$OUTPUT_FILE"
    ${pkgs.coreutils}/bin/chmod 644 "$OUTPUT_FILE"

    echo "Git workspace metrics collected successfully (''${REPO_COUNT} repos scanned, ''${STALE_COUNT} stale)"
  '';

in
{
  # Fast metrics collector service - reads state file only (runs every 15 minutes)
  systemd.services.git-workspace-metrics-fast = {
    description = "Collect Git Workspace metrics (fast - state file only)";
    path = with pkgs; [
      bash
      coreutils
      jq
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${gitWorkspaceMetricsFast}";
      User = "prometheus";
      Group = "prometheus";
      # Allow reading git workspace directory owned by johnw
      SupplementaryGroups = [ "johnw" ];
    };

    # Only run if the workspace directory exists
    unitConfig = {
      ConditionPathExists = "/var/lib/git-workspace-archive";
    };
  };

  # Slow metrics collector service - full filesystem scan (runs twice daily)
  systemd.services.git-workspace-metrics-slow = {
    description = "Collect Git Workspace metrics (slow - full scan)";
    path = with pkgs; [
      bash
      coreutils
      jq
      gnused
      findutils
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${gitWorkspaceMetricsSlow}";
      User = "prometheus";
      Group = "prometheus";
      # Allow reading git workspace directory owned by johnw
      SupplementaryGroups = [ "johnw" ];
    };

    # Only run if the workspace directory exists
    unitConfig = {
      ConditionPathExists = "/var/lib/git-workspace-archive";
    };
  };

  # Fast timer - every 15 minutes
  systemd.timers.git-workspace-metrics-fast = {
    description = "Timer for fast Git Workspace metrics collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Unit = "git-workspace-metrics-fast.service";
    };
  };

  # Slow timer - twice daily (after sync and midday check)
  # Runs at 00:45 (after daily git-workspace-archive sync at 00:00)
  # and at 12:00 (midday verification check)
  systemd.timers.git-workspace-metrics-slow = {
    description = "Timer for slow Git Workspace metrics collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = [ "00:45" "12:00" ];
      Persistent = true;
      Unit = "git-workspace-metrics-slow.service";
    };
  };

  # Note: The textfile directory is already created by system-exporters.nix
  # with proper permissions (1777), so no tmpfiles rules needed here
}
