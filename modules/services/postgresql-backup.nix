{
  config,
  lib,
  pkgs,
  ...
}:

# PostgreSQL backup — block-sharing MIRROR design (NOT dated artifacts).
#
# /tank/Backups/PostgreSQL is its own ZFS dataset (zstd, sanoid archival
# template: 24 hourly / 30 daily / 8 weekly / 12 monthly / 5 yearly autosnaps).
# ZFS snapshots are now the ONLY history layer — the dated-tarball retention
# (cleanup.py DirScanner) has been removed. This module therefore keeps a SINGLE
# live mirror of the cluster on the dataset root and lets snapshots provide the
# point-in-time history.
#
# Why a mirror instead of one compressed file per day:
#   The old design wrote postgresql-backup-YYYY-MM-DD.sql.xz — a fresh, unique
#   compressed blob every night. xz output is not block-stable, so each artifact
#   shared zero blocks with the prior one; the snapshots accumulated a full copy
#   per day and pinned ~970 GB. The fix is to make the on-disk bytes change as
#   little as possible night-to-night so consecutive ZFS snapshots share blocks.
#
# How block sharing is achieved:
#   pg_dump -Fd -Z0 (DIRECTORY format, UNCOMPRESSED) writes one file per table.
#   A table that hasn't changed dumps to byte-identical output, so its file is
#   unchanged on disk and the next snapshot references the same blocks. The
#   dataset's own zstd supplies the compression we used to get from xz — but at
#   the block layer, where unchanged blocks are shared rather than re-stored.
#   We publish the new dump over the live tree with rsync --delete --checksum;
#   --checksum is load-bearing (see the script) because the staging files always
#   have fresh mtimes and the default size+mtime quick-check would re-copy (and
#   thus un-share) every table even when its contents are identical.
#
# RESTORE:
#   psql -f globals.sql           # roles, tablespaces, grants
#   # then per database:
#   pg_restore -C -Fd -d postgres db/<name>

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;

  backupDir = "/var/lib/postgresql-backup";

  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";
  metricsFile = "${metricsDir}/pg_dump.prom";

  # Integrity / freshness emitter for the pg_dump mirror.
  #
  # A green systemd exit (Type=oneshot, code 0) is NOT proof of a complete dump:
  # on 2026-06-02 the run exited cleanly but the file truncated to 2.7 GB when
  # the UAS-backed /tank dropped mid-xz. This collector records, every run:
  #   pg_dump_last_success            1 iff $SERVICE_RESULT == "success" (ExecStopPost), else 0
  #   pg_dump_last_run_timestamp_seconds  wall-clock of this emission
  #   pg_dump_size_bytes              total byte size of the live mirror (0 if none)
  # so PgDumpFailed / PgDumpStale / PgDumpSizeShrunk can catch silent corruption.
  #
  # Runs via ExecStopPost with a '+' prefix (as root) so it always fires on
  # success AND failure and can write atomically regardless of the unit's User=.
  # $1 = run result ("success"/other from $SERVICE_RESULT, or explicit 1/0).
  # $2 = timestamp source: "now" (default, a run just completed) or "mtime"
  #      (activation seeding — use globals.sql's mtime so freshness reflects the
  #      real backup age and a mid-day rebuild does NOT mask a stale dump by
  #      resetting the clock to now).
  pgDumpMetricsScript = pkgs.writeShellScript "pg-dump-metrics" ''
    set -euo pipefail

    # Normalize the run result to a 1/0 gauge value.
    case "''${1:-0}" in
      success|1) success=1 ;;
      *)         success=0 ;;
    esac
    ts_mode="''${2:-now}"

    ${pkgs.coreutils}/bin/mkdir -p "${metricsDir}"

    # Total on-disk size of the live mirror (globals.sql + db/<name>/...). The
    # mirror is published into ${backupDir} directly; exclude the transient
    # .staging tree so an in-progress run doesn't double-count. Falls back to 0
    # if the dir is missing / empty.
    size=0
    if [ -d "${backupDir}" ]; then
      size=$(${pkgs.coreutils}/bin/du --exclude='.staging' -sb "${backupDir}" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo 0)
    fi

    # Pick the run timestamp. On seeding, anchor to globals.sql's mtime (real
    # backup age); if it doesn't exist yet, fall back to now.
    if [ "$ts_mode" = mtime ] && [ -f "${backupDir}/globals.sql" ]; then
      now=$(${pkgs.coreutils}/bin/stat -c %Y "${backupDir}/globals.sql" 2>/dev/null || ${pkgs.coreutils}/bin/date +%s)
    else
      now=$(${pkgs.coreutils}/bin/date +%s)
    fi

    tmp="${metricsFile}.$$"

    {
      echo "# HELP pg_dump_last_success Whether the most recent pg_dumpall backup run succeeded (1=success, 0=failure)"
      echo "# TYPE pg_dump_last_success gauge"
      echo "pg_dump_last_success $success"
      echo "# HELP pg_dump_last_run_timestamp_seconds Unix timestamp of the most recent PostgreSQL backup mirror run"
      echo "# TYPE pg_dump_last_run_timestamp_seconds gauge"
      echo "pg_dump_last_run_timestamp_seconds $now"
      echo "# HELP pg_dump_size_bytes Total byte size of the live PostgreSQL backup mirror (globals.sql + per-db directories)"
      echo "# TYPE pg_dump_size_bytes gauge"
      echo "pg_dump_size_bytes $size"
    } > "$tmp"

    ${pkgs.coreutils}/bin/mv "$tmp" "${metricsFile}"
    ${pkgs.coreutils}/bin/chmod 644 "${metricsFile}"
  '';

  postgresqlBackupScript = pkgs.writeShellScript "postgresql-backup" ''
    set -euo pipefail

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    log "Starting PostgreSQL backup"

    # Ensure backup directory exists with proper permissions
    if [ ! -d "${backupDir}" ]; then
      log "Creating backup directory: ${backupDir}"
      ${pkgs.coreutils}/bin/mkdir -p "${backupDir}"
      ${pkgs.coreutils}/bin/chown postgres:postgres "${backupDir}"
      ${pkgs.coreutils}/bin/chmod 750 "${backupDir}"
    fi

    # Build the new dump in a private staging tree, then atomically publish it
    # over the live mirror with rsync. Staging lives INSIDE the dataset so the
    # publish is a same-filesystem rename-free copy; NOTE this means an hourly
    # autosnap that fires mid-run may transiently pin one extra dump copy for up
    # to ~24h — accepted (a non-snapshotted staging area would need a sanoid
    # dataset override).
    staging="${backupDir}/.staging"
    ${pkgs.coreutils}/bin/rm -rf "$staging"
    ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$staging"

    # Cluster-wide globals (roles, tablespaces, grants) — one small SQL file.
    log "Dumping globals to staging/globals.sql"
    ${config.services.postgresql.package}/bin/pg_dumpall --globals-only > "$staging/globals.sql"

    # Per-database directory-format dumps. -Fd -Z0 = DIRECTORY format,
    # UNCOMPRESSED: one file per table, byte-identical when a table is unchanged,
    # so successive ZFS snapshots share blocks. -j2 parallelizes the dump; the
    # dataset's zstd provides compression at the block layer.
    ${pkgs.coreutils}/bin/mkdir -p "$staging/db"
    for db in $(${config.services.postgresql.package}/bin/psql -At -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname"); do
      log "Dumping database: $db"
      ${config.services.postgresql.package}/bin/pg_dump -Fd -Z0 -j2 --file="$staging/db/$db" "$db"
    done

    # Publish the staging tree over the live mirror. --delete prunes anything no
    # longer present (on the FIRST run this removes the legacy *.sql.xz blobs and
    # the orphan .files.dat — intended; ZFS snapshots retain them). --checksum is
    # REQUIRED: every staging file is freshly written with a new mtime, so the
    # default size+mtime quick-check would treat every table as changed and
    # re-copy it, un-sharing all blocks; --checksum compares content hashes and
    # re-copies ONLY genuinely changed tables. --exclude=/.staging keeps rsync
    # from recursing into / deleting its own source tree under the live root.
    log "Publishing staging mirror to ${backupDir}"
    ${pkgs.rsync}/bin/rsync -a --delete --checksum --exclude=/.staging "$staging/" "${backupDir}/"

    # Drop staging now that the mirror is published.
    ${pkgs.coreutils}/bin/rm -rf "$staging"

    # Log mirror size (excluding the now-removed staging tree).
    size=$(${pkgs.coreutils}/bin/du -sh --exclude='.staging' "${backupDir}" | ${pkgs.coreutils}/bin/cut -f1)
    log "Mirror size: $size"

    log "PostgreSQL backup process completed"
  '';
in
{
  systemd = {
    # PostgreSQL backup service
    services.postgresql-backup = {
      description = "Backup PostgreSQL databases";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = postgresqlBackupScript;

        # Emit integrity/freshness metrics on EVERY exit (success and failure).
        # The leading '+' runs this as root (full privileges, ignoring User=postgres)
        # so it can always write the textfile atomically. $SERVICE_RESULT is set by
        # systemd to "success" on a clean run; the emitter normalizes it to 1/0.
        ExecStopPost = "+${pgDumpMetricsScript} $SERVICE_RESULT";

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Timeout and logging. Raised 30m -> 2h: the first run writes the full
        # UNCOMPRESSED dump (~5-10x the old 17.8 GB xz), and steady-state runs
        # still read BOTH the staging and live trees end-to-end for the
        # --checksum compare.
        TimeoutStartSec = "2h";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Seed pg_dump.prom at activation so the freshness/integrity metrics exist
    # immediately (with the current mirror stats) — otherwise the series would
    # be absent until tonight's 2 AM run, leaving a coverage gap. Marks
    # success=1 because a present mirror reflects the last good backup.
    services.postgresql-backup-metrics-seed = {
      description = "Seed pg_dump.prom textfile metrics at activation";
      wantedBy = [ "multi-user.target" ];
      after = [ "var-lib-postgresql\\x2dbackup.mount" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RemainAfterExit = false;
        ExecStart = "${pgDumpMetricsScript} 1 mtime";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Timer for daily execution at 2 AM
    timers.postgresql-backup = {
      description = "Timer for PostgreSQL database backups";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run daily at 2:00 AM
        OnCalendar = "02:00";

        # Run on boot if missed (e.g., system was off)
        Persistent = true;

        # Unit to trigger
        Unit = "postgresql-backup.service";
      };
    };
  };

  # Ensure PostgreSQL is enabled (this module depends on it)
  assertions = [
    {
      assertion = config.services.postgresql.enable;
      message = "PostgreSQL backup requires services.postgresql.enable = true";
    }
  ];

  fileSystems = bindTankPath {
    path = "/var/lib/postgresql-backup";
    device = "/tank/Backups/PostgreSQL";
  };
}
