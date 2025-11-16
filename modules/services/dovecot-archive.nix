{ config, lib, pkgs, ... }:

let
  # Script that runs the doveadm archive command
  dovecotArchiveScript = pkgs.writeShellScript "dovecot-archive" ''
    set -euo pipefail

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    log "Starting Dovecot email archive process"

    # Archive emails older than 365 days from INBOX to Archive folder
    # Runs as user johnw
    ${pkgs.dovecot}/bin/doveadm move -u johnw Archive mailbox INBOX SENTBEFORE 365d

    exit_code=$?
    if [ $exit_code -eq 0 ]; then
      log "Email archive completed successfully"
    else
      log "ERROR: Email archive failed with exit code $exit_code"
      exit $exit_code
    fi
  '';
in
{
  systemd = {
    # Dovecot archive service
    services.dovecot-archive = {
      description = "Archive old emails from INBOX to Archive folder";
      after = [ "dovecot2.service" ];
      requires = [ "dovecot2.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = dovecotArchiveScript;

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Timeout and logging
        TimeoutStartSec = "10m";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Timer for daily execution at 3:00 AM
    timers.dovecot-archive = {
      description = "Timer for daily email archival";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run daily at 3:00 AM
        OnCalendar = "03:00";

        # Run on boot if missed (e.g., system was off)
        Persistent = true;

        # Unit to trigger
        Unit = "dovecot-archive.service";
      };
    };
  };

  # Ensure Dovecot is enabled (this module depends on it)
  assertions = [
    {
      assertion = config.services.dovecot2.enable;
      message = "Dovecot archive requires services.dovecot2.enable = true";
    }
  ];
}
