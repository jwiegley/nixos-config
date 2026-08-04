{
  config,
  lib,
  pkgs,
  ...
}:

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
        "johnw/node_modules/" # Development dependencies - 784MB
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
        # Already backed up or archived elsewhere.
        # NOTE: all three of these are bind mounts of tank/Backups/* datasets
        # (findmnt-verified 2026-07-29), so --one-file-system already stops
        # rsync at them. The exclusions are belt-and-braces, not the mechanism.
        "lib/git-workspace-archive/" # 23GB - Git archives
        "lib/postgresql-backup/" # 7.5GB - Already backed up dumps
        "lib/technitium-dns-backup/" # 1.2GB - DNS backups

        # === STATE DIRS WITH A DEDICATED MIRROR (added 2026-07-29) ===
        # These were being copied down TWO paths and only one of them is a real
        # backup. Each has a dedicated nightly rsync mirror onto its own
        # tank/Backups/* dataset (ZFS sanoid snapshots = retention), and this
        # module was ALSO dragging the live state dir into
        # /tank/Backups/Machines/Vulcan/var 4x a day. Both copies land on the
        # same pool, in the same enclosure, under the same recursive `archival`
        # sanoid template (modules/storage/zfs.nix), so the second copy buys no
        # independent failure domain -- it only adds churn to a pool whose USB
        # bridge has already hung once under backup I/O (2026-06-02).
        #
        # Verified byte-for-byte before excluding, so nothing unrecoverable is
        # being dropped:
        #
        #   lib/node-red -> modules/services/node-red-backup.nix mirrors it to
        #   /var/lib/node-red-backup (= tank/Backups/NodeRED) minus
        #   node_modules/.npm/.cache/*.tmp; `npm install` regenerates those per
        #   that module's step-5 restore procedure. Top-level entry lists of the
        #   mirror and the live dir are identical. That mirror is additionally
        #   the ONE mirror that goes offsite: "NodeRED" is absent from
        #   backupExcludes in modules/storage/backups.nix, so restic pushes it to
        #   B2. The copy removed here was 217MB (59MB of it node_modules) and had
        #   no offsite path at all, since "Machines" IS in backupExcludes.
        #
        #   lib/private/technitium-dns-server -> modules/services/technitium-dns-backup.nix
        #   mirrors /var/lib/technitium-dns-server (a symlink into private/) to
        #   /var/lib/technitium-dns-backup (= tank/Backups/TechnitiumDNS),
        #   excluding only /cache.bin, /logs and /stats. Confirmed the mirror
        #   holds every config/zone/app/blocklist/scope entry the live dir has;
        #   the 324MB copied here was those same entries plus exactly those three
        #   rebuildable runtime items.
        #
        #   Unlike node-red above, there is nothing stranded to clean up for this one:
        #   /tank/Backups/Machines/Vulcan/var/lib/private/technitium-dns-server does NOT
        #   exist in the mirror (checked 2026-07-29), so this exclusion leaves no
        #   pre-existing destination tree behind. Do not infer from the node-red case
        #   that this one also needs a manual rm.
        #
        # NOT excluded, deliberately: lib/hass/backups (301MB of Home Assistant's
        # own backup tarballs). Those have NO dedicated mirror -- this rsync is
        # the only thing that gets them off the nvme onto tank, so excluding them
        # would be a real loss of coverage, not a de-duplication.
        "lib/node-red/" # 217MB - mirror: /tank/Backups/NodeRED (+ offsite B2)
        "lib/private/technitium-dns-server/" # 324MB - mirror: /tank/Backups/TechnitiumDNS

        # === ACTIVE DATABASES (Need special handling) ===
        # These should use proper dump commands, not file copies
        "lib/postgresql/" # 9.3GB - Use pg_dump (already done)
        "lib/mongodb/" # MongoDB files
        "lib/elasticsearch/" # 406MB - Search indices, recreatable

        # === HIGH-CHURN MONITORING DATA ===
        # Constantly changing, causes I/O storms
        "lib/loki/" # 9.7GB - Log chunks
        "lib/prometheus2/" # 5.7GB - Time-series data
        "lib/victoria-metrics/" # Time-series data
        "lib/private/victoriametrics/" # 122 files/hour
        "lib/grafana/dashboards/" # Temporary dashboard data
        "lib/influxdb/" # Time-series data

        # === GIT REPOSITORIES (Use git bundle) ===
        "lib/gitea/repositories/" # Use git bundle instead
        "lib/gitlab/" # GitLab repos

        # === MEDIA & TEMPORARY FILES ===
        "lib/jellyfin/transcodes/" # Temporary transcoding
        "lib/jellyfin/metadata/" # Can be regenerated
        "lib/plex/" # Media server data

        # === MAIL INDICES (Recreatable) ===
        "spool/mail/*/fts-flatcurve/" # Mail search indices
        "spool/mail/*/.notmuch/" # Notmuch indices
        "lib/dovecot/indices/" # Dovecot indices

        # === SYSTEM FILES ===
        "lib/systemd/coredump/" # Core dumps
        "lib/systemd/catalog/" # System catalogs
        "crash/" # Crash dumps

        # === CACHE & TEMP DATA ===
        "lib/redis/" # Redis persistence files
        "lib/memcached/" # Memcached data
        "lib/snapd/" # Snap data
        "lib/flatpak/" # Flatpak data

        # === DATABASE FILES (Need special handling) ===
        "**/*.sqlite"
        "**/*.sqlite3"
        "**/*.sqlite-wal"
        "**/*.sqlite-shm"
        "**/*.db"
        "**/*.mdb" # LMDB files
        "**/*.ldb" # LevelDB files

        # === SWAP FILES ===
        "swap/" # 17GB swap files
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

        echo "# HELP local_backup_last_clean_success_timestamp Unix timestamp of the last CLEAN mirror pass (rsync 0/24; 23 = partial does not count)"
        echo "# TYPE local_backup_last_clean_success_timestamp gauge"
        ${lib.concatMapStringsSep "\n" (backup: ''
          if [ -f "${backupBaseDir}/.${backup.name}.lastclean" ]; then
            clean_ts=$(${pkgs.coreutils}/bin/stat -c %Y "${backupBaseDir}/.${backup.name}.lastclean")
            echo "local_backup_last_clean_success_timestamp{backup=\"${backup.name}\",host=\"vulcan\"} $clean_ts"
          fi
        '') backupSources}

        echo "# HELP local_backup_last_rsync_exit_code rsync exit code of the most recent run (0 ok, 23 partial, 24 vanished-files)"
        echo "# TYPE local_backup_last_rsync_exit_code gauge"
        ${lib.concatMapStringsSep "\n" (backup: ''
          if [ -n "''${rc_${backup.name}:-}" ]; then
            echo "local_backup_last_rsync_exit_code{backup=\"${backup.name}\",host=\"vulcan\"} ''${rc_${backup.name}}"
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
      '') (backup.excludes or [ ])}

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

      # Record the exit code for write_metrics (all sources run before it does).
      rc_${backup.name}=$rc

      # Exit codes: 0 = success; 24 = vanished source files, genuinely benign on a
      # live filesystem (14/17 of /var's runs); 23 = PARTIAL TRANSFER DUE TO ERROR.
      #
      # 23 is deliberately NOT treated as clean. Reproduced on this host with these
      # exact flags (2026-08-04): an unreadable source file leaves the mirror
      # silently holding the PREVIOUS run's copy, and an unreadable source
      # DIRECTORY additionally prints "IO error encountered -- skipping file
      # deletion", which suppresses --delete for the WHOLE run -- so deletions
      # also stop propagating and the mirror diverges in both directions.
      # --inplace makes it worse: a failed update can leave a hybrid file that
      # looks present and restorable.
      #
      # Handling (operator decision 2026-08-04, option B): the run still exits 0
      # and .latest is still touched -- rc 23 must not page SystemdServiceFailed,
      # and the three Nagios "Local Backup:" checks read .latest directly with an
      # 8h CRITICAL + hourly re-notify, so freezing it would turn one unreadable
      # file into a recurring page. Instead the partial gets its OWN signal:
      #   * .lastclean is touched only on rc 0/24 -> feeds
      #     local_backup_last_clean_success_timestamp and the 26h
      #     LocalBackupNoCleanSuccess critical;
      #   * the exit code is exported as local_backup_last_rsync_exit_code ->
      #     LocalBackupPartialTransfer warns on == 23;
      #   * one summary line is written at priority err via systemd-cat, because
      #     this script's stdout is priority 6 and promtail drops 5-7 -- an
      #     rc-23 line logged via log() would never reach Loki.
      if [[ $rc -eq 0 || $rc -eq 23 || $rc -eq 24 ]]; then
        if [[ $rc -eq 24 ]]; then
          log "Successfully backed up ${backup.name} (some files vanished during transfer)"
        elif [[ $rc -eq 23 ]]; then
          log "PARTIAL transfer for ${backup.name} (rsync exit 23): some files were NOT transferred; mirror may be stale or hold undeleted files"
          echo "local-backup: PARTIAL transfer for ${backup.name} (rsync exit 23): some files were NOT transferred -- see journalctl -u local-backup for the per-file errors"             | ${pkgs.systemd}/bin/systemd-cat -t local-backup -p err
        else
          log "Successfully backed up ${backup.name}"
        fi

        # Touch timestamp file to indicate the backup RAN (0/23/24). Nagios and
        # the cadence alerts read this; outcome is tracked separately below.
        ${pkgs.coreutils}/bin/touch "${backupBaseDir}/.${backup.name}.latest"

        if [[ $rc -ne 23 ]]; then
          # A CLEAN mirror pass (0/24): every readable file transferred and
          # --delete ran. This marker is what "the backup WORKED" means.
          ${pkgs.coreutils}/bin/touch "${backupBaseDir}/.${backup.name}.lastclean"
        fi

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
        IOSchedulingPriority = 7; # Lowest priority (0=highest, 7=lowest)
        IOWeight = 10; # Low I/O weight (systemd IOWeight= is 1-10000, default 100)

        # Enhanced I/O throttling with cgroup v2 bandwidth limits
        # Limit read speed from source drive to prevent I/O saturation
        IOReadBandwidthMax = "/dev/nvme0n1 50M"; # 50MB/s read limit

        # Limit write speed. NOTE (verified 2026-07-27): this names /dev/nvme0n1,
        # the SOURCE disk, not the backup destination -- /tank is a ZFS pool on
        # sda-sdd (external enclosure), so destination writes are not throttled here.
        IOWriteBandwidthMax = "/dev/nvme0n1 30M"; # 30MB/s write limit

        # CPU priority: Run at lower priority
        CPUSchedulingPolicy = "batch";
        Nice = 19; # Lowest CPU priority

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
      ${lib.concatMapStringsSep "\n" (
        backup: "- ${backup.source} -> ${backupBaseDir}/${backup.name}"
      ) backupSources}

      ## Timestamp Files
      After each successful backup, a timestamp file is created:
      ${lib.concatMapStringsSep "\n" (backup: "- ${backupBaseDir}/.${backup.name}.latest") backupSources}

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
