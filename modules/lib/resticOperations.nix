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
        # run rather than naming what had been skipped. builtins.attrNames sorts by BYTE
        # value, giving
        #   Audio Backups Databases Home Photos Public Video doc src
        # -- lowercase sorts AFTER every uppercase name, so `doc` and `src` are last rather
        # than interleaved where a case-insensitive alphabetical order would put them. A
        # persistent problem in an early repo therefore meant the rest were never verified.
        #
        # The idiom matters. The obvious `if ! ( check; prune; repair ); then` is WRONG:
        # bash SUPPRESSES errexit inside a condition-context subshell, so prune and repair
        # would still run after a failed check, and a succeeding repair would mask the
        # failure entirely. `cmd || repo_failed=1` is the correct form -- errexit does not
        # fire when a failure is handled by `||`, and each command's status is captured
        # individually.
        #
        # BOTH operations are isolated. The first version of this block guarded only
        # `check`, leaving the `snapshots` listing carrying the exact bug described above
        # while these comments claimed the whole script was covered.
        failed_repos=""

        for fileset in ${attrNameList backups} ; do
          echo "=== $fileset ==="
          repo_failed=0
          case "$operation" in
            check)
              # Unlock any stale locks before starting check operations.
              # `|| true` is deliberate: this is best-effort stale-lock clearing, and a real
              # problem here resurfaces immediately as a check failure for the SAME repo,
              # which is then recorded by name. The accepted tradeoff is that an unlock
              # failure on a repo whose check then succeeds produces no signal at all.
              /run/current-system/sw/bin/restic-$fileset unlock || true
              if /run/current-system/sw/bin/restic-$fileset \
                   --retry-lock=1h check ; then
                # repair is gated on prune SUCCEEDING, not merely on check succeeding.
                # `restic repair snapshots` documents a dependency on a correct index
                # ("The command depends on a correct index, thus make sure to run
                # 'repair index' first!"), and a prune that fails partway can leave the
                # index disagreeing with the pack files. We deliberately do NOT pass
                # --forget, so repair only ADDS corrected snapshots and cannot delete the
                # originals -- but running it against an index prune just failed to rewrite
                # is still the wrong order of operations.
                if /run/current-system/sw/bin/restic-$fileset \
                     --retry-lock=1h prune ; then
                  /run/current-system/sw/bin/restic-$fileset \
                    --retry-lock=1h repair snapshots || repo_failed=1
                else
                  repo_failed=1
                  echo "PRUNE FAILED for $fileset -- skipping repair snapshots, which" \
                       "depends on an index that a failed prune may have left inconsistent."
                fi
              else
                repo_failed=1
                echo "CHECK FAILED for $fileset -- skipping prune and repair, because" \
                     "pruning a possibly-damaged repository can destroy recovery data."
              fi
              ;;
            snapshots)
              # Isolated for the same reason as check, and it matters MORE here than the
              # exit code suggests: this path feeds the "Restic Snapshots" section of the
              # daily logwatch report, and logwatch IGNORES the script's exit status
              # entirely -- logwatch.pl runs it as `open(TESTFILE, $Command . " |")` and
              # never checks close(), emitting whatever reached stdout (stderr is folded in
              # by its own `2>&1`). So the exit code is invisible downstream and the ONLY
              # signal is the text. Before this guard a failing repo truncated the section
              # at that repo with nothing saying the remaining ones were never listed.
              # The exit status is unchanged from the old behaviour (errexit already
              # aborted with 1), so nothing downstream regresses.
              /run/current-system/sw/bin/restic-$fileset snapshots --json \
                | ${pkgs.jq}/bin/jq -r 'sort_by(.time) | reverse | .[:4][] | .time' \
                || repo_failed=1
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

        # Fail LOUDLY and name the repos, so $SERVICE_RESULT reflects reality for the
        # restic-check timer. Note the NAMES travel by stdout only -- into the journal for
        # `check`, and into the daily report body for `snapshots`. The Prometheus alert
        # itself carries just "the check failed" plus a pointer to journalctl, because
        # restic_integrity_check_success is a single unlabelled gauge.
        if [ -n "$failed_repos" ]; then
          echo "FAILED REPOS:$failed_repos"
          exit 1
        fi
      '';
    };
}
