{ config, lib, pkgs, ... }:

let
  # Helper function to create a backup configuration
  mkBackup = {
    name,
    path ? "/tank/${name}",
    bucket ? name,
    exclude ? []
  }: {
    "${name}" = {
      paths = [ "${path}" ];
      inherit exclude;
      repository = "s3:s3.us-west-001.backblazeb2.com/jwiegley-${bucket}";
      initialize = true;
      passwordFile = "/run/secrets/restic-password";
      environmentFile = "/run/secrets/aws-keys";
      timerConfig = {
        OnCalendar = "*-*-* 02:00:00";  # Daily at 2AM
        Persistent = true;
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-yearly 3"
      ];
      # Wait up to 5 minutes if repository is locked (prevents immediate failures)
      extraBackupArgs = [ "--retry-lock=5m" ];
      # Clean up any stale locks before starting backup
      backupPrepareCommand = "restic unlock || true";
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
    "pair"
    "rpool"
  ];

  attrNameList = attrs:
    builtins.concatStringsSep " " (builtins.attrNames attrs);

  # Restic operations script
  resticOperations = backups: pkgs.writeShellApplication {
    name = "restic-operations";
    text = ''
      operation="''${1:-check}"
      shift || true

      for fileset in ${attrNameList backups} ; do
        echo "=== $fileset ==="
        case "$operation" in
          check)
            # Unlock any stale locks before starting check operations
            /run/current-system/sw/bin/restic-$fileset unlock || true
            /run/current-system/sw/bin/restic-$fileset \
              --retry-lock=1h check
            /run/current-system/sw/bin/restic-$fileset \
              --retry-lock=1h prune
            /run/current-system/sw/bin/restic-$fileset \
              --retry-lock=1h repair snapshots
            ;;
          snapshots)
            /run/current-system/sw/bin/restic-$fileset snapshots --json | \
              ${pkgs.jq}/bin/jq -r \
                'sort_by(.time) | reverse | .[:4][] | .time'
            ;;
          *)
            echo "Unknown operation: $operation"
            exit 1
            ;;
        esac
      done
    '';
  };
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
    aws-keys = {};
    restic-password = {};
    # Note: Restic metrics collection uses aws-keys and restic-password
    # via the textfile collector approach (see prometheus-monitoring.nix)
  };

  services.restic.backups = lib.mkMerge [
    (mkBackup {
      name = "Audio";
    })
    (mkBackup {
      name = "Backups";
      bucket = "Backups-Misc";
      exclude = backupExcludes;
    })
    (mkBackup {
      name = "Databases";
      exclude = [
        "*.dtBase/Backup*"
        "*.zim"
        "slack*"
        "Assembly"
      ];
    })
    (mkBackup {
      name = "Home";
      exclude = homeExcludes;
    })
    (mkBackup {
      name = "Nextcloud";
      exclude = [
        "*/cache/*"
        "*/appdata_*/preview/*"
        "*/tmp/*"
        "*/updater-*"
      ];
    })
    (mkBackup {
      name = "Photos";
    })

    (mkBackup {
      name = "Video";
      exclude = videoExcludes;
    })
    (mkBackup {
      name = "doc";
      exclude = [ "*.dtBase/Backup*" ];
    })
    (mkBackup {
      name = "src";
      exclude = sourceExcludes;
    })
  ];

  # Get list of all backup names to create service overrides
  # ConditionPathIsMountPoint prevents "failed" status during rebuild when mount unavailable
  systemd.services = lib.mkMerge [
    # Override each individual restic-backups-* service
    (lib.mkMerge (map (name: {
      "restic-backups-${name}" = {
        after = [ "zfs.target" "zfs-import-tank.service" ];
        wantedBy = [ "tank.mount" ];
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
    }) (builtins.attrNames config.services.restic.backups)))

    # restic-check service
    {
      restic-check = {
        description = "Run restic check on backup repository";
        after = [ "zfs.target" "zfs-import-tank.service" ];
        wantedBy = [ "tank.mount" ];
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
      wantedBy = [ "timers.target" "tank.mount" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };
  };
}
