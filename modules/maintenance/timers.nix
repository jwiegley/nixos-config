{
  config,
  lib,
  pkgs,
  ...
}:

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;

  updateContainersScript = pkgs.writeShellScript "update-containers" ''
    set -euo pipefail

    export PATH=${
      lib.makeBinPath (
        with pkgs;
        [
          coreutils
          podman
          systemd
          iptables
          gnugrep
          util-linux
        ]
      )
    }

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    # Update containers for a given podman invocation and restart method
    # Args: $1 = label (e.g. "root" or username), $2+ = podman command prefix
    update_images_for() {
      local label="$1"
      shift
      local podman_cmd=("$@")

      log "[$label] Discovering containers..."

      local images
      images=$("''${podman_cmd[@]}" ps -a --format='{{.Image}}' 2>/dev/null | sort -u) || true

      if [ -z "$images" ]; then
        log "[$label] No containers found"
        return
      fi

      local updated_images=""

      while IFS= read -r image; do
        [ -z "$image" ] && continue

        # Skip locally-built images (cannot be pulled from a registry)
        if [[ "$image" == localhost/* ]]; then
          log "[$label] Skipping local image: $image"
          continue
        fi

        log "[$label] Checking image: $image"

        if output=$("''${podman_cmd[@]}" pull "$image" 2>&1); then
          if echo "$output" | grep -q "Downloading\|Copying\|Getting image"; then
            log "[$label] Updated: $image"
            updated_images="$updated_images $image"
          else
            log "[$label] Already up-to-date: $image"
          fi
        else
          log "[$label] ERROR: Failed to pull $image"
        fi
      done <<< "$images"

      if [ -z "$updated_images" ]; then
        log "[$label] No updates found"
        return
      fi

      log "[$label] Restarting containers with updated images..."

      for image in $updated_images; do
        local containers
        containers=$("''${podman_cmd[@]}" ps -a --filter "ancestor=$image" --format='{{.ID}}') || true

        [ -z "$containers" ] && continue

        while IFS= read -r container; do
          [ -z "$container" ] && continue

          local name
          name=$("''${podman_cmd[@]}" ps -a --filter "id=$container" --format='{{.Names}}')

          local systemd_unit
          systemd_unit=$("''${podman_cmd[@]}" inspect "$container" --format='{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' 2>/dev/null || echo "")

          if [ -n "$systemd_unit" ] && [ "$systemd_unit" != "<no value>" ]; then
            if [ "$label" = "root" ]; then
              log "[$label] Restarting system service: $systemd_unit (container: $name)"
              systemctl restart "$systemd_unit" 2>&1 || log "[$label] ERROR: Failed to restart $systemd_unit"
            else
              log "[$label] Restarting user service: $systemd_unit (container: $name)"
              systemctl --user --machine="$label@" restart "$systemd_unit" 2>&1 || log "[$label] ERROR: Failed to restart $systemd_unit"
            fi
          else
            log "[$label] Restarting container directly: $name ($container)"
            "''${podman_cmd[@]}" restart "$container" >/dev/null 2>&1 || log "[$label] ERROR: Failed to restart $name"
          fi
        done <<< "$containers"
      done
    }

    log "Starting container update process"

    # --- Root containers ---
    update_images_for "root" podman

    # --- Rootless containers (dedicated users) ---
    # Each user has linger enabled so their XDG_RUNTIME_DIR exists at /run/user/<uid>
    CONTAINER_USERS=(
      changedetection
      litellm
      mailarchiver
      nocobase
      open-webui
      openproject
      openspeedtest
      opnsense-exporter
      shlink
      shlink-web-client
      sillytavern
      teable
      wallabag
    )

    for user in "''${CONTAINER_USERS[@]}"; do
      uid=$(id -u "$user" 2>/dev/null || echo "")
      if [ -z "$uid" ]; then
        log "[$user] User not found, skipping"
        continue
      fi

      export XDG_RUNTIME_DIR="/run/user/$uid"
      if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        log "[$user] Runtime dir missing (not lingering?), skipping"
        continue
      fi

      update_images_for "$user" runuser -u "$user" -- podman
    done

    log "Container update process completed"
  '';

  # Script to update git workspace repositories
  workspaceUpdateScript = pkgs.writeShellScript "workspace-update" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        WORKSPACE_DIR="/var/lib/git-workspace-archive"
        STATE_FILE="$WORKSPACE_DIR/.sync-state.json"
        STATE_FILE_TMP="$STATE_FILE.tmp"
        LOG_FILE="$WORKSPACE_DIR/sync.log"

        # Parse arguments
        if [[ "''${1:-}" == "--passwords" ]]; then
            source $2
            shift 2
        fi

        # Read GitHub token from SOPS secret
        # When run as a systemd service, the token is available via LoadCredential
        # When run manually, read from the SOPS secret path directly
        if [[ -n "''${CREDENTIALS_DIRECTORY:-}" ]]; then
            export GITHUB_TOKEN=$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/github-token")
        elif [[ -f "${config.sops.secrets."github-token".path}" ]]; then
            export GITHUB_TOKEN=$(${pkgs.coreutils}/bin/cat "${
              config.sops.secrets."github-token".path
            }")
        else
            echo "ERROR: GitHub token not found. Ensure SOPS secret 'github-token' is configured." >&2
            exit 1
        fi

        # Function to clean up stale git lock files (older than 1 hour)
        cleanup_stale_locks() {
            local workspace="/var/lib/git-workspace-archive"
            echo "Cleaning up stale git lock files..."
            ${pkgs.findutils}/bin/find "$workspace" -name "*.lock" -path "*/.git/*" -mmin +60 -delete 2>/dev/null || true
        }

        # Clean up any stale lock files from previous crashed runs
        cleanup_stale_locks

        # Track sync metrics
        START_TIME=$(${pkgs.coreutils}/bin/date +%s)
        START_ISO=$(${pkgs.coreutils}/bin/date -Iseconds)

        # Capture output to parse for failures
        OUTPUT_FILE=$(${pkgs.coreutils}/bin/mktemp)
        trap "${pkgs.coreutils}/bin/rm -f $OUTPUT_FILE" EXIT

        # Run update and fetch with single thread to avoid concurrency issues
        # These commands will still report "failures" for repos with multiple remotes
        # where git's atomic ref updates encounter race conditions, but the repos
        # are actually updated successfully - these are false-positive errors
        echo "Starting git workspace sync at $START_ISO" | ${pkgs.coreutils}/bin/tee -a "$LOG_FILE"

        ${pkgs.git}/bin/git workspace --workspace /var/lib/git-workspace-archive update -t 1 2>&1 | ${pkgs.coreutils}/bin/tee -a "$OUTPUT_FILE" "$LOG_FILE" || true
        ${pkgs.git}/bin/git workspace --workspace /var/lib/git-workspace-archive fetch -t 1 2>&1 | ${pkgs.coreutils}/bin/tee -a "$OUTPUT_FILE" "$LOG_FILE" || true

        if [[ "''${1:-}" == "--archive" ]]; then
            shift 1
            ${pkgs.git}/bin/git workspace --workspace /var/lib/git-workspace-archive archive --force 2>&1 | ${pkgs.coreutils}/bin/tee -a "$LOG_FILE" || true
        fi

        # Calculate metrics
        END_TIME=$(${pkgs.coreutils}/bin/date +%s)
        END_ISO=$(${pkgs.coreutils}/bin/date -Iseconds)
        DURATION=$((END_TIME - START_TIME))
        CURRENT_TIME=$END_TIME
        STALE_THRESHOLD=$((3 * 86400))  # 3 days in seconds
        STALE_COUNT=0
        STALE_REPOS_JSON=""

        # Collect staleness data while files are hot in cache
        echo "Collecting repository staleness metrics..." | ${pkgs.coreutils}/bin/tee -a "$LOG_FILE"
        if [[ -d "$WORKSPACE_DIR/github" ]]; then
          STALE_REPOS_FILE=$(${pkgs.coreutils}/bin/mktemp)
          trap "${pkgs.coreutils}/bin/rm -f $OUTPUT_FILE $STALE_REPOS_FILE" EXIT

          # Scan repositories for staleness (this is fast now since files are cached)
          while IFS= read -r -d $'\0' line; do
            FETCH_TIME=''${line%% *}
            fetch_head=''${line#* }
            FETCH_TIME=''${FETCH_TIME%.*}  # Convert fractional to integer

            # Extract repo path
            git_dir="''${fetch_head%/FETCH_HEAD}"
            REPO_PATH="''${git_dir%/.git}"
            REPO_NAME="''${REPO_PATH#$WORKSPACE_DIR/}"

            # Calculate age
            AGE_SECONDS=$((CURRENT_TIME - FETCH_TIME))

            # Track stale repos (>3 days)
            if [[ $AGE_SECONDS -gt $STALE_THRESHOLD && $FETCH_TIME -gt 0 ]]; then
              STALE_COUNT=$((STALE_COUNT + 1))
              # Store top 50 stalest repos for detailed metrics
              echo "$AGE_SECONDS $FETCH_TIME $REPO_NAME" >> "$STALE_REPOS_FILE"
            fi
          done < <(${pkgs.findutils}/bin/find "$WORKSPACE_DIR/github" -name "FETCH_HEAD" -path "*/.git/FETCH_HEAD" -printf '%T@ %p\0' 2>/dev/null)

          # Convert top 50 stalest repos to JSON array
          if [[ -f "$STALE_REPOS_FILE" && -s "$STALE_REPOS_FILE" ]]; then
            STALE_REPOS_JSON=$(${pkgs.coreutils}/bin/sort -rn "$STALE_REPOS_FILE" | ${pkgs.coreutils}/bin/head -50 | ${pkgs.gawk}/bin/awk '{printf "{\"repo\":\"%s\",\"age\":%s,\"last_fetch\":%s},", $3, $1, $2}' | ${pkgs.gnused}/bin/sed 's/,$//')
            STALE_REPOS_JSON="[$STALE_REPOS_JSON]"
          else
            STALE_REPOS_JSON="[]"
          fi
        fi

        echo "Found $STALE_COUNT stale repositories (>3 days old)" | ${pkgs.coreutils}/bin/tee -a "$LOG_FILE"

        # Parse output for failures
        # Use tail -1 to get only the last occurrence (from the final fetch command)
        # and handle case where grep doesn't match by defaulting to 0
        FAILED_COUNT=$(${pkgs.gnugrep}/bin/grep "repositories failed:" "$OUTPUT_FILE" | ${pkgs.coreutils}/bin/tail -1 | ${pkgs.gawk}/bin/awk '{print $1}' | ${pkgs.coreutils}/bin/tr -d '\n ' || echo "0")

        # Ensure FAILED_COUNT is a valid number (default to 0 if empty or invalid)
        if ! [[ "$FAILED_COUNT" =~ ^[0-9]+$ ]]; then
            FAILED_COUNT=0
        fi

        # Extract failed repo names and reasons
        FAILED_REPOS=$(${pkgs.gnugrep}/bin/grep -A 1000 "repositories failed:" "$OUTPUT_FILE" | ${pkgs.gnugrep}/bin/grep "^github/" | ${pkgs.coreutils}/bin/tr '\n' ',' | ${pkgs.gnused}/bin/sed 's/,$//' || echo "")

        # Count total repos from workspace-lock.toml
        TOTAL_REPOS=$(${pkgs.gnugrep}/bin/grep -c '^\[\[repo\]\]' "$WORKSPACE_DIR/workspace-lock.toml" 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '\n ' || echo "0")

        # Ensure TOTAL_REPOS is a valid number (default to 0 if empty or invalid)
        if ! [[ "$TOTAL_REPOS" =~ ^[0-9]+$ ]]; then
            TOTAL_REPOS=0
        fi

        SUCCESSFUL_REPOS=$((TOTAL_REPOS - FAILED_COUNT))

        # Write state file atomically
        ${pkgs.coreutils}/bin/cat > "$STATE_FILE_TMP" <<EOF
    {
      "last_run_start": "$START_ISO",
      "last_run_end": "$END_ISO",
      "duration_seconds": $DURATION,
      "total_repos": $TOTAL_REPOS,
      "successful": $SUCCESSFUL_REPOS,
      "failed": $FAILED_COUNT,
      "failed_repos": "$FAILED_REPOS",
      "workspace_dir": "$WORKSPACE_DIR",
      "stale_repos_count": $STALE_COUNT,
      "stale_repos_detail": $STALE_REPOS_JSON
    }
    EOF
        ${pkgs.coreutils}/bin/mv "$STATE_FILE_TMP" "$STATE_FILE"
        ${pkgs.coreutils}/bin/chmod 644 "$STATE_FILE"

        echo "Sync completed at $END_ISO. Duration: $DURATION seconds. Failed: $FAILED_COUNT/$TOTAL_REPOS" | ${pkgs.coreutils}/bin/tee -a "$LOG_FILE"
  '';
in
{
  # SOPS secret for GitHub token used by workspace update
  sops.secrets."github-token" = {
    owner = "johnw";
    group = "johnw";
    mode = "0400";
    restartUnits = [ "git-workspace-archive.service" ];
  };

  fileSystems = bindTankPath {
    path = "/var/lib/git-workspace-archive";
    device = "/tank/Backups/Git";
  };

  systemd = {
    # Git workspace archive
    services.git-workspace-archive = {
      description = "Archive Git repositories";
      path = with pkgs; [
        git
        git-workspace
        openssh
        gawk
        gnused
        findutils
      ];
      after = [
        "sops-nix.service"
        "var-lib-git\\x2dworkspace\\x2darchive.mount"
      ];
      wants = [ "sops-nix.service" ];
      requires = [ "var-lib-git\\x2dworkspace\\x2darchive.mount" ];
      serviceConfig = {
        Type = "oneshot";
        User = "johnw";
        Group = "johnw";
        ExecStart = "${workspaceUpdateScript} --archive";
        # Load GitHub token as a systemd credential
        LoadCredential = "github-token:${config.sops.secrets."github-token".path}";
        # Ensure directory permissions allow monitoring users (prometheus, nagios) to read
        ExecStartPost = [
          "${pkgs.coreutils}/bin/chmod 750 /var/lib/git-workspace-archive"
          "${pkgs.coreutils}/bin/chmod -R g+rX /var/lib/git-workspace-archive/github"
        ];
        TimeoutStartSec = "1h";
        RemainAfterExit = false;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    timers.git-workspace-archive = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Unit = "git-workspace-archive.service";
      };
    };

    # Update containers
    services.update-containers = {
      description = "Update and restart Podman containers (root and rootless)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = updateContainersScript;
        User = "root";
        RemainAfterExit = false;
        TimeoutStartSec = "30m";
        KillMode = "process"; # Only kill main script, not restarted containers
        StandardOutput = "journal";
        StandardError = "journal";
      };
      after = [
        "network-online.target"
        "podman.service"
      ];
      wants = [ "network-online.target" ];
    };

    timers.update-containers = {
      description = "Timer for updating Podman containers";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "30m";
        Persistent = true;
      };
    };
  };
}
