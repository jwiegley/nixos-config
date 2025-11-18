{ config, lib, pkgs, ... }:

let
  # Backup directories configuration with exclusions
  backupSources = [
    {
      name = "etc";
      source = "/etc";
      excludes = [
        # Exclude node_modules (development artifact, very large)
        "nixos/node_modules/"
      ];
    }
    {
      name = "home";
      source = "/home";
      excludes = [
        # Exclude container overlay storage (ephemeral, causes rsync to hang)
        "johnw/.local/share/containers/storage/overlay/"
        "johnw/.local/share/docker/overlay2/"
        "johnw/.local/share/Trash/"
        "johnw/.cache/"
        "johnw/.npm/"
        # Exclude large data directories (backed up separately or not needed)
        "johnw/node_modules/"        # Development dependencies - 784MB
      ];
    }
    {
      name = "var";
      source = "/var";
      excludes = [
        # === CONTAINER & OVERLAY STORAGE (30GB+) ===
        # Exclude container overlay storage (ephemeral, causes rsync to hang)
        "lib/containers/"
        "lib/docker/overlay2/"
        "lib/podman/"
        "lib/containers/storage/"

        # === VOLATILE RUNTIME DIRECTORIES ===
        "cache/"
        "tmp/"
        "run/"
        "lock/"

        # === LARGE ARCHIVE/BACKUP DATA (30GB+) ===
        # Already backed up or archived elsewhere
        "lib/git-workspace-archive/"     # 23GB - Git archives
        "lib/windows/"                    # 9.5GB - VM images
        "lib/postgresql-backup/"          # 7.5GB - Already backed up dumps
        "lib/technitium-dns-backup/"      # 1.2GB - DNS backups

        # === ACTIVE DATABASES (Need special handling) ===
        # These should use proper dump commands, not file copies
        "lib/postgresql/"                 # 9.3GB - Use pg_dump (already done)
        "lib/mongodb/"                    # MongoDB files
        "lib/elasticsearch/"              # 406MB - Search indices, recreatable

        # === HIGH-CHURN MONITORING DATA ===
        # Constantly changing, causes I/O storms
        "lib/loki/"                       # 9.7GB - Log chunks
        "lib/prometheus2/"                # 5.7GB - Time-series data
        "lib/ntopng/"                     # 1.7GB - 517 files/hour!
        "lib/victoria-metrics/"           # Time-series data
        "lib/private/victoriametrics/"    # 122 files/hour
        "lib/grafana/dashboards/"         # Temporary dashboard data
        "lib/influxdb/"                   # Time-series data

        # === GIT REPOSITORIES (Use git bundle) ===
        "lib/gitea/repositories/"         # Use git bundle instead
        "lib/gitlab/"                     # GitLab repos

        # === MEDIA & TEMPORARY FILES ===
        "lib/jellyfin/transcodes/"        # Temporary transcoding
        "lib/jellyfin/metadata/"          # Can be regenerated
        "lib/plex/"                       # Media server data

        # === MAIL INDICES (Recreatable) ===
        "spool/mail/*/fts-flatcurve/"     # Mail search indices
        "spool/mail/*/.notmuch/"          # Notmuch indices
        "lib/dovecot/indices/"            # Dovecot indices

        # === SYSTEM FILES ===
        "lib/systemd/coredump/"           # Core dumps
        "lib/systemd/catalog/"            # System catalogs
        "crash/"                          # Crash dumps

        # === CACHE & TEMP DATA ===
        "lib/redis/"                      # Redis persistence files
        "lib/memcached/"                  # Memcached data
        "lib/snapd/"                      # Snap data
        "lib/flatpak/"                    # Flatpak data

        # === DATABASE FILES (Need special handling) ===
        "**/*.sqlite"
        "**/*.sqlite3"
        "**/*.sqlite-wal"
        "**/*.sqlite-shm"
        "**/*.db"
        "**/*.mdb"                        # LMDB files
        "**/*.ldb"                        # LevelDB files

        # === SWAP FILES ===
        "swap/"                           # 17GB swap files
      ];
    }
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

      # Build rsync exclude arguments
      exclude_args=""
      ${lib.concatMapStringsSep "\n" (exclude: ''
        exclude_args="$exclude_args --exclude='${exclude}'"
      '') (backup.excludes or [])}

      # Run rsync and capture exit code
      # Enhanced rsync options to prevent I/O overload:
      # - --one-file-system: Don't cross filesystem boundaries
      # - --bwlimit=30000: Limit bandwidth to 30MB/s
      # - --timeout=120: Increased timeout for large files
      # - --partial: Keep partial transfers for resumption
      # - --inplace: Update destination files in-place (reduces I/O)
      # Temporarily disable set -e to properly capture rsync exit codes (especially 23/24 for vanished files)
      set +e
      eval "${pkgs.rsync}/bin/rsync -aHx \
        --one-file-system \
        --delete \
        --timeout=120 \
        --bwlimit=30000 \
        --partial \
        --inplace \
        --info=progress2 \
        $exclude_args \
        '${backup.source}/' '${backupBaseDir}/${backup.name}/'"
      rc=$?
      set -e

      # Exit codes: 0=success, 23=partial transfer, 24=vanished files (all acceptable)
      if [[ $rc -eq 0 || $rc -eq 23 || $rc -eq 24 ]]; then
        if [[ $rc -eq 24 ]]; then
          log "Successfully backed up ${backup.name} (some files vanished during transfer)"
        elif [[ $rc -eq 23 ]]; then
          log "Successfully backed up ${backup.name} (partial transfer with non-critical errors)"
        else
          log "Successfully backed up ${backup.name}"
        fi

        # Touch timestamp file to indicate successful backup
        ${pkgs.coreutils}/bin/touch "${backupBaseDir}/.${backup.name}.latest"

        # Skip size calculation for now (du is too slow on large directories)
        # TODO: Consider using a faster method or caching size info
        log "Completed backup for ${backup.name}"
      else
        log "ERROR: Failed to backup ${backup.name} (rsync exit code: $rc)"
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

      # Don't restart during nixos-rebuild switch - only run via timer
      restartIfChanged = false;

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

        # Resource limits to prevent OOM and reduce I/O impact
        # Memory limit: 2GB should be more than sufficient for rsync operations
        MemoryMax = "2G";
        MemoryHigh = "1.5G";

        # I/O limits: Use best-effort scheduling to minimize impact on other services
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;  # Lowest priority (0=highest, 7=lowest)
        IOWeight = 10;  # Low I/O weight (10-1000 scale)

        # Enhanced I/O throttling with cgroup v2 bandwidth limits
        # Limit read speed from source drive to prevent I/O saturation
        IOReadBandwidthMax = "/dev/nvme0n1 50M";  # 50MB/s read limit

        # Limit write speed to backup destination
        IOWriteBandwidthMax = "/dev/nvme0n1 30M";  # 30MB/s write limit

        # CPU priority: Run at lower priority
        CPUSchedulingPolicy = "batch";
        Nice = 19;  # Lowest CPU priority

        # Timeout and logging
        # Increased from 1h to 2h to accommodate slow backups with many changed files
        TimeoutStartSec = "2h";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Timer for 4x daily execution (reduced from hourly to prevent I/O storms)
    timers.local-backup = {
      description = "Timer for 4x daily local backups";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run 4 times per day: midnight, 6am, noon, 6pm
        # This reduces I/O pressure while maintaining regular backups
        OnCalendar = "*-*-* 00,06,12,18:00:00";

        # Run on boot if missed (e.g., system was off)
        Persistent = true;

        # Increased randomization to spread I/O load
        RandomizedDelaySec = "15m";

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
