{ config, lib, pkgs, ... }:

let
  # Helper function to create a backup configuration
  mkBackup = {
    path,
    name ? path,
    bucket ? name,
    explicit ? false,
    exclude ? []
  }: {
    "${name}" = {
      paths = if explicit then [ path ] else [ "/tank/${path}" ];
      inherit exclude;
      repository = "s3:s3.us-west-001.backblazeb2.com/jwiegley-${bucket}";
      initialize = true;
      passwordFile = "/secrets/restic_password";
      environmentFile = "/secrets/aws_keys";
      timerConfig = {
        OnCalendar = "*-*-* 02:00:00";  # Daily at 2AM
        Persistent = true;
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-yearly 3"
      ];
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
    "Kadena"
    "Racial Justice"
    "Zoom"
  ];

  # Backup excludes
  backupExcludes = [
    "Git"
    "Images"
    "chainweb"
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
  # mkBackup { path = "kadena"; }

  services.restic.backups = lib.mkMerge [
    (mkBackup {
      path = "doc";
      exclude = [ "*.dtBase/Backup*" ];
    })
    (mkBackup {
      path = "src";
      exclude = sourceExcludes;
    })
    (mkBackup {
      path = "Home";
      exclude = homeExcludes;
    })
    (mkBackup {
      path = "Photos";
    })
    (mkBackup {
      path = "Audio";
    })
    (mkBackup {
      path = "Video";
      exclude = videoExcludes;
    })
    (mkBackup {
      path = "Backups";
      bucket = "Backups-Misc";
      exclude = backupExcludes;
    })
    (mkBackup {
      path = "Nasim";
    })
  ];

  systemd = {
    services.restic-check = {
      description = "Run restic check on backup repository";
      serviceConfig = {
        ExecStart = "${lib.getExe (resticOperations config.services.restic.backups)} check";
        User = "root";
      };
    };

    timers.restic-check = {
      description = "Timer for restic check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };
  };
}
