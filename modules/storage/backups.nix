{
  config,
  lib,
  pkgs,
  ...
}:

let
  resticLib = import ../lib/resticOperations.nix { inherit config lib pkgs; };
  inherit (resticLib) resticOperations;

  # Helper function to create a backup configuration
  mkBackup =
    {
      name,
      path ? "/tank/${name}",
      bucket ? name,
      exclude ? [ ],
      # Per-backup start time, staggered across the call sites below so the nine
      # restic jobs don't all read the USB-attached tank enclosure at once.
      # Concurrent multi-bay I/O hung the OWC bridge on 2026-06-02 (see the UAS
      # quirk in modules/storage/zfs.nix). Heavy datasets (Photos, Video) run last.
      time ? "02:00:00",
    }:
    {
      "${name}" = {
        paths = [ "${path}" ];
        inherit exclude;
        repository = "s3:s3.us-west-001.backblazeb2.com/jwiegley-${bucket}";
        initialize = true;
        passwordFile = "/run/secrets/restic-password";
        environmentFile = "/run/secrets/aws-keys";
        timerConfig = {
          OnCalendar = "*-*-* ${time}";
          Persistent = true;
        };
        pruneOpts = [
          # forget --prune takes the repo lock too; wait it out instead of dying
          # at the default retry-lock=0 if anything (e.g. the weekly restic-check)
          # holds it. --retry-lock is a restic global flag honored by forget.
          "--retry-lock=5m"
          "--keep-daily 7"
          "--keep-weekly 5"
          "--keep-monthly 12"
          "--keep-yearly 3"
        ];
        # Wait up to 5 minutes if repository is locked (prevents immediate failures)
        extraBackupArgs = [ "--retry-lock=5m" ];
        # Clean up any stale locks before starting backup
        backupPrepareCommand = "${pkgs.restic}/bin/restic unlock || true";
      };
    };

  # Common exclude patterns for source code
  sourceExcludes = [
    "*.agdai"
    "*.aux"
    "*.cma"
    "*.cmi"
    "*.cmo"
    "*.cmx"
    "*.cmxa"
    "*.cmxs"
    "*.elc"
    "*.eln"
    "*.glob"
    "*.hi"
    "*.lia-cache"
    "*.lra-cache"
    "*.nia-cache"
    "*.nra-cache"
    "*.o"
    "*.vo"
    "*.vok"
    "*.vos"
    ".cabal"
    ".cache"
    ".cargo"
    ".coq-native"
    ".ghc"
    ".ghc.*"
    ".lia.cache"
    ".local/share/vagrant"
    ".lra.cache"
    ".nia.cache"
    ".nra.cache"
    ".slocdata"
    ".vagrant"
    ".venv"
    "MAlonzo"
    "dist"
    "dist-newstyle"
    "node_modules"
    "result"
    "result-*"
    "target"
  ];

  # Home directory excludes
  homeExcludes = [
    ".cache"
    "Library/Application Support/Bookmap/Cache"
    "Library/Application Support/CloudDocs"
    "Library/Application Support/FileProvider"
    "Library/Application Support/MobileSync"
    "Library/CloudStorage/GoogleDrive-copper2gold1@gmail.com"
    "Library/Containers"
    "Library/Caches/GeoServices"
  ];

  # Audio excludes
  audioExcludes = [
    "In Our Time"
  ];

  # Video excludes
  videoExcludes = [
    "Bicycle"
    "Category Theory"
    "Cinema"
    "Finance"
    "Haskell"
    "Racial Justice"
    "Zoom"
  ];

  # Backup excludes
  backupExcludes = [
    "Assembly"
    "Contracts"
    "Git"
    "Images"
    "Machines"
    "PostgreSQL"
    "TechnitiumDNS"
    # cloud-drive mirrors (rclone-cloud-backup): local-only, never pushed to B2
    "GoogleDrive"
    "OneDrive"
    # Sessions (dataset tank/Backups/Sessions) is the gathered AI-session
    # archive. It is itself a copy of session roots that still live on their
    # source hosts, so shipping it to B2 pays to protect a backup with a backup.
    # Left in, it would roughly double this repo: 350.9 GB at the time of
    # writing, against an archive the gatherer expects to reach ~220 GiB.
    # Excluded at John's direction 2026-08-14; the sessions design scopes Restic
    # out explicitly too.
    "Sessions"
  ];

  # Photos excludes
  photosExcludes = [
    "Immich"
  ];

in
{
  # List snapshots to verify backups are being created:
  # > sudo restic-doc snapshots
  # Test a restore to verify data can be recovered:
  # > sudo restic-doc restore --target /path/to/restore/directory latest
  # Check repository integrity:
  # > sudo restic-doc check

  # These directories are either too large, too private, or are already backed
  # up via another cloud service.
  #
  # mkBackup { path = "Desktop"; }
  # mkBackup { path = "Documents"; }
  # mkBackup { path = "Downloads"; }
  # mkBackup { path = "Machines"; }
  # mkBackup { path = "Models"; }
  # mkBackup { path = "Movies"; }
  # mkBackup { path = "Music"; }
  # mkBackup { path = "Pictures"; }

  sops.secrets = {
    aws-keys = { };
    restic-password = { };
    # Note: Restic metrics collection uses aws-keys and restic-password
    # via the textfile collector approach (see
    # modules/monitoring/services/restic-metrics.nix:37-44; there is no
    # prometheus-monitoring.nix in this repo)
  };

  # Staggered start times (20-min spacing from 02:10) so the nine restic jobs
  # don't hammer the USB tank enclosure simultaneously. postgresql-backup keeps
  # 02:00 to itself; the heavy datasets (Photos, Video) run last with extra gaps.
  services.restic.backups = lib.mkMerge [
    (mkBackup {
      name = "Audio";
      time = "02:10:00";
      exclude = audioExcludes;
    })
    (mkBackup {
      name = "Backups";
      bucket = "Backups-Misc";
      time = "03:30:00";
      exclude = backupExcludes;
    })
    (mkBackup {
      name = "Databases";
      time = "02:50:00";
      exclude = [
        "*.dtBase/Backup*"
        "*.zim"
        "slack*"
        "Assembly"
      ];
    })
    (mkBackup {
      name = "Home";
      time = "03:50:00";
      exclude = homeExcludes;
    })
    (mkBackup {
      name = "Photos";
      time = "04:40:00";
      exclude = photosExcludes;
    })
    (mkBackup {
      name = "Video";
      time = "05:30:00";
      exclude = videoExcludes;
    })
    (mkBackup {
      name = "doc";
      time = "02:30:00";
      exclude = [ "*.dtBase/Backup*" ];
    })
    (mkBackup {
      name = "src";
      time = "03:10:00";
      exclude = sourceExcludes;
    })
    (mkBackup {
      name = "Documents";
      # 04:25 rather than continuing the 20-minute rhythm: 04:10 (Public) and
      # 04:40 (Photos) were the nearest neighbours and this splits that gap.
      # The stagger exists to keep concurrent reads off the USB tank enclosure,
      # and measured 2026-08-14 every existing job finishes in well under a
      # minute once the initial upload is done -- Public 3s, Audio 7s, Video 7s,
      # doc 10s, Backups 11s, Photos 11s, src 20s, Databases 36s, Home 39s.
      # 15 minutes of clearance either side is therefore generous. The FIRST run
      # is the exception: it uploads the whole 12.5G and will take far longer.
      time = "04:25:00";
      # Syncthing bookkeeping, excluded on the same reasoning as Public below.
      # .stversions is Syncthing's own copy of superseded file versions (209M at
      # the dataset root, 118K under Obsidian) and is redundant here: restic
      # already keeps 7 daily / 5 weekly / 12 monthly / 3 yearly snapshots, so
      # file history is preserved by the backup itself rather than by shipping
      # Syncthing's duplicate of it to B2.
      exclude = [
        ".stfolder"
        ".stignore"
        ".stversions"
        # Requested by John 2026-08-14, "for now" -- expected to be revisited.
        # NOTE: no directory of this name existed anywhere under /tank/Documents
        # when this was added (checked case-insensitively at every depth; the
        # only 'session' hits were two Obsidian .md files). The pattern is
        # therefore inert today and will start excluding the moment such a
        # directory appears. Left unanchored, like the .st* entries above, so it
        # matches at any depth rather than only at the dataset root -- the
        # intended location was not known.
        "Sessions"
      ];
    })
    (mkBackup {
      name = "Public";
      time = "04:10:00";
      # Retained historical sync markers remain under Public. Keep only
      # marker metadata out of B2 until cleanup is explicitly approved.
      # Conflict copies and temp artifacts may contain recoverable payload,
      # so they are intentionally backed up.
      exclude = [
        ".stfolder"
        ".stignore"
        ".stversions"
      ];
    })
  ];

  # Get list of all backup names to create service overrides
  # ConditionPathIsMountPoint prevents "failed" status during rebuild when mount unavailable
  systemd.services = lib.mkMerge [
    # Override each individual restic-backups-* service
    (lib.mkMerge (
      map (name: {
        "restic-backups-${name}" = {
          after = [
            "zfs.target"
            "zfs-import-tank.service"
          ];
          # NOT wantedBy=tank.mount: that pulled all 9 backups at once when the
          # USB/UAS tank imported at boot -> simultaneous heavy B2 reads that hung
          # the OWC bridge (2026-06-02). Staggered OnCalendar timers (02:10-05:30)
          # + Persistent=true provide the spacing and missed-run catch-up, so the
          # boot trigger was redundant and harmful. Mirrors the restic-check de-herd
          # below. (Audit 2026-06-09.)
          unitConfig = {
            RequiresMountsFor = [ "/tank" ];
            ConditionPathIsMountPoint = "/tank";
          };
          # Prevent restart during system reconfiguration if backup is running
          # This avoids repository lock conflicts when nixos-rebuild runs during a backup
          serviceConfig = {
            X-RestartIfChanged = false;
          };
        };
      }) (builtins.attrNames config.services.restic.backups)
    ))

    # restic-check service
    {
      restic-check = {
        description = "Run restic check on backup repository";
        after = [
          "zfs.target"
          "zfs-import-tank.service"
        ];
        # NOT wantedBy=tank.mount. restic-check takes an exclusive repo lock; when
        # it co-started with the 9 backups' forget/prune at the tank.mount boot
        # trigger it lost the lock race and exited 11 on every reboot. It is now
        # driven ONLY by its weekly timer (Persistent=yes catches up a missed run),
        # so it never races the boot herd. (Audit 2026-06-08.)
        unitConfig = {
          RequiresMountsFor = [ "/tank" ];
          ConditionPathIsMountPoint = "/tank";
          # Reuse the same alert template the restic-backups-* jobs use
          # (defined in backup-monitoring.nix). %n expands to this unit's full
          # name "restic-check.service", which the alert script logs as $1.
          # Previously empty: a corrupt repo / bit-rot detection failed silently.
          OnFailure = "backup-alert@%n.service";
        };
        serviceConfig = {
          ExecStart = "${lib.getExe (resticOperations config.services.restic.backups)} check";
          User = "root";
          # Backstop only. Rotating data verification put a real network-dependent workload
          # in this unit (~2h expected), so it needs an upper bound -- but this is a HARD
          # kill that would abort the per-repo loop and lose the per-repo failure accounting,
          # so the script carries its own 3h budget and 1h per-repo cap to stay inside it.
          # Reaching 4h means the script's own budgeting failed and the loud failure is
          # correct: the unit fails, the gauge goes 0, and ResticIntegrityCheckFailed pages.
          RuntimeMaxSec = "4h";
          # Export the integrity-check outcome as node-exporter textfile metrics so
          # a silent failure (exit != 0, lock loss, repo corruption) becomes alertable.
          # ExecStopPost runs in both success and failure paths; $SERVICE_RESULT is
          # "success" only on a clean exit. Written atomically (tmp + mv), mode 644,
          # mirroring container-health-exporter.nix. Runs as root (User=root) so it
          # can write into the world-writable textfile dir and chmod the result.
          ExecStopPost = pkgs.writeShellScript "restic-check-metrics" ''
            # `-e` added 2026-07-29. With only `set -u`, a failed write left the PREVIOUS
            # file in place -- so a run that failed to record SUCCESS=0 kept publishing the
            # stale 1 from last week, and the script still exited 0 because the final chmod
            # succeeded against that surviving file. The one gauge whose job is to report a
            # failed integrity check could therefore report success indefinitely, with no
            # trace. With `-e` the write failure fails ExecStopPost, which marks the unit
            # failed and is caught by the fleet node_systemd_unit_state alerting.
            #
            # The mv itself is safe: METRICS_TMP is in the same directory as METRICS_FILE,
            # so it is a rename(2) and node-exporter can never observe a half-written file.
            set -eu

            METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/restic_check.prom"
            METRICS_TMP="$METRICS_FILE.tmp"

            mkdir -p "$(dirname "$METRICS_FILE")"

            if [ "''${SERVICE_RESULT:-}" = "success" ]; then
              SUCCESS=1
            else
              SUCCESS=0
            fi

            NOW=$(${pkgs.coreutils}/bin/date +%s)

            cat > "$METRICS_TMP" <<EOF
            # HELP restic_integrity_check_success Whether the last weekly restic check completed successfully (1=ok, 0=failed)
            # TYPE restic_integrity_check_success gauge
            restic_integrity_check_success $SUCCESS
            # HELP restic_integrity_check_timestamp_seconds Unix time of the last restic integrity check run
            # TYPE restic_integrity_check_timestamp_seconds gauge
            restic_integrity_check_timestamp_seconds $NOW
            EOF

            mv "$METRICS_TMP" "$METRICS_FILE"
            chmod 644 "$METRICS_FILE"
          '';
        };
      };
    }
  ];

  systemd.timers = {
    restic-check = {
      description = "Timer for restic check";
      # Only timers.target — NOT tank.mount (which fired the check at every boot
      # into the backup herd's lock race). Persistent=yes catches up a missed run.
      wantedBy = [
        "timers.target"
      ];
      timerConfig = {
        # Moved off `weekly` (= Mon 00:00) 2026-07-29, when rotating data verification
        # took this job from ~7 minutes to ~2 hours. At 00:00 a 2-3h run would have
        # spilled straight into the staggered backup herd that starts at 02:10, and those
        # jobs' `forget --prune` only waits `--retry-lock=5m` before failing. 06:30 sits
        # after the last backup (05:30) with the whole morning clear.
        OnCalendar = "Mon 06:30";
        Persistent = true;
      };
    };
  };
}
