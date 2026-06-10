{
  config,
  lib,
  pkgs,
  ...
}:

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;

  sourceDir = "/var/lib/technitium-dns-server";
  backupDir = "/var/lib/technitium-dns-backup";
  backupFile = "${backupDir}/technitium-dns-backup-$(date '+%Y-%m-%d').tar";

  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";
  metricsFile = "${metricsDir}/technitium_backup.prom";

  # Integrity / freshness emitter for the Technitium DNS backup artifact, mirroring
  # the postgresql-backup triad (a green Type=oneshot exit is NOT proof of a complete
  # backup — the UAS-backed /tank can drop mid-write). Records, every run:
  #   technitium_backup_last_success            1 iff $SERVICE_RESULT == "success"
  #   technitium_backup_last_run_timestamp_seconds  emission wall-clock (or newest mtime on seed)
  #   technitium_backup_size_bytes              byte size of the NEWEST .tar.xz artifact
  # Runs via ExecStopPost with a '+' prefix (root) so it fires on success AND failure.
  # $1 = run result ("success"/other from $SERVICE_RESULT, or explicit 1/0).
  # $2 = timestamp source: "now" (default) or "mtime" (activation seeding — anchor to
  #      the newest artifact so a mid-day rebuild does not mask a stale backup).
  technitiumBackupMetricsScript = pkgs.writeShellScript "technitium-backup-metrics" ''
    set -euo pipefail

    case "''${1:-0}" in
      success|1) success=1 ;;
      *)         success=0 ;;
    esac
    ts_mode="''${2:-now}"

    ${pkgs.coreutils}/bin/mkdir -p "${metricsDir}"

    size=0
    newest=$(${pkgs.coreutils}/bin/ls -1t ${backupDir}/technitium-dns-backup-*.tar.xz 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)
    if [ -n "''${newest:-}" ] && [ -f "$newest" ]; then
      size=$(${pkgs.coreutils}/bin/stat -c %s "$newest" 2>/dev/null || echo 0)
    fi

    if [ "$ts_mode" = mtime ] && [ -n "''${newest:-}" ] && [ -f "$newest" ]; then
      now=$(${pkgs.coreutils}/bin/stat -c %Y "$newest" 2>/dev/null || ${pkgs.coreutils}/bin/date +%s)
    else
      now=$(${pkgs.coreutils}/bin/date +%s)
    fi

    tmp="${metricsFile}.$$"

    {
      echo "# HELP technitium_backup_last_success Whether the most recent Technitium DNS backup run succeeded (1=success, 0=failure)"
      echo "# TYPE technitium_backup_last_success gauge"
      echo "technitium_backup_last_success $success"
      echo "# HELP technitium_backup_last_run_timestamp_seconds Unix timestamp of the most recent Technitium DNS backup run"
      echo "# TYPE technitium_backup_last_run_timestamp_seconds gauge"
      echo "technitium_backup_last_run_timestamp_seconds $now"
      echo "# HELP technitium_backup_size_bytes Byte size of the newest Technitium DNS backup artifact"
      echo "# TYPE technitium_backup_size_bytes gauge"
      echo "technitium_backup_size_bytes $size"
    } > "$tmp"

    ${pkgs.coreutils}/bin/mv "$tmp" "${metricsFile}"
    ${pkgs.coreutils}/bin/chmod 644 "${metricsFile}"
  '';

  technitiumDnsBackupScript = pkgs.writeShellScript "technitium-dns-backup" ''
    set -euo pipefail

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    log "Starting Technitium DNS Server backup"

    # Ensure backup directory exists with proper permissions
    if [ ! -d "${backupDir}" ]; then
      log "Creating backup directory: ${backupDir}"
      ${pkgs.coreutils}/bin/mkdir -p "${backupDir}"
      ${pkgs.coreutils}/bin/chmod 755 "${backupDir}"
    fi

    # Verify source directory exists
    if [ ! -d "${sourceDir}" ]; then
      log "ERROR: Source directory ${sourceDir} does not exist!"
      exit 1
    fi

    # Create temporary directory for selective backup
    TMPDIR=$(${pkgs.coreutils}/bin/mktemp -d)
    trap "${pkgs.coreutils}/bin/rm -rf $TMPDIR" EXIT

    log "Creating backup archive"

    # Retry loop to ensure clean backup without file changes
    # Tar exit codes: 0=success, 1=files changed, 2=fatal error
    max_retries=10
    retry_delay=5  # seconds
    attempt=1
    tar_exit=1

    while [ $attempt -le $max_retries ] && [ $tar_exit -eq 1 ]; do
      if [ $attempt -gt 1 ]; then
        log "Retry attempt $attempt/$max_retries after ''${retry_delay}s delay..."
        ${pkgs.coreutils}/bin/sleep $retry_delay
      else
        log "Starting backup attempt $attempt/$max_retries"
      fi

      # Remove partial backup if it exists from previous attempt
      if [ -f "${backupFile}" ]; then
        ${pkgs.coreutils}/bin/rm -f "${backupFile}"
      fi

      # Backup critical files and directories, exclude cache and logs
      set +e  # Temporarily disable exit on error to capture tar's exit code
      ${pkgs.gnutar}/bin/tar \
        --create \
        --file="${backupFile}" \
        --directory="${sourceDir}" \
        --exclude='cache.bin' \
        --exclude='logs' \
        --exclude='stats' \
        --warning=no-file-changed \
        --verbose \
        .
      tar_exit=$?
      set -e  # Re-enable exit on error

      # Check tar exit code
      if [ $tar_exit -eq 0 ]; then
        log "Backup completed successfully without file changes"
        break
      elif [ $tar_exit -eq 2 ]; then
        log "ERROR: tar command failed with fatal error"
        exit 2
      elif [ $tar_exit -eq 1 ]; then
        log "Files changed during backup attempt $attempt"
        attempt=$((attempt + 1))
      fi
    done

    # Final check: did we succeed or exhaust retries?
    if [ $tar_exit -ne 0 ]; then
      log "ERROR: Failed to create clean backup after $max_retries attempts"
      log "Files are changing too frequently - backup may be inconsistent"
      exit 1
    fi

    if [ -f "${backupFile}" ]; then
      log "Archive created successfully, compressing with xz"

      # Compress the backup
      ${pkgs.xz}/bin/xz --compress --force "${backupFile}"

      # Set permissions on backup file
      ${pkgs.coreutils}/bin/chmod 644 "${backupFile}.xz"

      # Log backup size
      size=$(${pkgs.coreutils}/bin/du -h "${backupFile}.xz" | ${pkgs.coreutils}/bin/cut -f1)
      log "Backup size: $size"
      log "Backup location: ${backupFile}.xz"
    else
      log "ERROR: Backup archive creation failed!"
      exit 1
    fi

    log "Technitium DNS Server backup completed successfully"
  '';
in
{
  systemd = {
    # Technitium DNS backup service
    services.technitium-dns-backup = {
      description = "Backup Technitium DNS Server configuration";
      after = [ "technitium-dns-server.service" ];
      wants = [ "technitium-dns-server.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = technitiumDnsBackupScript;

        # Emit integrity/freshness metrics on EVERY exit (success and failure).
        # Leading '+' runs as root regardless of User= so it can always write the
        # textfile atomically. $SERVICE_RESULT is "success" on a clean run.
        ExecStopPost = "+${technitiumBackupMetricsScript} $SERVICE_RESULT";

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [
          backupDir
          metricsDir
        ];
        ReadOnlyPaths = [ sourceDir ];

        # Timeout and logging
        TimeoutStartSec = "15m";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Seed technitium_backup.prom at activation so the freshness/integrity metrics
    # exist immediately (with the current newest-backup stats) rather than being
    # absent until the next 03:00 run. Marks success=1 because a present artifact
    # reflects the last good backup; anchors the timestamp to the artifact mtime.
    services.technitium-dns-backup-metrics-seed = {
      description = "Seed technitium_backup.prom textfile metrics at activation";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RemainAfterExit = false;
        ExecStart = "${technitiumBackupMetricsScript} 1 mtime";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Timer for daily execution at 3:00 AM (offset from PostgreSQL at 2:00 AM)
    timers.technitium-dns-backup = {
      description = "Timer for Technitium DNS Server backups";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run daily at 3:00 AM
        OnCalendar = "03:00";

        # Run on boot if missed (e.g., system was off)
        Persistent = true;

        # Randomize start time by up to 5 minutes to avoid system load spikes
        RandomizedDelaySec = "5m";

        # Unit to trigger
        Unit = "technitium-dns-backup.service";
      };
    };
  };

  # Ensure Technitium DNS Server is enabled (this module depends on it)
  assertions = [
    {
      assertion = config.services.technitium-dns-server.enable or false;
      message = "Technitium DNS backup requires services.technitium-dns-server.enable = true";
    }
  ];

  # Bind mount ZFS dataset to backup directory
  fileSystems = bindTankPath {
    path = backupDir;
    device = "/tank/Backups/TechnitiumDNS";
  };
}
