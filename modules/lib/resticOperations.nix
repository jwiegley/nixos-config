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

        # PER-REPO FAILURE ISOLATION (added 2026-07-29).
        #
        # pkgs.writeShellApplication injects `set -euo pipefail`, so before this change a
        # single failing repo ABORTED THE WHOLE SCRIPT and every repo later in the list got
        # NO integrity check at all that week -- silently, because the alert fired for the
        # run rather than naming what had been skipped. With 9 repos ordered
        # alphabetically, a persistent problem in an early one meant the rest were never
        # verified.
        #
        # The idiom matters. The obvious `if ! ( check; prune; repair ); then` is WRONG:
        # bash SUPPRESSES errexit inside a condition-context subshell, so prune and repair
        # would still run after a failed check, and a succeeding repair would mask the
        # failure entirely. `cmd || repo_failed=1` is the correct form -- errexit does not
        # fire when a failure is handled by `||`, and each command's status is captured
        # individually.
        #
        # prune/repair are SKIPPED when check fails for a repo, deliberately: a failed
        # integrity check means the repository may be damaged, and pruning a damaged repo
        # can destroy the very data needed to recover it.
        failed_repos=""

        for fileset in ${attrNameList backups} ; do
          echo "=== $fileset ==="
          repo_failed=0
          case "$operation" in
            check)
              # Unlock any stale locks before starting check operations
              /run/current-system/sw/bin/restic-$fileset unlock || true
              if /run/current-system/sw/bin/restic-$fileset \
                   --retry-lock=1h check ; then
                /run/current-system/sw/bin/restic-$fileset \
                  --retry-lock=1h prune || repo_failed=1
                /run/current-system/sw/bin/restic-$fileset \
                  --retry-lock=1h repair snapshots || repo_failed=1
              else
                repo_failed=1
                echo "CHECK FAILED for $fileset -- skipping prune and repair, because" \
                     "pruning a possibly-damaged repository can destroy recovery data."
              fi
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

          if [ "$repo_failed" -ne 0 ]; then
            failed_repos="$failed_repos $fileset"
          fi
        done

        # Fail LOUDLY and name the repos, so $SERVICE_RESULT reflects reality and the
        # operator learns WHICH repository is broken rather than only that "the check
        # failed". Every other repo has still been verified by this point.
        if [ -n "$failed_repos" ]; then
          echo "FAILED REPOS:$failed_repos"
          exit 1
        fi
      '';
    };
}
