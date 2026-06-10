{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  user = "rclone-backup";
  configPath = config.sops.secrets."rclone-cloudbackup-config".path;
  workConfig = "/run/rclone-backup/rclone.conf";
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  baseFlags = lib.concatStringsSep " " [
    "--track-renames"
    "--transfers=8"
    "--checkers=16"
    "--max-delete=2000"
    "--max-delete-size=50G"
    "--retries=3"
    "--low-level-retries=10"
    "--log-level=INFO"
    "--stats=5m"
    "--stats-one-line"
  ];
  # Google Drive handles server-side recursive listing (ListR) well.
  commonFlags = baseFlags + " --fast-list";

  driveFlags = lib.concatStringsSep " " [
    "--drive-export-formats=docx,xlsx,pptx,svg,csv"
    "--drive-acknowledge-abuse"
    # Skip shortcuts: they resolve to other owners' files that frequently can't be
    # downloaded ("failed to open source object: operation not permitted"), which
    # otherwise fails the whole remote on every run. Proven on gdrive: 48 errors -> 0.
    "--drive-skip-shortcuts"
  ];
in
{
  ##### service user #####
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = "/var/lib/rclone-backup";
    description = "rclone cloud-drive backup";
  };
  users.groups.${user} = { };

  ##### migrated + onedrive OAuth config (SOPS, binary) #####
  sops.secrets."rclone-cloudbackup-config" = {
    format = "binary";
    sopsFile = secrets.outPath + "/rclone-cloudbackup.conf";
    owner = user;
    group = user;
    mode = "0400";
  };

  ##### idempotent ZFS dataset creation + ownership #####
  systemd.services.rclone-cloud-backup-setup = {
    description = "Create/own ZFS datasets for cloud-drive backups";
    wantedBy = [ "multi-user.target" ];
    after = [
      "zfs.target"
      "zfs-mount.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.zfs
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail
      datasets="tank/Backups/GoogleDrive \
        tank/Backups/GoogleDrive/assembly \
        tank/Backups/GoogleDrive/bia \
        tank/Backups/GoogleDrive/jwiegley \
        tank/Backups/GoogleDrive/positron \
        tank/Backups/GoogleDrive/git-ai \
        tank/Backups/OneDrive"
      for ds in $datasets; do
        if ! zfs list -H -o name "$ds" >/dev/null 2>&1; then
          zfs create "$ds"
        fi
      done
      for mp in /tank/Backups/GoogleDrive \
                /tank/Backups/GoogleDrive/assembly \
                /tank/Backups/GoogleDrive/bia \
                /tank/Backups/GoogleDrive/jwiegley \
                /tank/Backups/GoogleDrive/positron \
                /tank/Backups/GoogleDrive/git-ai \
                /tank/Backups/OneDrive; do
        chown ${user}:${user} "$mp"
        chmod 0700 "$mp"
      done
    '';
  };

  ##### nightly sync service #####
  systemd.services.rclone-cloud-backup = {
    description = "Nightly one-way mirror of cloud drives to ZFS";
    after = [
      "network-online.target"
      "rclone-cloud-backup-setup.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "rclone-cloud-backup-setup.service" ];
    path = [
      pkgs.rclone
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
    ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      TimeoutStartSec = "infinity"; # initial sync can run for hours
      Nice = 19;
      IOSchedulingClass = "idle";
      StateDirectory = "rclone-backup";
      RuntimeDirectory = "rclone-backup";
      RuntimeDirectoryPreserve = true;
      Environment = [
        "HOME=/var/lib/rclone-backup"
        "RCLONE_CONFIG=${workConfig}"
      ];
      # hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      ReadWritePaths = [
        "/tank/Backups/GoogleDrive"
        "/tank/Backups/OneDrive"
        "/var/lib/rclone-backup"
        textfileDir
      ];
    };
    onFailure = [ "backup-alert@%n.service" ]; # same template restic jobs use
    script = ''
      set -uo pipefail
      export HOME=/var/lib/rclone-backup

      # rclone persists refreshed/rotated OAuth tokens to its config, but the SOPS
      # secret is read-only. Keep a writable working copy on the (tmpfs) runtime
      # dir; reseed from SOPS only when SOPS is newer, so rotated tokens survive
      # between runs while secret edits still propagate on rebuild.
      if [ ! -e "${workConfig}" ] || [ "${configPath}" -nt "${workConfig}" ]; then
        install -m 0600 "${configPath}" "${workConfig}"
      fi

      overall=0

      # Per-remote textfile metrics. Emitted on EVERY attempt so a remote that is
      # being synced but failing every night is distinguishable from one that is
      # idle/empty (the census P2 finding: a perpetual RcloneCloudBackupStale on a
      # broken OAuth token looks identical to "nothing to copy" with the
      # success-timestamp alone). Each run writes, per remote:
      #   rclone_last_run_timestamp_seconds{remote}     attempt wall-clock (always)
      #   rclone_last_exit_code{remote}                 0 on success, 1 on failure (always)
      #   rclone_last_success_timestamp_seconds{remote} wall-clock (ONLY on success)
      # The success timestamp is sticky: on a failed run it is preserved from the
      # previous .prom file so RcloneCloudBackupStale keeps measuring true success
      # age, while (run_ts - success_ts) reveals an actively-failing remote.
      metric() {  # $1 = remote label  $2 = exit code (0 success / non-zero failure)
        local remote="$1" rc="$2" now success_line prev f
        now=$(date +%s)
        f="${textfileDir}/rclone-$remote.prom"

        if [ "$rc" -eq 0 ]; then
          success_line="rclone_last_success_timestamp_seconds{remote=\"$remote\"} $now"
        else
          # Preserve the last known success timestamp across a failed run.
          prev=$(grep -h '^rclone_last_success_timestamp_seconds' "$f" 2>/dev/null | tail -n1 || true)
          success_line="$prev"
        fi

        local tmp
        tmp=$(mktemp "$f.XXXXXX") || return 0
        {
          printf 'rclone_last_run_timestamp_seconds{remote="%s"} %s\n' "$remote" "$now"
          printf 'rclone_last_exit_code{remote="%s"} %s\n' "$remote" "$rc"
          [ -n "$success_line" ] && printf '%s\n' "$success_line"
        } > "$tmp"
        chmod 0644 "$tmp"
        mv -f "$tmp" "$f"
      }

      sync_google() {  # $1 = remote  $2 = dest
        local remote="$1" dest="$2" drives
        rclone sync "$remote": "$dest/MyDrive" ${commonFlags} ${driveFlags} || return 1
        # Shared-with-me / shared drives are best-effort and use `copy`, not `sync`:
        # the source view is intentionally partial (--drive-skip-shortcuts hides
        # shortcut targets; 403 "cannotDownloadFile" hides forbidden shares), so
        # `sync` would try to delete previously-mirrored copies, hit --max-delete,
        # and fatally abort the pass mid-run. `copy` (additive, no delete phase)
        # lets the pass finish and never fails the remote — MyDrive is authoritative.
        rclone copy "$remote": "$dest/SharedWithMe" ${commonFlags} ${driveFlags} \
          --drive-shared-with-me || echo "WARNING: $remote SharedWithMe had errors (continuing)"
        drives=$(rclone backend drives "$remote": 2>/dev/null || echo '[]')
        printf '%s' "$drives" | jq -r '.[]? | "\(.id)\t\(.name)"' \
          | while IFS=$'\t' read -r id name; do
              [ -n "$id" ] || continue
              safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._- ' '_')
              rclone copy "$remote": "$dest/SharedDrives/$safe" \
                ${commonFlags} ${driveFlags} --drive-team-drive "$id" \
                || echo "WARNING: $remote shared drive '$name' had errors (continuing)"
            done
        return 0
      }

      sync_onedrive() {  # $1 = remote  $2 = dest
        # No --fast-list: OneDrive's server-side recursive listing chokes on the
        # locked "Personal Vault" folder (invalidResourceId / ObjectHandle is
        # Invalid). Skip it and list incrementally so the filter applies.
        rclone sync "$1": "$2" ${baseFlags} --exclude "/Personal Vault/**" || return 1
        return 0
      }

      # Always record the attempt (run-ts + exit code) per remote, success or not.
      #
      # DISABLED 2026-06-10 — assembly, bia, positron, git-ai: their Google OAuth
      # client sits in "Testing" publishing status, so Google expires every refresh
      # token after exactly 7 days (all four died together 06-02/03, 7 days after
      # the 05-27 deploy; weekly interactive re-auth is not sustainable). gdrive +
      # onedrive use long-lived tokens and stay enabled. A final full snapshot of
      # all 6 remotes succeeded 2026-06-10 10:48-10:50 with freshly transplanted
      # tokens; the datasets keep that state (sanoid snapshots continue).
      # TO RE-ENABLE: publish the OAuth app to "In production" (Google console →
      # APIs & Services → OAuth consent screen), re-auth the four remotes once
      # (rclone config reconnect on hera → sops secrets/rclone-cloudbackup.conf →
      # commit → nix flake update secrets → rebuild), then uncomment these lines.
      # Their stale rclone-<remote>.prom textfiles must be deleted when disabling
      # (else RcloneCloudBackupStale fires forever) — and that's automatic on
      # re-enable (the metric() helper recreates them).
      # if sync_google assembly /tank/Backups/GoogleDrive/assembly; then metric assembly 0; else metric assembly 1; overall=1; fi
      # if sync_google bia      /tank/Backups/GoogleDrive/bia;      then metric bia      0; else metric bia      1; overall=1; fi
      if sync_google gdrive   /tank/Backups/GoogleDrive/jwiegley; then metric gdrive   0; else metric gdrive   1; overall=1; fi
      # if sync_google positron /tank/Backups/GoogleDrive/positron; then metric positron 0; else metric positron 1; overall=1; fi
      # if sync_google git-ai   /tank/Backups/GoogleDrive/git-ai;   then metric git-ai   0; else metric git-ai   1; overall=1; fi
      if sync_onedrive onedrive /tank/Backups/OneDrive;           then metric onedrive 0; else metric onedrive 1; overall=1; fi

      exit $overall
    '';
  };

  ##### nightly timer #####
  systemd.timers.rclone-cloud-backup = {
    description = "Nightly cloud-drive mirror";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 01:00:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
