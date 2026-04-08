{
  config,
  lib,
  pkgs,
  ...
}:

let
  attrNameList = attrs: builtins.concatStringsSep " " (builtins.attrNames attrs);
in
{
  inherit attrNameList;

  # Generate a script that runs restic operations across all configured backup repos
  resticOperations =
    backups:
    pkgs.writeShellApplication {
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
}
