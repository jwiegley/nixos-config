{
  config,
  lib,
  pkgs,
  ...
}:

# Nightly Technitium DNS Server backup
#
# DESIGN: this is an rsync MIRROR, not a dated tarball. The backup target
# /var/lib/technitium-dns-backup is its own ZFS dataset (zstd) under
# /tank/Backups/TechnitiumDNS, and sanoid keeps the archival snapshot
# schedule (24 hourly / 30 daily / 8 weekly / 12 monthly / 5 yearly). With
# ZFS snapshots as the retention/history layer, there is no reason to keep
# accreting compressed dated artifacts here — each daily run simply makes
# the mirror reflect the current live state, and the snapshot taken after it
# is the immutable point-in-time copy. This replaces the old design, which
# built a dated technitium-dns-backup-YYYY-MM-DD.tar.xz per run and leaned on
# cleanup.py's DirScanner to age them out.
#
# Because the dataset already block-deduplicates and snapshots cheaply, the
# mirror stays small (it is the live config, not N compressed copies), and a
# restore is a plain rsync/cp back out of the dataset (or `zfs rollback` /
# clone of a chosen snapshot) rather than untar.
#
# The very first run after this switch carries `rsync --delete`, which will
# remove the legacy dated *.tar.xz tarballs and the orphan .files.dat left by
# the old design from the dataset root — that deletion is INTENDED. The
# existing ZFS snapshots still retain those artifacts if they are ever needed.
#
# Restore procedure:
#   1. sudo systemctl stop technitium-dns-server
#   2. choose a snapshot:  zfs list -t snapshot tank/Backups/TechnitiumDNS
#   3. copy state back:    sudo rsync -a \
#        /tank/Backups/TechnitiumDNS/.zfs/snapshot/<snap>/ \
#        /var/lib/technitium-dns-server/
#      (or restore the current mirror without a snapshot prefix)
#   4. sudo chown -R technitium-dns-server:technitium-dns-server \
#        /var/lib/technitium-dns-server
#   5. sudo systemctl start technitium-dns-server

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;

  sourceDir = "/var/lib/technitium-dns-server";
  backupDir = "/var/lib/technitium-dns-backup";

  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";
  metricsFile = "${metricsDir}/technitium_backup.prom";

  # Integrity / freshness emitter for the Technitium DNS backup mirror, mirroring
  # the postgresql-backup triad (a green Type=oneshot exit is NOT proof of a complete
  # backup — the UAS-backed /tank can drop mid-write). Records, every run:
  #   technitium_backup_last_success            1 iff $SERVICE_RESULT == "success"
  #   technitium_backup_last_run_timestamp_seconds  emission wall-clock (or newest mtime on seed)
  #   technitium_backup_size_bytes              byte size of the whole mirror (du -sb)
  # Runs via ExecStopPost with a '+' prefix (root) so it fires on success AND failure.
  # $1 = run result ("success"/other from $SERVICE_RESULT, or explicit 1/0).
  # $2 = timestamp source: "now" (default) or "mtime" (activation seeding — anchor to
  #      the newest file in the mirror so a mid-day rebuild does not mask a stale backup).
  technitiumBackupMetricsScript = pkgs.writeShellScript "technitium-backup-metrics" ''
    set -euo pipefail

    case "''${1:-0}" in
      success|1) success=1 ;;
      *)         success=0 ;;
    esac
    ts_mode="''${2:-now}"

    ${pkgs.coreutils}/bin/mkdir -p "${metricsDir}"

    # Size := total bytes of the mirror tree (the backup is now a live copy,
    # not a single compressed artifact). du -sb sums the whole directory.
    size=0
    if [ -d "${backupDir}" ]; then
      size=$(${pkgs.coreutils}/bin/du -sb "${backupDir}" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo 0)
    fi

    # Timestamp seed anchors to the newest file in the mirror (so a mid-day
    # rebuild reflects the last real backup's freshness), else falls back to now.
    if [ "$ts_mode" = mtime ]; then
      newest=$(${pkgs.findutils}/bin/find "${backupDir}" -type f -printf '%T@\n' 2>/dev/null | ${pkgs.coreutils}/bin/sort -nr | ${pkgs.coreutils}/bin/head -n1 || true)
      if [ -n "''${newest:-}" ]; then
        now=$(${pkgs.coreutils}/bin/printf '%.0f' "$newest")
      else
        now=$(${pkgs.coreutils}/bin/date +%s)
      fi
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
      echo "# HELP technitium_backup_size_bytes Total byte size of the Technitium DNS backup mirror"
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
      ${pkgs.coreutils}/bin/chmod 0700 "${backupDir}"
    fi

    # Verify source directory exists
    if [ ! -d "${sourceDir}" ]; then
      log "ERROR: Source directory ${sourceDir} does not exist!"
      exit 1
    fi

    log "Mirroring ${sourceDir} -> ${backupDir}"

    # Mirror the live state with rsync --delete. The first --delete run after
    # the migration removes the legacy dated *.tar.xz tarballs and the orphan
    # .files.dat from the dataset root — that is intended; ZFS snapshots retain
    # them. cache.bin / logs / stats are rebuildable runtime cruft, excluded.
    #
    # Small retry loop in the spirit of the old tar-retry: rsync can race a
    # live config dir. exit 0 (clean) or 24 (some source files vanished mid-run
    # — benign on a live tree) count as success; exit 23 (partial transfer /
    # transient error) or any other non-zero is retried after 5s, up to 3
    # attempts. We do NOT chase per-file point-in-time consistency beyond that:
    # that guarantee now belongs to the ZFS snapshot taken after this run, not
    # to the rsync pass (this replaces the old tar exit-1 "files changed" loop,
    # which tried to win the consistency race in userspace).
    max_attempts=3
    retry_delay=5  # seconds
    attempt=1
    rsync_exit=1

    while [ $attempt -le $max_attempts ]; do
      if [ $attempt -gt 1 ]; then
        log "Retry attempt $attempt/$max_attempts after ''${retry_delay}s delay..."
        ${pkgs.coreutils}/bin/sleep $retry_delay
      else
        log "Starting mirror attempt $attempt/$max_attempts"
      fi

      set +e  # Temporarily disable exit on error to capture rsync's exit code
      ${pkgs.rsync}/bin/rsync \
        -a \
        --delete \
        --exclude=/cache.bin \
        --exclude=/logs \
        --exclude=/stats \
        "${sourceDir}/" \
        "${backupDir}/"
      rsync_exit=$?
      set -e  # Re-enable exit on error

      if [ $rsync_exit -eq 0 ] || [ $rsync_exit -eq 24 ]; then
        if [ $rsync_exit -eq 24 ]; then
          log "Mirror completed (exit 24: some source files vanished mid-run, benign on a live dir)"
        else
          log "Mirror completed cleanly"
        fi
        break
      elif [ $rsync_exit -eq 23 ]; then
        log "Partial transfer (exit 23) on attempt $attempt"
        attempt=$((attempt + 1))
      else
        log "rsync failed with exit $rsync_exit on attempt $attempt"
        attempt=$((attempt + 1))
      fi
    done

    if [ $rsync_exit -ne 0 ] && [ $rsync_exit -ne 24 ]; then
      log "ERROR: Failed to produce a clean mirror after $max_attempts attempts (last exit $rsync_exit)"
      exit 1
    fi

    # Tighten at-rest perms on the mirror root. Zone files and config may carry
    # TSIG keys / API tokens; the old design left dated *.tar.xz at 0644 in a
    # 0755 dir (world-readable), which was too loose for credential-bearing
    # state. 0700 keeps the live copy readable only by root.
    ${pkgs.coreutils}/bin/chmod 0700 "${backupDir}"

    size=$(${pkgs.coreutils}/bin/du -sh "${backupDir}" | ${pkgs.coreutils}/bin/cut -f1)
    log "Mirror size: $size (history/retention handled by ZFS snapshots, not dated artifacts)"
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
    # exist immediately (with the current mirror stats) rather than being absent
    # until the next 03:00 run. Marks success=1 because a present mirror reflects
    # the last good backup; anchors the timestamp to the newest file's mtime.
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
