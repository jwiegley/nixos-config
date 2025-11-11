{ config, lib, pkgs, ... }:

let
  # Git workspace metrics collection script
  gitWorkspaceMetricsScript = pkgs.writeShellScript "collect-git-workspace-metrics" ''
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
      while IFS= read -r -d $'\0' fetch_head; do
        REPO_COUNT=$((REPO_COUNT + 1))

        # Extract repo path relative to workspace
        REPO_PATH=$(${pkgs.coreutils}/bin/dirname "$fetch_head")
        REPO_NAME=$(echo "$REPO_PATH" | ${pkgs.gnused}/bin/sed "s|$WORKSPACE_DIR/||" | ${pkgs.gnused}/bin/sed 's|/.git$||')

        # Get FETCH_HEAD modification time
        FETCH_TIME=$(${pkgs.coreutils}/bin/stat -c %Y "$fetch_head" 2>/dev/null || echo "0")
        AGE_SECONDS=$((CURRENT_TIME - FETCH_TIME))

        # Track stale repos
        if [[ $AGE_SECONDS -gt $STALE_THRESHOLD && $FETCH_TIME -gt 0 ]]; then
          STALE_COUNT=$((STALE_COUNT + 1))
        fi

        # Only export per-repo metrics for a sample (top 50 by staleness)
        # Full scan would be too many metrics for Prometheus
        # We'll export the 50 stalest repos
        echo "$AGE_SECONDS $FETCH_TIME $REPO_NAME" >> "$TEMP_FILE.repos"

      done < <(${pkgs.findutils}/bin/find "$WORKSPACE_DIR/github" -name "FETCH_HEAD" -path "*/.git/FETCH_HEAD" -print0 2>/dev/null)

      # Sort by age (descending) and take top 50 stalest repos
      if [[ -f "$TEMP_FILE.repos" ]]; then
        ${pkgs.coreutils}/bin/sort -rn "$TEMP_FILE.repos" | ${pkgs.coreutils}/bin/head -50 | while read age fetch_time repo_name; do
          # Escape repo name for Prometheus label (replace special chars with _)
          SAFE_REPO_NAME=$(echo "$repo_name" | ${pkgs.gnused}/bin/sed 's/[^a-zA-Z0-9_\/]/_/g')
          cat >> "$TEMP_FILE" <<EOF
git_workspace_repo_last_fetch_timestamp_seconds{repository="$SAFE_REPO_NAME"} $fetch_time
git_workspace_repo_age_seconds{repository="$SAFE_REPO_NAME"} $age
EOF
        done
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
  # Create systemd service to collect git workspace metrics
  systemd.services.git-workspace-metrics = {
    description = "Collect Git Workspace Archive metrics for Prometheus";
    path = with pkgs; [
      bash
      coreutils
      jq
      gnused
      findutils
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${gitWorkspaceMetricsScript}";
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

  # Timer to collect metrics every 5 minutes
  systemd.timers.git-workspace-metrics = {
    description = "Timer for Git Workspace metrics collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Unit = "git-workspace-metrics.service";
    };
  };

  # Note: The textfile directory is already created by system-exporters.nix
  # with proper permissions (1777), so no tmpfiles rules needed here
}
