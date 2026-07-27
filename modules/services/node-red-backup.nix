{
  config,
  lib,
  pkgs,
  ...
}:

# Nightly Node-RED backup
#
# Maintains an rsync MIRROR of /var/lib/node-red minus rebuildable content
# (node_modules, npm cache) on /tank/Backups/NodeRED. The mirror is
# sufficient to fully restore flows, credentials, the palette, the
# auto-generated _credentialSecret, and per-node persistent state
# (context, cronplusdata) on a fresh install.
#
# Why a mirror (not a dated tarball)?
#   /tank/Backups/NodeRED is its own ZFS dataset (zstd) under the sanoid
#   archival template (24 hourly / 30 daily / 8 weekly / 12 monthly /
#   5 yearly autosnaps). ZFS snapshots are now the SOLE history/retention
#   layer: every snapshot is a frozen point-in-time copy of the mirror, so
#   the per-file dated-artifact scheme (and cleanup.py's DirScanner over
#   this directory) is redundant and has been retired. The live mirror is
#   always the latest state; "yesterday's backup" is `.zfs/snapshot/...`.
#   zstd compression on the dataset replaces the per-tarball zstd, and
#   block-level dedup across snapshots makes an unpacked mirror cheaper to
#   retain than a chain of full tarballs.
#
# Restore procedure (latest mirror):
#   1. sudo systemctl stop node-red
#   2. sudo rm -rf /var/lib/node-red/*  /var/lib/node-red/.[!.]*
#   3. sudo rsync -a /tank/Backups/NodeRED/ /var/lib/node-red/
#   4. sudo chown -R node-red:node-red /var/lib/node-red
#   5. cd /var/lib/node-red && sudo -u node-red npm install   # restores node_modules
#   6. sudo systemctl start node-red
#
# To restore an OLDER point in time, substitute a snapshot for the source:
#   sudo rsync -a /tank/Backups/NodeRED/.zfs/snapshot/<snap>/ /var/lib/node-red/

let
  bindTankLib = import ../lib/bindTankModule.nix { inherit config lib pkgs; };
  inherit (bindTankLib) bindTankPath;

  backupDir = "/var/lib/node-red-backup";

  metricsDir = "/var/lib/prometheus-node-exporter-textfiles";
  metricsFile = "${metricsDir}/nodered_backup.prom";

  # Retention is now handled entirely by ZFS snapshots of the
  # /tank/Backups/NodeRED dataset (sanoid archival template) — the
  # cleanup.py DirScanner over this directory has been retired. The
  # rsync --delete below prunes the live mirror to match the source;
  # snapshots preserve everything the mirror drops, including the legacy
  # dated tarballs and the orphan .files.dat that the FIRST mirror run
  # sweeps away.

  # Integrity / freshness emitter for the Node-RED backup mirror, mirroring the
  # postgresql-backup triad (a green Type=oneshot exit is NOT proof of a complete
  # backup — the UAS-backed /tank dropped mid-write on 2026-06-02, and this very
  # backup once ran against a shadow root). Records, every run:
  #   nodered_backup_last_success            1 iff $SERVICE_RESULT == "success"
  #   nodered_backup_last_run_timestamp_seconds  emission wall-clock (or newest mirror mtime on seed)
  #   nodered_backup_size_bytes              total byte size of the mirror (du -sb)
  # Runs via ExecStopPost with a '+' prefix (root) so it fires on success AND failure.
  # $1 = run result ("success"/other from $SERVICE_RESULT, or explicit 1/0).
  # $2 = timestamp source: "now" (default) or "mtime" (activation seeding).
  # NOTE: with a mirror (vs a fresh dated artifact), nodered_backup_size_bytes
  # is the whole-tree size (a few MB, not the old ~290KB per-day tarball). The
  # SizeShrunk alert's 14d trailing average makes it insensitive during the
  # transition window — acceptable while history rebuilds on the new scale.
  # (That window closed 14d after the 2026-06-10 switch to a mirror; as of
  # 2026-07-27 the average is fully on the mirror scale, ~6 MB.)
  noderedBackupMetricsScript = pkgs.writeShellScript "nodered-backup-metrics" ''
    set -euo pipefail

    case "''${1:-0}" in
      success|1) success=1 ;;
      *)         success=0 ;;
    esac
    ts_mode="''${2:-now}"

    ${pkgs.coreutils}/bin/mkdir -p "${metricsDir}"

    # Size := apparent byte size of the whole mirror tree (du -sb). Falls
    # back to 0 if the mirror dir is absent (e.g. tank not mounted).
    size=0
    if [ -d "${backupDir}" ]; then
      size=$(${pkgs.coreutils}/bin/du -sb "${backupDir}" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo 0)
    fi
    size=''${size:-0}

    # Freshness anchor: on activation seeding (mtime mode) use the newest
    # mtime among the mirror's files (the last time a backup actually wrote
    # something), integer-truncated; otherwise emission wall-clock. Falls
    # back to now if the mirror is empty/absent.
    if [ "$ts_mode" = mtime ]; then
      newest_mtime=$(${pkgs.findutils}/bin/find "${backupDir}" -type f -printf '%T@\n' 2>/dev/null | ${pkgs.coreutils}/bin/sort -n | ${pkgs.coreutils}/bin/tail -n1 || true)
      if [ -n "''${newest_mtime:-}" ]; then
        now=''${newest_mtime%.*}
      else
        now=$(${pkgs.coreutils}/bin/date +%s)
      fi
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
      echo "# HELP nodered_backup_size_bytes Total byte size of the Node-RED backup mirror"
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

    log "Mirroring /var/lib/node-red to ${backupDir}"

    # rsync mirror (not a dated tarball): --delete prunes the destination to
    # match the source, so the live mirror is always the current state and
    # ZFS snapshots hold the history. The excludes were tar-anchored under
    # 'node-red/'; as rsync root-anchored patterns they become /node_modules
    # etc. (leading slash = relative to the transfer root = the source dir).
    #
    # On the FIRST run --delete removes the legacy node-red-*.tar.zst tarballs
    # and the orphan .files.dat that the old cleanup scheme left behind — that
    # is intended; the most recent snapshot still retains them.
    #
    # rsync exit 24 ("some files vanished before transfer") is the live-dir
    # equivalent of tar's --warning=no-file-changed: Node-RED rewrote a file
    # we'd already enumerated. Tolerate ONLY 24; any other non-zero is a real
    # failure. Temporarily disable -e so we can inspect $?.
    set +e
    ${pkgs.rsync}/bin/rsync -a --delete \
      --exclude=/node_modules \
      --exclude=/.npm \
      --exclude=/.cache \
      --exclude='*.tmp' \
      /var/lib/node-red/ "${backupDir}/"
    rc=$?
    set -e
    if [ "$rc" -eq 24 ]; then
      log "rsync exit 24 (source files vanished mid-run) — tolerated"
      rc=0
    fi
    if [ "$rc" -ne 0 ]; then
      log "ERROR: rsync failed with exit $rc"
      exit "$rc"
    fi

    # The mirror holds _credentialSecret and flows_cred.json as plain files
    # (rsync -a preserved their per-file source perms). Lock down the mirror
    # ROOT so the tree is not group/world traversable — the old tarballs were
    # 0600 for exactly this reason.
    ${pkgs.coreutils}/bin/chmod 0700 "${backupDir}"

    SIZE=$(${pkgs.coreutils}/bin/du -sh "${backupDir}" | ${pkgs.coreutils}/bin/cut -f1)
    log "Mirror size: $SIZE (history/retention handled by ZFS snapshots)"

    FILES=$(${pkgs.findutils}/bin/find "${backupDir}" -type f | ${pkgs.coreutils}/bin/wc -l)
    log "Node-RED backup complete; $FILES file(s) in mirror"
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
    # exist immediately (with the current mirror's stats) rather than being
    # absent until the next 02:30 run. Marks success=1 because a populated mirror
    # reflects the last good backup; anchors the timestamp to the newest mirror
    # file mtime.
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
