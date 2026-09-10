{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  promFile = "${textfileDir}/dovecot_archive.prom";

  # Mailbox maintenance, one entry per rule. Kept as data rather than inline
  # commands so the metrics, the logging and the operations cannot drift apart.
  #
  # DATE FIELD IS LOAD-BEARING -- read this before adding a rule:
  #
  #   SENTBEFORE  matches on the Date: header, i.e. when the message was WRITTEN.
  #   SAVEDBEFORE matches on when the message was STORED IN THIS MAILBOX.
  #
  # For the two `move` rules either would be defensible, because a move is
  # reversible and the sent date is what a human means by "old mail".
  #
  # For the Trash rule the choice is not cosmetic, it decides what gets deleted
  # forever. Measured on 2026-09-10, against the same 10,488-message Trash:
  #
  #     SENTBEFORE 365d   -> 9276 messages
  #     SAVEDBEFORE 365d  ->    0 messages
  #
  # SENTBEFORE would have permanently destroyed 9,276 messages on its first run,
  # including anything deleted yesterday that merely happened to be a year old --
  # which is the opposite of "drop Trash items after one year". SAVEDBEFORE is the
  # only correct reading of a retention period on a wastebasket: one year SINCE
  # DELETION. Do not "make it consistent" with the rules above.
  rules = [
    {
      step = "inbox_archive";
      desc = "INBOX -> Archive (sent >365d ago)";
      mailbox = "INBOX";
      criteria = "SENTBEFORE 365d";
      action = "move";
      dest = "Archive";
    }
    {
      step = "spam_archive";
      desc = "Spam -> SpamArchive (sent >30d ago)";
      mailbox = "Spam";
      criteria = "SENTBEFORE 30d";
      action = "move";
      dest = "SpamArchive";
    }
    {
      step = "trash_expire";
      desc = "Trash -> deleted (in Trash >365d)";
      mailbox = "Trash";
      criteria = "SAVEDBEFORE 365d";
      action = "expunge";
      dest = null;
    }
  ];

  doveadm = "${pkgs.dovecot}/bin/doveadm";

  mkStep =
    r:
    let
      cmd =
        if r.action == "move" then
          "${doveadm} move -u johnw ${lib.escapeShellArg r.dest} mailbox ${lib.escapeShellArg r.mailbox} ${r.criteria}"
        else
          "${doveadm} expunge -u johnw mailbox ${lib.escapeShellArg r.mailbox} ${r.criteria}";
    in
    ''
      run_step ${lib.escapeShellArg r.step} ${lib.escapeShellArg r.desc} \
        ${lib.escapeShellArg r.mailbox} ${lib.escapeShellArg r.criteria} \
        ${cmd}
    '';

  dovecotArchiveScript = pkgs.writeShellScript "dovecot-archive" ''
    # NOT `set -e`. This is deliberate and is the fix for a real defect.
    #
    # The previous version set `-euo pipefail` and then captured `exit_code=$?`
    # after the doveadm calls to branch on success. Under `set -e` a failing
    # doveadm aborts the script before reaching that line, so the branch could
    # only ever observe 0 and its ERROR arm was unreachable -- the script could
    # not report the one thing it tried to report.
    #
    # `set -e` also made the rules interdependent: a failure archiving INBOX
    # skipped Spam archiving entirely, even though they touch different mailboxes
    # and have no relationship to each other. These are independent janitorial
    # operations, so one failing must not cancel the others.
    #
    # So: no `-e`, each step checked explicitly, every step always attempted, and
    # a non-zero exit at the end if any of them failed. `-u` and `pipefail` are
    # kept -- neither causes the early-abort problem and both catch real bugs.
    set -uo pipefail

    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }

    failed=0
    declare -A step_ok
    declare -A step_count

    # Counts the matching messages BEFORE acting, so the metric reports what this
    # run actually did rather than what is left over. The search uses the same
    # criteria as the operation, so the two cannot disagree.
    run_step() {
      local step="$1" desc="$2" mailbox="$3" criteria="$4"
      shift 4

      local n
      # shellcheck disable=SC2086
      n=$(${doveadm} search -u johnw mailbox "$mailbox" $criteria 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
      if [ -z "$n" ]; then n=0; fi

      if [ "$n" -eq 0 ]; then
        log "$desc: nothing to do"
        step_ok[$step]=1
        step_count[$step]=0
        return 0
      fi

      log "$desc: $n message(s) match"
      if "$@"; then
        log "$desc: OK ($n message(s))"
        step_ok[$step]=1
        step_count[$step]=$n
      else
        local rc=$?
        log "ERROR: $desc failed (exit $rc)"
        step_ok[$step]=0
        step_count[$step]=0
        failed=1
      fi
    }

    log "Starting Dovecot mailbox maintenance"

    ${lib.concatMapStrings mkStep rules}

    # ---- metrics -----------------------------------------------------------
    #
    # A last-success TIMESTAMP rather than a "did it work" boolean, because a
    # boolean cannot distinguish "failed" from "has not run at all": if the timer
    # stops, nothing rewrites this file and a boolean stays frozen at 1 forever,
    # reading as health. A timestamp is self-invalidating -- time() keeps moving
    # while the value does not -- so the single alert on it catches BOTH a stopped
    # timer and a job that runs and fails. That is why this collector is
    # deliberately not on the Daily staleness allowlist in meta-monitoring.yaml:
    # it carries its own last-success triad, which is the documented reason a
    # collector may stay unlisted, and the 14d UnclassifiedStale backstop still
    # covers it automatically.
    #
    # On failure the PREVIOUS last-success value is carried forward, never reset
    # and never omitted. Omitting it would make the series disappear, and an
    # absent series cannot fire a `time() - metric > threshold` comparison -- the
    # failure would silence the alarm instead of raising it.
    now=$(date +%s)
    prev_success=$(${pkgs.gnugrep}/bin/grep -oP '^dovecot_archive_last_success_timestamp_seconds \K[0-9]+' ${promFile} 2>/dev/null | ${pkgs.coreutils}/bin/tail -1 || true)
    if [ "$failed" -eq 0 ]; then
      last_success=$now
    else
      last_success=''${prev_success:-0}
    fi

    tmp=$(${pkgs.coreutils}/bin/mktemp ${promFile}.XXXXXX)
    {
      echo "# HELP dovecot_archive_run_timestamp_seconds Unix time of the last run, successful or not"
      echo "# TYPE dovecot_archive_run_timestamp_seconds gauge"
      echo "dovecot_archive_run_timestamp_seconds $now"
      echo "# HELP dovecot_archive_last_success_timestamp_seconds Unix time of the last run in which EVERY step succeeded"
      echo "# TYPE dovecot_archive_last_success_timestamp_seconds gauge"
      echo "dovecot_archive_last_success_timestamp_seconds $last_success"
      echo "# HELP dovecot_archive_step_ok 1 if this maintenance step succeeded on the last run"
      echo "# TYPE dovecot_archive_step_ok gauge"
      for s in "''${!step_ok[@]}"; do
        echo "dovecot_archive_step_ok{step=\"$s\"} ''${step_ok[$s]}"
      done
      echo "# HELP dovecot_archive_messages_processed Messages moved or expunged by this step on the last run"
      echo "# TYPE dovecot_archive_messages_processed gauge"
      for s in "''${!step_count[@]}"; do
        echo "dovecot_archive_messages_processed{step=\"$s\"} ''${step_count[$s]}"
      done
    } > "$tmp"
    ${pkgs.coreutils}/bin/chmod 644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" ${promFile}

    if [ "$failed" -eq 0 ]; then
      log "Mailbox maintenance completed successfully"
    else
      log "ERROR: one or more maintenance steps failed"
    fi
    exit $failed
  '';
in
{
  systemd = {
    services.dovecot-archive = {
      description = "Archive old mail and expire Trash (Dovecot mailbox maintenance)";
      after = [ "dovecot2.service" ];
      requires = [ "dovecot2.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = dovecotArchiveScript;

        # Needs to write its own .prom. textfileDir is mode 1777 (sticky), so a
        # DynamicUser would not be able to rename(2) over the previous run's file.
        ReadWritePaths = [ textfileDir ];

        PrivateTmp = true;
        NoNewPrivileges = true;

        TimeoutStartSec = "10m";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    timers.dovecot-archive = {
      description = "Timer for daily mailbox maintenance";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "03:00";
        Persistent = true;
        Unit = "dovecot-archive.service";
      };
    };
  };

  assertions = [
    {
      assertion = config.services.dovecot2.enable;
      message = "Dovecot archive requires services.dovecot2.enable = true";
    }
  ];
}
