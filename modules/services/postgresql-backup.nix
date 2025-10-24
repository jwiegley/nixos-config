{ config, lib, pkgs, ... }:

let
  backupDir = "/var/lib/postgresql-backup";
  backupFile = "${backupDir}/postgresql-backup-$(date '+%Y-%m-%d').sql";

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
      ${pkgs.xz}/bin/xz "${backupFile}"

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

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Timeout and logging
        TimeoutStartSec = "30m";
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
}
