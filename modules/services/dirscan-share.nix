{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.dirscan-share;

  # Create wrapper script that sets up PYTHONPATH and runs share.py
  shareScript = pkgs.writeShellScript "dirscan-share-wrapper" ''
    set -euo pipefail

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    log "Starting dirscan share.py"
    log "Source: ${cfg.sourceDir}"
    log "Destination: ${cfg.destinationDir}"

    # Ensure source directory exists
    if [ ! -d "${cfg.sourceDir}" ]; then
      log "ERROR: Source directory does not exist: ${cfg.sourceDir}"
      exit 1
    fi

    # Ensure destination directory exists
    if [ ! -d "${cfg.destinationDir}" ]; then
      log "Creating destination directory: ${cfg.destinationDir}"
      mkdir -p "${cfg.destinationDir}"
    fi

    # Add dirscan to Python path and run share.py
    export PYTHONPATH="${pkgs.dirscan}/libexec''${PYTHONPATH:+:$PYTHONPATH}"

    ${pkgs.python3}/bin/python3 ${pkgs.dirscan}/bin/share.py \
      "${cfg.sourceDir}" \
      "${cfg.destinationDir}" \
      ${concatStringsSep " " cfg.extraArgs}

    log "Share completed successfully"
  '';
in
{
  options.services.dirscan-share = {
    enable = mkEnableOption "dirscan share.py filesystem monitoring";

    sourceDir = mkOption {
      type = types.path;
      default = "/tank/Public/johnw";
      description = ''
        Source directory to monitor and share from.
        Changes to this directory will trigger share.py execution.
      '';
    };

    destinationDir = mkOption {
      type = types.path;
      description = ''
        Destination directory to share files to.
        This directory will be created if it doesn't exist.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "User to run the share service as";
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = "Group to run the share service as";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ "-v" ];  # Verbose by default for debugging
      description = "Additional arguments to pass to share.py";
      example = [ "-v" "--dry-run" ];
    };

    destinationOwner = mkOption {
      type = types.str;
      default = cfg.user;
      description = "Owner for files in destination directory (defaults to service user)";
    };

    destinationGroup = mkOption {
      type = types.str;
      default = cfg.group;
      description = "Group for files in destination directory (defaults to service group)";
    };

    timerInterval = mkOption {
      type = types.str;
      default = "*:0/15";  # Every 15 minutes
      description = ''
        Systemd timer interval for periodic execution as fallback.
        Uses systemd calendar event format.
      '';
      example = "*:0/15";  # Every 15 minutes
    };
  };

  config = mkIf cfg.enable {
    # Main service that runs share.py
    systemd.services.dirscan-share = {
      description = "Dirscan share.py - sync shared files";
      after = [ "network.target" "local-fs.target" ];

      # Allow both path and timer to trigger this service
      unitConfig = {
        # Prevent service from being started too frequently
        StartLimitBurst = 15;
        StartLimitIntervalSec = 60;
      };

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = shareScript;

        # Ensure proper ownership after share.py completes
        ExecStartPost = pkgs.writeShellScript "fix-ownership" ''
          if [ -d "${cfg.destinationDir}" ]; then
            ${pkgs.coreutils}/bin/chown -R ${cfg.destinationOwner}:${cfg.destinationGroup} "${cfg.destinationDir}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fixed ownership: ${cfg.destinationOwner}:${cfg.destinationGroup}"
          fi
        '';

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = false;  # May need privileges for file operations

        # Timeout and logging
        TimeoutStartSec = "10m";
        StandardOutput = "journal";
        StandardError = "journal";

        # Prevent parallel execution
        LockPersonality = true;
      };
    };

    # Path unit for filesystem monitoring using inotify
    systemd.paths.dirscan-share = {
      description = "Monitor ${cfg.sourceDir} for changes";
      wantedBy = [ "multi-user.target" ];

      pathConfig = {
        # Monitor for any changes in the directory
        PathChanged = cfg.sourceDir;

        # Also monitor if directory becomes non-empty
        DirectoryNotEmpty = cfg.sourceDir;

        # Unit to trigger when changes detected
        Unit = "dirscan-share.service";

        # Coalesce multiple rapid changes into single trigger
        # Wait 10 seconds of inactivity before triggering
        MakeDirectory = false;  # Don't create the directory
      };
    };

    # Timer for periodic execution (fallback to catch missed changes)
    systemd.timers.dirscan-share = {
      description = "Periodic fallback timer for dirscan share.py";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # Run every 15 minutes by default (configurable)
        OnCalendar = cfg.timerInterval;

        # Run on boot if missed
        Persistent = true;

        # Add some randomization to prevent all services starting at once
        RandomizedDelaySec = "30s";

        # Unit to trigger
        Unit = "dirscan-share.service";
      };
    };
  };
}
