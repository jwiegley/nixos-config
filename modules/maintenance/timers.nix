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

    export PATH=${pkgs.iptables}/bin:$PATH

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    log "Starting container update process"

    # Get unique images from all containers
    images=$(${pkgs.podman}/bin/podman ps -a --format='{{.Image}}' | sort -u)

    if [ -z "$images" ]; then
      log "No containers found"
      exit 0
    fi

    # Track which images were updated
    updated_images=""

    # Pull each image and track updates
    while IFS= read -r image; do
      [ -z "$image" ] && continue

      log "Checking image: $image"

      # Capture the pull output to detect if image was updated
      if output=$(${pkgs.podman}/bin/podman pull "$image" 2>&1); then
        if echo "$output" | grep -q "Downloading\|Copying\|Getting image"; then
          log "Updated: $image"
          updated_images="$updated_images $image"
        else
          log "Already up-to-date: $image"
        fi
      else
        log "ERROR: Failed to pull $image"
        # Continue with other images even if one fails
      fi
    done <<< "$images"

    # Only restart containers with updated images
    if [ -n "$updated_images" ]; then
      log "Restarting containers with updated images..."

      for image in $updated_images; do
        # Find containers using this image
        containers=$(${pkgs.podman}/bin/podman ps -a --filter "ancestor=$image" --format='{{.ID}}')

        if [ -n "$containers" ]; then
          while IFS= read -r container; do
            [ -z "$container" ] && continue

            # Get container name for logging
            name=$(${pkgs.podman}/bin/podman ps -a --filter "id=$container" --format='{{.Names}}')

            if ${pkgs.podman}/bin/podman restart "$container" >/dev/null 2>&1; then
              log "Restarted container: $name ($container)"
            else
              log "ERROR: Failed to restart container: $name ($container)"
            fi
          done <<< "$containers"
        fi
      done
    else
      log "No updates found, skipping container restarts"
    fi

    log "Container update process completed"
  '';

  # Script to update git workspace repositories
  workspaceUpdateScript = pkgs.writeShellScript "workspace-update" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

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
        export GITHUB_TOKEN=$(${pkgs.coreutils}/bin/cat "${config.sops.secrets."github-token".path}")
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

    # Run update and fetch with single thread to avoid concurrency issues
    # These commands will still report "failures" for repos with multiple remotes
    # where git's atomic ref updates encounter race conditions, but the repos
    # are actually updated successfully - these are false-positive errors
    ${pkgs.git}/bin/git workspace --workspace /var/lib/git-workspace-archive update -t 1
    ${pkgs.git}/bin/git workspace --workspace /var/lib/git-workspace-archive fetch -t 1

    if [[ "''${1:-}" == "--archive" ]]; then
        shift 1
        ${pkgs.git}/bin/git workspace --workspace /var/lib/git-workspace-archive archive --force
    fi
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
        gitAndTools.git-workspace
        openssh
      ];
      after = [ "sops-nix.service" ];
      wants = [ "sops-nix.service" ];
      serviceConfig = {
        User = "johnw";
        Group = "johnw";
        ExecStart = "${workspaceUpdateScript} --archive";
        # Load GitHub token as a systemd credential
        LoadCredential = "github-token:${config.sops.secrets."github-token".path}";
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
      description = "Update and restart Podman containers";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = updateContainersScript;
        User = "root";
        RemainAfterExit = false;
        TimeoutStartSec = "10m";
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
