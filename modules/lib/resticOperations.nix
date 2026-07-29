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

        # ---------------------------------------------------------------------------------
        # ROTATING DATA VERIFICATION (added 2026-07-29).
        #
        # A plain `restic check` verifies STRUCTURE only -- it confirms the index and
        # metadata are consistent but never reads the pack payloads, so silent bit-rot in
        # the actual backup data is invisible to it. Measured: last structure-only run
        # (2026-07-27) took 6m42s and pulled 1.6 GB for all nine repos.
        #
        # `--read-data-subset=P/52` reads part P of 52, so each week verifies ~1.92% of
        # every repo and the WHOLE repository is covered once a year -- deterministically.
        # A percentage subset ("2%") picks a RANDOM subset each week instead, which
        # re-reads some packs and may never touch others, so n/t is the better shape for
        # the same cost. Across 1.473 TB of repos that is ~28.3 GB of B2 downloads a week
        # (~113 GB/month), against the 1.6 GB/week the structure check already pulls.
        #
        # This runs as a SECOND pass rather than by adding the flag to the existing check.
        # The flag would fuse structure and data verification into one command, so an
        # exhausted data budget would take the structure check down with it. Two passes
        # cost ~7 extra minutes total and keep structure verification unconditional.
        READ_DATA_PART=$(( ( 10#$(${pkgs.coreutils}/bin/date +%V) - 1 ) % 52 + 1 ))
        # ISO weeks run 01..53; folding 53 back onto part 1 keeps the divisor at 52 rather
        # than leaving one part unreachable. Verified: week 53 -> part 1, week 52 -> 52.

        # Budgets. The systemd RuntimeMaxSec=4h backstop is a HARD kill that would abort
        # the loop mid-repo and destroy exactly the per-repo accounting established above,
        # so these keep it a genuine last resort rather than an expected outcome:
        #   - a 3h global budget, leaving an hour of headroom under RuntimeMaxSec
        #   - a 1h per-repo cap so one hung repo cannot consume the whole budget
        #     (the largest slice, Photos at 7.71 GB, needs ~32 min at the 4 MB/s implied
        #      by the last run's 1.6 GB / 6m42s)
        #   - a 5m floor below which a repo is reported as skipped instead of started
        # Expected total is ~2h at that throughput, i.e. 1.5x inside the 3h budget.
        READ_DATA_BUDGET_SEC=10800
        READ_DATA_REPO_MAX_SEC=3600
        READ_DATA_MIN_SEC=300
        read_data_deadline=$(( $(${pkgs.coreutils}/bin/date +%s) + READ_DATA_BUDGET_SEC ))
        read_data_skipped=""
        # Counters feed a textfile metric below. Without them, a week where the budget runs
        # out reports overall SUCCESS while most repos went data-unverified -- visible only
        # as a journal line nobody reads. That is precisely the silent-degradation shape
        # this work exists to remove, so coverage is measured, not merely logged.
        #
        # Invariant: verified + skipped + failed == total, for the `check` operation. A repo
        # is counted in exactly one bucket -- a data error is NOT a skip, and a repo whose
        # structure check failed never reaches the data pass and so lands in none of the
        # three (it is short of `total` by construction, which is why `total` is published
        # rather than assumed to be 9).
        read_data_verified_count=0
        read_data_skipped_count=0
        read_data_failed_count=0
        repo_count=0

        for fileset in ${attrNameList backups} ; do
          echo "=== $fileset ==="
          repo_failed=0
          repo_count=$(( repo_count + 1 ))
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

                # Rotating data verification. Gated on the STRUCTURE check passing (reading
                # payloads from a repo whose index is already known-bad tells us nothing)
                # but deliberately NOT on prune: this pass is read-only and is the only
                # thing here that can detect bit-rot, so a prune problem must not cancel it.
                read_data_remaining=$(( read_data_deadline - $(${pkgs.coreutils}/bin/date +%s) ))
                read_data_cap=$read_data_remaining
                if [ "$read_data_cap" -gt "$READ_DATA_REPO_MAX_SEC" ]; then
                  read_data_cap=$READ_DATA_REPO_MAX_SEC
                fi
                if [ "$read_data_remaining" -lt "$READ_DATA_MIN_SEC" ]; then
                  # Named, not silent: incomplete coverage is a real gap and the operator
                  # must be able to see WHICH repos went unverified this week.
                  echo "READ-DATA SKIPPED for $fileset -- only ''${read_data_remaining}s of" \
                       "the ''${READ_DATA_BUDGET_SEC}s budget left. Structure check passed;" \
                       "pack payloads were NOT read this week."
                  read_data_skipped="$read_data_skipped $fileset"
                  read_data_skipped_count=$(( read_data_skipped_count + 1 ))
                else
                  echo "Reading data subset $READ_DATA_PART/52 for $fileset" \
                       "(cap ''${read_data_cap}s)"
                  read_data_rc=0
                  ${pkgs.coreutils}/bin/timeout "$read_data_cap" \
                    /run/current-system/sw/bin/restic-$fileset \
                      --retry-lock=1h check --read-data-subset="$READ_DATA_PART/52" \
                    || read_data_rc=$?
                  # Severity split. 124 is timeout(1)'s "deadline hit" -- that means we ran
                  # out of budget, NOT that the data is bad, so it must not page. Any other
                  # non-zero status is restic reporting an actual pack/blob error, which IS
                  # bit-rot on a backup and must fail the unit.
                  if [ "$read_data_rc" -eq 0 ]; then
                    read_data_verified_count=$(( read_data_verified_count + 1 ))
                  elif [ "$read_data_rc" -eq 124 ]; then
                    echo "READ-DATA TIMED OUT for $fileset after ''${read_data_cap}s --" \
                         "coverage incomplete this week, but this is a budget outcome," \
                         "not a data error, so it does not fail the run."
                    read_data_skipped="$read_data_skipped $fileset"
                    read_data_skipped_count=$(( read_data_skipped_count + 1 ))
                  elif [ "$read_data_rc" -ne 0 ]; then
                    repo_failed=1
                    read_data_failed_count=$(( read_data_failed_count + 1 ))
                    echo "READ-DATA FAILED for $fileset (exit $read_data_rc) -- restic" \
                         "found an error while reading pack payloads. This is the bit-rot" \
                         "signal; the structure check alone would never have caught it."
                  fi
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

        # Incomplete data coverage is reported but deliberately does NOT fail the run: it
        # means we ran out of budget, not that a backup is bad. It still has to be visible,
        # because "the check passed" would otherwise imply coverage it did not achieve.
        if [ -n "$read_data_skipped" ]; then
          echo "READ-DATA COVERAGE INCOMPLETE for part $READ_DATA_PART/52:$read_data_skipped"
        fi

        # Publish coverage as metrics, so degradation is ALERTABLE and not just a journal
        # line. restic_integrity_check_success cannot carry this: it is one unlabelled gauge
        # that says only whether the run exited 0, and a run where the budget expired exits 0
        # having verified almost no data. Only written for `check` -- the `snapshots` path
        # does no verification and must not overwrite these with zeros.
        #
        # A failed write is reported but does NOT fail the run: refusing to verify backups
        # because a metrics file could not be written is the wrong severity. Persistent
        # failure surfaces instead through the timestamp going stale, which is what
        # ResticReadDataStale watches.
        if [ "$operation" = "check" ]; then
          rd_file=/var/lib/prometheus-node-exporter-textfiles/restic_read_data.prom
          rd_tmp="$rd_file.tmp"
          if {
            echo "# HELP restic_read_data_part Which 1/52 slice of each repo was read this run"
            echo "# TYPE restic_read_data_part gauge"
            echo "restic_read_data_part $READ_DATA_PART"
            echo "# HELP restic_read_data_repos_verified Repos whose data subset was fully read"
            echo "# TYPE restic_read_data_repos_verified gauge"
            echo "restic_read_data_repos_verified $read_data_verified_count"
            echo "# HELP restic_read_data_repos_skipped Repos left data-unverified (budget/timeout)"
            echo "# TYPE restic_read_data_repos_skipped gauge"
            echo "restic_read_data_repos_skipped $read_data_skipped_count"
            echo "# HELP restic_read_data_repos_failed Repos where restic reported a data error"
            echo "# TYPE restic_read_data_repos_failed gauge"
            echo "restic_read_data_repos_failed $read_data_failed_count"
            echo "# HELP restic_read_data_repos_total Repos visited this run"
            echo "# TYPE restic_read_data_repos_total gauge"
            echo "restic_read_data_repos_total $repo_count"
            echo "# HELP restic_read_data_timestamp_seconds Unix time this run finished"
            echo "# TYPE restic_read_data_timestamp_seconds gauge"
            echo "restic_read_data_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
          } > "$rd_tmp" && ${pkgs.coreutils}/bin/mv "$rd_tmp" "$rd_file"; then
            ${pkgs.coreutils}/bin/chmod 644 "$rd_file" || true
          else
            echo "WARNING: could not write $rd_file -- read-data coverage will go stale."
          fi
        fi

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
