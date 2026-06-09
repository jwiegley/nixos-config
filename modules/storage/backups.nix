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
    # via the textfile collector approach (see prometheus-monitoring.nix)
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
      name = "Public";
      time = "04:10:00";
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
        };
        serviceConfig = {
          ExecStart = "${lib.getExe (resticOperations config.services.restic.backups)} check";
          User = "root";
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
        OnCalendar = "weekly";
        Persistent = true;
      };
    };
  };
}
