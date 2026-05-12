{
  config,
  lib,
  pkgs,
  ...
}:

# Nightly Node-RED backup
#
# Captures /var/lib/node-red minus rebuildable content (node_modules, npm
# cache). The tarball is sufficient to fully restore flows, credentials,
# the palette, the auto-generated _credentialSecret, and per-node
# persistent state (context, cronplusdata) on a fresh install.
#
# Restore procedure:
#   1. sudo systemctl stop node-red
#   2. sudo rm -rf /var/lib/node-red/*  /var/lib/node-red/.[!.]*
#   3. sudo tar -xf /tank/Backups/NodeRED/node-red-YYYY-MM-DD.tar.zst -C /var/lib
#   4. sudo chown -R node-red:node-red /var/lib/node-red
#   5. cd /var/lib/node-red && sudo -u node-red npm install   # restores node_modules
#   6. sudo systemctl start node-red

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;

  backupDir = "/var/lib/node-red-backup";

  # Retention is centrally managed by /etc/nixos/scripts/cleanup.py
  # (cleanup.timer at 03:00 daily) — keep entries here in lockstep with
  # the corresponding DirScanner block over /tank/Backups/NodeRED.

  nodeRedBackupScript = pkgs.writeShellScript "node-red-backup" ''
    set -euo pipefail

    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

    log "Starting Node-RED backup"

    # Sanity: confirm the bind mount is in place. If the /tank dataset
    # isn't mounted, /var/lib/node-red-backup would resolve to the OS
    # pool, which silently fills the root filesystem.
    if ! ${pkgs.util-linux}/bin/mountpoint -q "${backupDir}"; then
      log "ERROR: ${backupDir} is not a mountpoint — refusing to back up to OS pool"
      exit 1
    fi

    BACKUP_FILE="${backupDir}/node-red-$(date '+%Y-%m-%d').tar.zst"

    log "Creating $BACKUP_FILE"
    ${pkgs.gnutar}/bin/tar \
      --create \
      --use-compress-program='${pkgs.zstd}/bin/zstd -T0 -3' \
      --warning=no-file-changed \
      --exclude='node-red/node_modules' \
      --exclude='node-red/.npm' \
      --exclude='node-red/.cache' \
      --exclude='node-red/*.tmp' \
      --file "$BACKUP_FILE" \
      --directory /var/lib \
      node-red

    # Tarball contains _credentialSecret — lock it down.
    ${pkgs.coreutils}/bin/chmod 0600 "$BACKUP_FILE"

    SIZE=$(${pkgs.coreutils}/bin/du -h "$BACKUP_FILE" | ${pkgs.coreutils}/bin/cut -f1)
    log "Backup size: $SIZE (retention handled by cleanup.service at 03:00)"

    KEEPING=$(${pkgs.findutils}/bin/find "${backupDir}" -maxdepth 1 -name 'node-red-*.tar.zst' -type f | ${pkgs.coreutils}/bin/wc -l)
    log "Node-RED backup complete; $KEEPING tarball(s) on disk"
  '';
in
{
  systemd = {
    services.node-red-backup = {
      description = "Backup Node-RED configuration and flows";

      # Run after Node-RED is up (not required — backup works either way —
      # but ordering avoids racing a Node-RED-managed write).
      after = [ "node-red.service" ];

      serviceConfig = {
        Type = "oneshot";
        # root so we can read everything under /var/lib/node-red regardless
        # of how Node-RED has chowned individual files.
        User = "root";
        Group = "root";
        ExecStart = nodeRedBackupScript;

        # Hardening
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = [ "/var/lib/node-red" ];
        ReadWritePaths = [ backupDir ];

        TimeoutStartSec = "15m";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    timers.node-red-backup = {
      description = "Timer for nightly Node-RED backup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # 30 min after postgresql-backup at 02:00 to avoid I/O contention.
        OnCalendar = "02:30";
        Persistent = true;
        Unit = "node-red-backup.service";
      };
    };
  };

  assertions = [
    {
      assertion = config.services.node-red.enable;
      message = "Node-RED backup requires services.node-red.enable = true";
    }
  ];

  fileSystems = bindTankPath {
    path = backupDir;
    device = "/tank/Backups/NodeRED";
  };
}
