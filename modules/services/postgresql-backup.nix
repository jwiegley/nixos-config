{
  config,
  lib,
  pkgs,
  ...
}:

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;

  backupDir = "/var/lib/postgresql-backup";
  backupFile = "${backupDir}/postgresql-backup-$(date '+%Y-%m-%d').sql";

  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";
  metricsFile = "${metricsDir}/pg_dump.prom";

  # Integrity / freshness emitter for the pg_dump artifact.
  #
  # A green systemd exit (Type=oneshot, code 0) is NOT proof of a complete dump:
  # on 2026-06-02 the run exited cleanly but the file truncated to 2.7 GB when
  # the UAS-backed /tank dropped mid-xz. This collector records, every run:
  #   pg_dump_last_success            1 iff $SERVICE_RESULT == "success" (ExecStopPost), else 0
  #   pg_dump_last_run_timestamp_seconds  wall-clock of this emission
  #   pg_dump_size_bytes              byte size of the NEWEST dump artifact (0 if none)
  # so PgDumpFailed / PgDumpStale / PgDumpSizeShrunk can catch silent corruption.
  #
  # Runs via ExecStopPost with a '+' prefix (as root) so it always fires on
  # success AND failure and can write atomically regardless of the unit's User=.
  # $1 = run result ("success"/other from $SERVICE_RESULT, or explicit 1/0).
  # $2 = timestamp source: "now" (default, a run just completed) or "mtime"
  #      (activation seeding — use the newest artifact's mtime so freshness
  #      reflects the real backup age and a mid-day rebuild does NOT mask a
  #      stale dump by resetting the clock to now).
  pgDumpMetricsScript = pkgs.writeShellScript "pg-dump-metrics" ''
    set -euo pipefail

    # Normalize the run result to a 1/0 gauge value.
    case "''${1:-0}" in
      success|1) success=1 ;;
      *)         success=0 ;;
    esac
    ts_mode="''${2:-now}"

    ${pkgs.coreutils}/bin/mkdir -p "${metricsDir}"

    # Newest dump artifact in the backup target dir; the live script writes
    # postgresql-backup-YYYY-MM-DD.sql then xz-compresses it to .sql.xz, so the
    # finished artifact ends in .sql.xz. Fall back to 0 if none / dir missing.
    size=0
    newest=$(${pkgs.coreutils}/bin/ls -1t ${backupDir}/postgresql-backup-*.sql.xz 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)
    if [ -n "''${newest:-}" ] && [ -f "$newest" ]; then
      size=$(${pkgs.coreutils}/bin/stat -c %s "$newest" 2>/dev/null || echo 0)
    fi

    # Pick the run timestamp. On seeding, anchor to the newest artifact's mtime
    # (real backup age); if no artifact exists, fall back to now.
    if [ "$ts_mode" = mtime ] && [ -n "''${newest:-}" ] && [ -f "$newest" ]; then
      now=$(${pkgs.coreutils}/bin/stat -c %Y "$newest" 2>/dev/null || ${pkgs.coreutils}/bin/date +%s)
    else
      now=$(${pkgs.coreutils}/bin/date +%s)
    fi

    tmp="${metricsFile}.$$"

    {
      echo "# HELP pg_dump_last_success Whether the most recent pg_dumpall backup run succeeded (1=success, 0=failure)"
      echo "# TYPE pg_dump_last_success gauge"
      echo "pg_dump_last_success $success"
      echo "# HELP pg_dump_last_run_timestamp_seconds Unix timestamp of the most recent pg_dumpall backup run"
      echo "# TYPE pg_dump_last_run_timestamp_seconds gauge"
      echo "pg_dump_last_run_timestamp_seconds $now"
      echo "# HELP pg_dump_size_bytes Byte size of the newest pg_dumpall backup artifact"
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

    # Perform backup using pg_dumpall
    log "Running pg_dumpall to ${backupFile}"
    if ${config.services.postgresql.package}/bin/pg_dumpall > "${backupFile}"; then
      log "Backup completed successfully"

      # Set permissions on backup file
      ${pkgs.coreutils}/bin/chown postgres:postgres "${backupFile}"
      ${pkgs.coreutils}/bin/chmod 640 "${backupFile}"
      # Use parallel compression (-T0) with fast preset (-0) for speed over size
      ${pkgs.xz}/bin/xz -T0 -0 "${backupFile}"

      # Log backup size
      size=$(${pkgs.coreutils}/bin/du -h "${backupFile}.xz" | ${pkgs.coreutils}/bin/cut -f1)
      log "Backup size: $size"
    else
      log "ERROR: Backup failed!"
      exit 1
    fi

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

        # Timeout and logging
        TimeoutStartSec = "30m";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Seed pg_dump.prom at activation so the freshness/integrity metrics exist
    # immediately (with the current newest-dump stats) — otherwise the series
    # would be absent until tonight's 2 AM run, leaving a coverage gap. Marks
    # success=1 because a present artifact reflects the last good backup.
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
