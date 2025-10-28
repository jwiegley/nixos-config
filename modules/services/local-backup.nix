{ config, lib, pkgs, ... }:

let
  # Backup directories configuration
  backupSources = [
    { name = "etc"; source = "/etc"; }
    { name = "home"; source = "/home"; }
    { name = "var-lib"; source = "/var/lib"; }
  ];

  backupBaseDir = "/tank/Backups/Machines/Vulcan";
  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";
  metricsFile = "${metricsDir}/local-backup.prom";

  # Main backup script
  localBackupScript = pkgs.writeShellScript "local-backup" ''
    set -euo pipefail

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    # Function to write Prometheus metrics
    write_metrics() {
      local tmp_file="${metricsFile}.$$"

      {
        echo "# HELP local_backup_last_success_timestamp Unix timestamp of last successful local backup"
        echo "# TYPE local_backup_last_success_timestamp gauge"

        ${lib.concatMapStringsSep "\n" (backup: ''
          if [ -f "${backupBaseDir}/.${backup.name}.latest" ]; then
            timestamp=$(${pkgs.coreutils}/bin/stat -c %Y "${backupBaseDir}/.${backup.name}.latest")
            echo "local_backup_last_success_timestamp{backup=\"${backup.name}\",host=\"vulcan\",source=\"${backup.source}\",destination=\"${backupBaseDir}/${backup.name}\"} $timestamp"
          fi
        '') backupSources}
      } > "$tmp_file"

      # Atomic move to final location
      ${pkgs.coreutils}/bin/mv "$tmp_file" "${metricsFile}"
      ${pkgs.coreutils}/bin/chmod 644 "${metricsFile}"
    }

    log "Starting local backup to ${backupBaseDir}"

    # Ensure base backup directory exists
    if [ ! -d "${backupBaseDir}" ]; then
      log "Creating backup directory: ${backupBaseDir}"
      ${pkgs.coreutils}/bin/mkdir -p "${backupBaseDir}"
      ${pkgs.coreutils}/bin/chmod 755 "${backupBaseDir}"
    fi

    # Track overall success
    overall_success=true

    ${lib.concatMapStringsSep "\n" (backup: ''
      # Backup ${backup.name}
      log "Backing up ${backup.source} -> ${backupBaseDir}/${backup.name}"

      # Create destination directory if it doesn't exist
      if [ ! -d "${backupBaseDir}/${backup.name}" ]; then
        log "Creating destination directory: ${backupBaseDir}/${backup.name}"
        ${pkgs.coreutils}/bin/mkdir -p "${backupBaseDir}/${backup.name}"
      fi

      # Run rsync
      if ${pkgs.rsync}/bin/rsync -ax --delete "${backup.source}/" "${backupBaseDir}/${backup.name}/"; then
        log "Successfully backed up ${backup.name}"

        # Touch timestamp file to indicate successful backup
        ${pkgs.coreutils}/bin/touch "${backupBaseDir}/.${backup.name}.latest"

        # Log backup size
        size=$(${pkgs.coreutils}/bin/du -sh "${backupBaseDir}/${backup.name}" | ${pkgs.coreutils}/bin/cut -f1)
        log "Backup size for ${backup.name}: $size"
      else
        log "ERROR: Failed to backup ${backup.name}"
        overall_success=false
      fi
    '') backupSources}

    # Write Prometheus metrics
    log "Writing Prometheus metrics to ${metricsFile}"
    write_metrics

    if [ "$overall_success" = true ]; then
      log "Local backup completed successfully"
      exit 0
    else
      log "Local backup completed with errors"
      exit 1
    fi
  '';
in
{
  systemd = {
    # Local backup service
    services.local-backup = {
      description = "Local backup of system directories to /tank";
      after = [ "local-fs.target" ];

      # Only run if /tank is mounted
      unitConfig = {
        ConditionPathIsMountPoint = "/tank";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = localBackupScript;

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Timeout and logging
        TimeoutStartSec = "1h";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Timer for hourly execution
    timers.local-backup = {
      description = "Timer for hourly local backups";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run every hour
        OnCalendar = "hourly";

        # Run on boot if missed (e.g., system was off)
        Persistent = true;

        # Add some randomization to prevent all backups running at exactly the same time
        RandomizedDelaySec = "5m";

        # Unit to trigger
        Unit = "local-backup.service";
      };
    };
  };

  # Ensure metrics directory exists with proper permissions
  systemd.tmpfiles.rules = [
    "d ${metricsDir} 1777 prometheus prometheus -"
  ];

  # Documentation
  environment.etc."local-backup/README.md" = {
    text = ''
      # Local Backup System

      ## Overview
      Hourly backups of critical system directories to /tank/Backups/Machines/Vulcan using rsync.

      ## Backed Up Directories
      ${lib.concatMapStringsSep "\n" (backup:
        "- ${backup.source} -> ${backupBaseDir}/${backup.name}"
      ) backupSources}

      ## Timestamp Files
      After each successful backup, a timestamp file is created:
      ${lib.concatMapStringsSep "\n" (backup:
        "- ${backupBaseDir}/.${backup.name}.latest"
      ) backupSources}

      ## Monitoring

      ### Prometheus Metrics
      Metrics are exported via node_exporter textfile collector:
      - Metric: local_backup_last_success_timestamp{backup="<name>"}
      - Location: ${metricsFile}
      - Alert: Fires if backup is older than 4 hours

      ### Nagios Checks
      Nagios monitors timestamp file ages and alerts if older than 4 hours.

      ## Manual Operations

      ### Trigger Backup Manually
      ```bash
      sudo systemctl start local-backup.service
      ```

      ### Check Service Status
      ```bash
      sudo systemctl status local-backup.service
      sudo systemctl status local-backup.timer
      ```

      ### View Logs
      ```bash
      sudo journalctl -u local-backup -f
      sudo journalctl -u local-backup --since "1 day ago"
      ```

      ### Check Last Backup Times
      ```bash
      ls -lh ${backupBaseDir}/.*.latest
      stat ${backupBaseDir}/.etc.latest
      ```

      ### Verify Backup Contents
      ```bash
      ls -lh ${backupBaseDir}/etc/
      du -sh ${backupBaseDir}/*
      ```

      ## Schedule
      - Runs every hour on the hour
      - Persistent: Runs missed backups after system boot
      - Randomized delay: Up to 5 minutes to prevent resource contention

      ## Safety Features
      - Only runs if /tank is mounted (ConditionPathIsMountPoint)
      - Uses rsync --delete for exact mirror copies
      - Atomic metric updates (write to temp file, then move)
      - Comprehensive logging with timestamps
      - Error handling and exit codes
    '';
    mode = "0644";
  };
}
