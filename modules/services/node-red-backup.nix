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

  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";
  metricsFile = "${metricsDir}/nodered_backup.prom";

  # Retention is centrally managed by /etc/nixos/scripts/cleanup.py
  # (cleanup.timer at 03:00 daily) — keep entries here in lockstep with
  # the corresponding DirScanner block over /tank/Backups/NodeRED.

  # Integrity / freshness emitter for the Node-RED backup artifact, mirroring the
  # postgresql-backup triad (a green Type=oneshot exit is NOT proof of a complete
  # backup — the UAS-backed /tank dropped mid-write on 2026-06-02, and this very
  # backup once ran against a shadow root). Records, every run:
  #   nodered_backup_last_success            1 iff $SERVICE_RESULT == "success"
  #   nodered_backup_last_run_timestamp_seconds  emission wall-clock (or newest mtime on seed)
  #   nodered_backup_size_bytes              byte size of the NEWEST .tar.zst artifact
  # Runs via ExecStopPost with a '+' prefix (root) so it fires on success AND failure.
  # $1 = run result ("success"/other from $SERVICE_RESULT, or explicit 1/0).
  # $2 = timestamp source: "now" (default) or "mtime" (activation seeding).
  noderedBackupMetricsScript = pkgs.writeShellScript "nodered-backup-metrics" ''
    set -euo pipefail

    case "''${1:-0}" in
      success|1) success=1 ;;
      *)         success=0 ;;
    esac
    ts_mode="''${2:-now}"

    ${pkgs.coreutils}/bin/mkdir -p "${metricsDir}"

    size=0
    newest=$(${pkgs.coreutils}/bin/ls -1t ${backupDir}/node-red-*.tar.zst 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)
    if [ -n "''${newest:-}" ] && [ -f "$newest" ]; then
      size=$(${pkgs.coreutils}/bin/stat -c %s "$newest" 2>/dev/null || echo 0)
    fi

    if [ "$ts_mode" = mtime ] && [ -n "''${newest:-}" ] && [ -f "$newest" ]; then
      now=$(${pkgs.coreutils}/bin/stat -c %Y "$newest" 2>/dev/null || ${pkgs.coreutils}/bin/date +%s)
    else
      now=$(${pkgs.coreutils}/bin/date +%s)
    fi

    tmp="${metricsFile}.$$"

    {
      echo "# HELP nodered_backup_last_success Whether the most recent Node-RED backup run succeeded (1=success, 0=failure)"
      echo "# TYPE nodered_backup_last_success gauge"
      echo "nodered_backup_last_success $success"
      echo "# HELP nodered_backup_last_run_timestamp_seconds Unix timestamp of the most recent Node-RED backup run"
      echo "# TYPE nodered_backup_last_run_timestamp_seconds gauge"
      echo "nodered_backup_last_run_timestamp_seconds $now"
      echo "# HELP nodered_backup_size_bytes Byte size of the newest Node-RED backup artifact"
      echo "# TYPE nodered_backup_size_bytes gauge"
      echo "nodered_backup_size_bytes $size"
    } > "$tmp"

    ${pkgs.coreutils}/bin/mv "$tmp" "${metricsFile}"
    ${pkgs.coreutils}/bin/chmod 644 "${metricsFile}"
  '';

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

        # Emit integrity/freshness metrics on EVERY exit (success and failure).
        # Leading '+' runs as root and bypasses the unit sandbox so it can write
        # the textfile atomically despite ProtectSystem=strict. $SERVICE_RESULT
        # is "success" on a clean run.
        ExecStopPost = "+${noderedBackupMetricsScript} $SERVICE_RESULT";

        # Hardening
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = [ "/var/lib/node-red" ];
        ReadWritePaths = [
          backupDir
          metricsDir
        ];

        TimeoutStartSec = "15m";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Seed nodered_backup.prom at activation so the freshness/integrity metrics
    # exist immediately (with the current newest-backup stats) rather than being
    # absent until the next 02:30 run. Marks success=1 because a present artifact
    # reflects the last good backup; anchors the timestamp to the artifact mtime.
    services.node-red-backup-metrics-seed = {
      description = "Seed nodered_backup.prom textfile metrics at activation";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RemainAfterExit = false;
        ExecStart = "${noderedBackupMetricsScript} 1 mtime";
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
