{ config, lib, pkgs, ... }:

let
  # Create a Python environment with dirscan available
  pythonWithDirscan = pkgs.python3.withPackages (ps: [
    # Note: dirscan is defined in overlays/dirscan.nix but we need to
    # ensure the Python module is available, not just the binary
  ]);

  cleanupScript = pkgs.writeShellScript "cleanup-wrapper" ''
    set -euo pipefail

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    log "Starting automated cleanup"

    # Add dirscan to Python path and run the cleanup script with verbose flag
    export PYTHONPATH="${pkgs.dirscan}/libexec''${PYTHONPATH:+:$PYTHONPATH}"
    ${pkgs.python3}/bin/python3 /etc/nixos/scripts/cleanup.py

    log "Cleanup completed successfully"
  '';
in
{
  systemd = {
    # Cleanup service
    services.cleanup = {
      description = "Automated cleanup of trash and old backups";
      after = [ "network.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = cleanupScript;

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = false; # Script may need elevated privileges

        # Timeout and logging
        TimeoutStartSec = "30m";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Timer for daily execution
    timers.cleanup = {
      description = "Timer for automated cleanup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run daily at 3:00 AM (after PostgreSQL backup at 2 AM)
        OnCalendar = "03:00";

        # Run on boot if missed (e.g., system was off)
        Persistent = true;

        # Unit to trigger
        Unit = "cleanup.service";
      };
    };
  };
}
