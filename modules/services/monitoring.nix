{
  config,
  lib,
  pkgs,
  ...
}:

let
  # ---------------------------------------------------------------------------
  # Backblaze B2 bucket table (daily logwatch section).
  #
  # Replaced the old "Restic Snapshots" section on 2026-08-19. That section
  # printed the last four snapshot timestamps for each of the ten repositories --
  # forty bare dates that answered "did a backup run" but never "how much am I
  # storing" or "which bucket has quietly stopped growing".
  #
  # The numbers are read from B2 itself rather than from restic's own accounting,
  # because restic's accounting does not measure the bucket. Both cheaper sources
  # were checked first and measured against a real listing on 2026-08-19:
  #
  #   - restic_repo_size_bytes (modules/monitoring/services/restic-metrics.nix,
  #     refreshed every 6h) runs 0.03%-5.6% LOW per bucket. `stats --mode
  #     raw-data` sums the lengths of REFERENCED blobs, so it counts neither pack
  #     header, index, snapshot and key objects nor anything still occupying the
  #     bucket that restic no longer references.
  #   - restic_last_snapshot_timestamp_seconds reports the last SNAPSHOT, which
  #     is not the last write to the bucket -- prune and check write too.
  #
  # Both remain good trend metrics. Neither is the bucket, and this section
  # claims to show the bucket.
  #
  # Cost of asking B2 directly, measured across all ten buckets: 16 seconds,
  # ~97k objects, ~100 list requests. One recursive listing per bucket yields the
  # byte total and the newest object time together, so freshness is free.
  # ---------------------------------------------------------------------------

  # Every restic repository on this host is an S3-compatible B2 URL shaped
  #   s3:<endpoint-host>/<bucket>
  # Parsed out of services.restic.backups rather than listed by hand. The
  # hand-maintained REPOSITORIES array in restic-metrics.nix is the cautionary
  # tale: "Public" was simply missing from it, so that repo had zero B2-side
  # coverage until a census caught it (see the note at restic-metrics.nix:19).
  # Deriving the list from the backups themselves makes that drift impossible.
  b2Buckets = lib.filter (b: b != null) (
    lib.mapAttrsToList (
      _name: backup:
      let
        parts = lib.splitString "/" (lib.removePrefix "s3:" backup.repository);
      in
      # Short-circuit order matters: `parts` must not be forced for a backup
      # that sets repositoryFile instead of repository, where it would be null.
      if
        backup.repository != null && lib.hasPrefix "s3:" backup.repository && builtins.length parts > 1
      then
        {
          endpoint = builtins.head parts;
          bucket = lib.concatStringsSep "/" (builtins.tail parts);
        }
      else
        null
    ) config.services.restic.backups
  );

  resticBucketTable = pkgs.writeShellApplication {
    name = "logwatch-b2-buckets";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      gnused
      rclone
    ];
    text = ''
      # The Backblaze application key reaches this script as a systemd
      # credential (LoadCredential= on logwatch.service, declared in
      # modules/services/monitoring.nix), so it is read by PID 1 into this unit's
      # private credential directory and never enters the environment that
      # logwatch's other custom services inherit -- which matters, because one of
      # them (ai-log-summary) ships log text to an LLM gateway.
      #
      # -s rather than -r: the unit pairs LoadCredential= with an empty
      # SetCredential= default, so a missing secret yields a zero-length file
      # instead of refusing to start the entire daily report.
      creds="''${CREDENTIALS_DIRECTORY:-/nonexistent}/aws-keys"
      if [ ! -s "$creds" ]; then
        echo "ERROR: B2 credentials unavailable -- bucket sizes were not collected."
        echo "       Expected credential 'aws-keys' sourced from /run/secrets/aws-keys."
        exit 1
      fi

      # `set -a` exports what the file defines (AWS_ACCESS_KEY_ID /
      # AWS_SECRET_ACCESS_KEY). rclone picks those up via env_auth=true in the
      # connection string below, so no key is ever passed as an argument where
      # ps(1) would expose it to every user on the host.
      set -a
      # shellcheck disable=SC1090
      . "$creds"
      set +a

      # NOT tidiness -- this prevents an interactive password prompt. johnw's
      # rclone config (/home/johnw/.config/rclone/rclone.conf) is
      # password-encrypted, so an rclone that finds it demands a configuration
      # password on stdin before doing anything. Verified 2026-08-19: the file
      # carries rclone's "# Encrypted rclone configuration File" marker and a
      # bare `rclone listremotes` against it prompts.
      #
      # Under logwatch the unit runs as root, where no rclone config exists
      # today, so the prompt would not fire there as things stand. It fires for
      # the case that actually matters: a human running this script by hand to
      # debug the section, which is the first thing anyone will do. It would
      # also fire under logwatch the moment a root rclone config appeared or
      # HOME changed. Pinning the config to /dev/null makes the script immune to
      # all three, and everything rclone needs is in the connection string and
      # the environment anyway.
      export RCLONE_CONFIG=/dev/null

      # Bound the whole section, not merely each call -- ten bounded calls are
      # still unbounded in aggregate. Measured 2026-08-19 over two full sweeps of
      # all ten buckets: 16s and 37s (~97k objects, ~100 list requests). B2
      # latency clearly varies by better than 2x run to run, so the budget is set
      # against the SLOWER observation: 180s is ~5x that, and 60s per bucket is
      # ~6x the worst single bucket. Deliberately generous, because what this
      # guards against is a slow B2, and cutting a healthy sweep short publishes
      # wrong sizes rather than no sizes.
      #
      # The deadline is tested when a bucket may START, so the residual worst
      # case is SECTION_BUDGET_SEC + PER_BUCKET_TIMEOUT_SEC = 240s -- the same
      # shape as the loop deadline in modules/lib/resticOperations.nix, and
      # harmless here because logwatch's own budget is 45min (TimeoutStartSec on
      # logwatch.service). Even the residual cannot crowd out the other sections.
      PER_BUCKET_TIMEOUT_SEC=60
      SECTION_BUDGET_SEC=180
      section_deadline=$(( $(date +%s) + SECTION_BUDGET_SEC ))

      total_bytes=0
      # How many buckets actually contributed to total_bytes. The TOTAL row is
      # meaningless without it -- see the coverage logic where it is printed.
      counted=0
      unreported=""
      # Kept separate from unreported: an empty bucket was successfully READ, it
      # is just an emergency. Lumping the two together would file "the repository
      # is gone" under the same heading as "B2 was slow".
      empty_buckets=""

      fmt_size() {
        # SI, not IEC. Backblaze bills and displays in powers of ten, so this
        # column matches what the B2 console shows rather than restic's GiB.
        #
        # --round=nearest is NOT decoration. numfmt defaults to round=from-zero,
        # which rounds AWAY from zero at the requested precision and therefore
        # overstates every single figure: the first rendering of this table
        # printed the 8.0014 GB Public bucket as "8.1GB" and the 1.609 TB total
        # as "1.7TB", a 5.7% overstatement on the number most likely to be read
        # as a billing estimate.
        numfmt --round=nearest --to=si --suffix=B --format='%.1f' "$1"
      }

      row() {
        printf '%-24s %10s  %s\n' "$1" "$2" "$3"
      }

      # rclone's stderr is CAPTURED, not discarded. It used to go to /dev/null,
      # which cost nothing on the happy path and everything on the one that
      # matters: a review run saw jwiegley-src report 6.5GB against a true
      # 15.7GB, with the newest-object time moving BACKWARD -- the signature of
      # a listing that stopped partway through the key space, since restic
      # writes index/ and snapshots/ objects last and they sort after data/.
      # That row was entirely plausible on its face. It was not reproducible and
      # may have been an artifact of that run's stubbed rclone, so it is NOT
      # recorded here as a live bug.
      #
      # What is recorded is that the guards below cannot catch it: `-eq 0` and
      # the numeric-shape test detect total failure, not partial. A byte-count
      # floor would only be a guess, so no threshold is imposed. Keeping stderr
      # is the cheap half of the fix -- it makes the next occurrence
      # DIAGNOSABLE instead of invisible, with no false positives.
      errfile=$(mktemp)
      trap 'rm -f "$errfile"' EXIT

      # Last non-blank stderr line, appended to an anomalous row. Truncated, and
      # anything shaped like a credential assignment is scrubbed first: this text
      # is emailed, and rclone is not obliged to keep secrets out of its errors.
      why_suffix() {
        local why
        why=$(sed -E 's/((key|secret|token|password)[A-Za-z_]*[[:space:]]*[=:][[:space:]]*)[^[:space:],;]+/\1[REDACTED]/Ig' \
                "$errfile" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 || true)
        if [ -n "$why" ]; then
          printf ' [%.160s]' "$why"
        fi
      }

      bucket_row() {
        local bucket="$1" endpoint="$2"
        local remaining cap out bytes newest

        remaining=$(( section_deadline - $(date +%s) ))
        if [ "$remaining" -le 0 ]; then
          unreported="$unreported $bucket"
          row "$bucket" "-" "not reached (section budget spent)"
          return 0
        fi
        cap=$PER_BUCKET_TIMEOUT_SEC
        if [ "$cap" -gt "$remaining" ]; then cap=$remaining; fi

        # Two flags here are load-bearing, and both were found by measurement
        # rather than by reading the manual:
        #
        #   --use-server-modtime -- without it rclone resolves each object's
        #     time from its x-amz-meta-mtime header, which costs a HEAD request
        #     PER OBJECT. Across ~97k objects that is ~97k B2 transactions in
        #     place of ~100 list calls.
        #
        #   --files-only -- without it rclone emits a synthetic row for every
        #     directory prefix (restic's data/00..data/ff and friends: 226 of
        #     them in the SMALLEST bucket) carrying size -1 and mtime "now".
        #     That understates the total and pins Last Updated to the moment the
        #     report ran, which is the worst kind of wrong answer because it
        #     looks entirely plausible -- every bucket appears freshly written.
        #     Verified against `rclone size`: with --files-only the byte totals
        #     agree exactly (Public: 8001422466 both ways).
        #
        # awk concatenates "" onto both sides of the time comparison to force
        # string context. An unset awk variable is both "" and 0, and the
        # timestamps begin with digits, so leaving it implicit invites a
        # numeric comparison on the first row.
        # --time-format is pinned rather than left to rclone's default. Two
        # things depend on the exact rendering and neither is obvious: the
        # column is sliced positionally (''${newest:0:16}), and the awk
        # comparison below relies on lexicographic order matching chronological
        # order. Both hold for this layout and both break silently if an rclone
        # release ever changes the default -- one renders garbage, the other
        # picks the wrong "newest". Asserting the format costs nothing.
        #
        # These times are LOCAL, and so is the OnCalendar of every restic timer
        # in modules/storage/backups.nix, so the column and the schedule are
        # directly comparable -- as of 2026-08-19 all ten rows land within
        # minutes of their configured time. Said explicitly because a UTC/local
        # mix-up has already caused one bad incident reconstruction on this
        # host; do not "normalise" this to UTC without changing that too.
        : >"$errfile"
        if out=$(timeout "$cap" rclone lsf \
                   ":s3,provider=Other,env_auth=true,endpoint=''${endpoint}:''${bucket}" \
                   --recursive --files-only --use-server-modtime \
                   --format st --separator '|' \
                   --time-format '2006-01-02 15:04:05' 2>"$errfile" \
                 | awk -F'|' '
                     { bytes += $1; if ($2 "" > newest "") newest = $2 }
                     END { printf "%d|%s\n", bytes, (newest == "" ? "(empty)" : newest) }
                   ')
        then
          IFS='|' read -r bytes newest <<<"$out"

          # A zero or unparseable byte count must never render as a plain
          # "0.0B" row. That is the failure shape this host keeps getting bitten
          # by: a monitoring path that breaks in a way which reads as a clean
          # result. "0.0B" in a size column does not read as "the instrument
          # broke" -- it reads as "the backup shrank", or it reads as nothing at
          # all, which is worse. Both cases below are therefore loud, and both
          # are named again in a summary line at the end of the section.
          #
          # This first guard is defence in depth, not a live path: the awk END
          # block above always emits `%d`, so `bytes` is numeric for any input
          # rclone can produce today, and a failing rclone is caught by pipefail
          # in the `if` instead. It is here because the hazard it covers is
          # invisible -- bash arithmetic treats an empty string as 0 without
          # complaint, so if that pipeline is ever changed to emit something
          # else, a malformed result would quietly drop the bucket from TOTAL
          # while still printing a plausible-looking row.
          if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
            unreported="$unreported $bucket"
            row "$bucket" "ERROR" "unparseable listing result"
            return 0
          fi

          # rclone exits 0 for a bucket that exists and holds nothing, so an
          # empty restic repository arrives here as a SUCCESS. It is not one: a
          # repo with zero objects means the backup is gone.
          if [ "$bytes" -eq 0 ]; then
            empty_buckets="$empty_buckets $bucket"
            row "$bucket" "EMPTY" "no objects found -- INVESTIGATE$(why_suffix)"
            return 0
          fi

          total_bytes=$(( total_bytes + bytes ))
          counted=$(( counted + 1 ))
          # Trim the seconds; the day and time-of-day are what identify which
          # scheduled backup last wrote here.
          row "$bucket" "$(fmt_size "$bytes")" "''${newest:0:16}"
        else
          unreported="$unreported $bucket"
          row "$bucket" "ERROR" "B2 listing failed or timed out$(why_suffix)"
        fi
      }

      row "Bucket" "Size on B2" "Last Updated"
      row "------------------------" "----------" "----------------"

      ${lib.concatMapStringsSep "\n" (
        r: "bucket_row ${lib.escapeShellArg r.bucket} ${lib.escapeShellArg r.endpoint}"
      ) b2Buckets}

      row "------------------------" "----------" "----------------"

      # The TOTAL must never be a bare "0.0B". Measured while testing the
      # failure path: with every bucket erroring, the naive version printed a
      # clean-looking "TOTAL (10 buckets)  0.0B" underneath ten ERROR rows --
      # the same reads-as-a-clean-result shape the per-bucket guards above
      # exist to kill, reintroduced at the one line most likely to be skimmed.
      # So the total states its own coverage, and prints no byte figure at all
      # when nothing could be read.
      if [ "$counted" -eq 0 ]; then
        row "TOTAL" "n/a" "no bucket could be read"
      elif [ "$counted" -lt ${toString (builtins.length b2Buckets)} ]; then
        row "TOTAL ($counted of ${toString (builtins.length b2Buckets)} buckets)" \
          "$(fmt_size "$total_bytes")" "INCOMPLETE -- see below"
      else
        printf '%-24s %10s\n' "TOTAL (${toString (builtins.length b2Buckets)} buckets)" \
          "$(fmt_size "$total_bytes")"
      fi

      # logwatch discards this script's exit status entirely -- logwatch.pl runs
      # it as `open(TESTFILE, $Command . " |")` and never checks close() -- so a
      # partial table has to announce itself in the TEXT or it is invisible to
      # the only reader this output has. The exit code is for anyone running the
      # script by hand.
      if [ -n "$empty_buckets" ]; then
        echo
        echo "EMPTY BUCKETS -- a restic repository is never legitimately empty." \
             "The listing SUCCEEDED and found nothing, so this is not a" \
             "reporting failure; check these immediately:$empty_buckets"
      fi

      if [ -n "$unreported" ]; then
        echo
        echo "NOT REPORTED (B2 listing failed, timed out, or was not reached):$unreported"
      fi

      if [ -n "$unreported" ] || [ -n "$empty_buckets" ]; then
        exit 1
      fi
    '';
  };

  zfsSnapshotScript = pkgs.writeShellApplication {
    name = "logwatch-zfs-snapshot";
    text = ''
      for fs in $(${pkgs.zfs}/bin/zfs list -H -o name -t filesystem -r); do
        ${pkgs.zfs}/bin/zfs list -H -o name -t snapshot -S creation -d 1 "$fs" | ${pkgs.coreutils}/bin/head -1
      done
    '';
  };

  databaseSizesScript = pkgs.writeShellApplication {
    name = "logwatch-database-sizes";
    runtimeInputs = [
      config.services.postgresql.package
      pkgs.coreutils
      pkgs.gawk
      pkgs.sudo
    ];
    text = ''
      echo "PostgreSQL Databases"
      echo "--------------------"
      sudo -u postgres psql -t -A -F '|' -c \
        "SELECT datname, pg_database_size(datname) as raw_size,
                pg_size_pretty(pg_database_size(datname)) as size
         FROM pg_database
         WHERE datistemplate = false
         ORDER BY pg_database_size(datname) DESC;" 2>/dev/null | \
      while IFS='|' read -r name _raw_size pretty_size; do
        printf "  %-20s %10s\n" "$name" "$pretty_size"
      done
      echo ""
      total=$(sudo -u postgres psql -t -A -c \
        "SELECT pg_size_pretty(sum(pg_database_size(datname)))
         FROM pg_database WHERE datistemplate = false;" 2>/dev/null)
      printf "  %-20s %10s\n" "TOTAL" "$total"
      echo ""

      echo "Time-Series Databases"
      echo "---------------------"
      prom_size=$(du -sh /var/lib/prometheus2/data/ 2>/dev/null | awk '{print $1}')
      prom_dr_size=$(du -sh /var/lib/prometheus2/disaster-recovery/ 2>/dev/null | awk '{print $1}')
      vm_size=$(du -sh /var/lib/private/victoriametrics/ 2>/dev/null | awk '{print $1}')
      printf "  %-20s %10s\n" "Prometheus TSDB" "''${prom_size:-N/A}"
      printf "  %-20s %10s\n" "Prometheus DR" "''${prom_dr_size:-N/A}"
      printf "  %-20s %10s\n" "VictoriaMetrics" "''${vm_size:-N/A}"
    '';
  };

  zpoolScript = pkgs.writeShellApplication {
    name = "logwatch-zpool";
    text = "${pkgs.zfs}/bin/zpool status";
  };

  systemctlFailedScript = pkgs.writeShellApplication {
    name = "logwatch-systemctl-failed";
    text = "${pkgs.systemd}/bin/systemctl --failed";
  };

  certificateValidationScript = pkgs.writeShellApplication {
    name = "logwatch-certificate-validation";
    runtimeInputs = with pkgs; [
      bash
      openssl
      coreutils
      gawk
      gnugrep
    ];
    text = ''
      /etc/nixos/certs/validate-certificates-concise.sh || true
    '';
  };

  # AI log analysis script (used by both logwatch and command-line)
  analyzeLogsScript = pkgs.writeShellApplication {
    name = "analyze-logs";
    runtimeInputs = with pkgs; [
      python3
      systemd
    ];
    text = ''
      # No API key is exported here on purpose. The host LLM gateway on
      # 127.0.0.1:4000 injects the upstream Authorization header itself (see
      # modules/services/hera-llm-proxy.nix), so a client-side key would be
      # overwritten anyway. log-summarizer.py only sets the header when
      # LLM_API_KEY is non-empty, so leaving it unset is the correct config.

      # Pass all arguments to the log summarizer
      exec ${pkgs.python3}/bin/python3 /etc/nixos/scripts/log-summarizer.py "$@"
    '';
  };

  # Wrapper for logwatch (quiet mode, suppress errors)
  logwatchAiScript = pkgs.writeShellApplication {
    name = "logwatch-ai-summary";
    runtimeInputs = [ analyzeLogsScript ];
    text = ''
      analyze-logs --quiet 2>/dev/null || true
    '';
  };
in
{
  # Bound the daily logwatch run. The upstream module (nixos-logwatch flake input) ships
  # TimeoutStartUSec=infinity, and logwatch's ai-log-summary custom service calls an LLM
  # through the host gateway with its OWN 2-hour budget (scripts/log-summarizer.py:308,
  # `self.timeout = 7200  # 2 hours (local LLM can be slow)`). Unbounded unit + 2h request
  # means a dead model backend hangs this job for two hours, daily, with nothing stopping it.
  #
  # Not hypothetical: during the hera outage on 2026-08-01 logwatch sat in activating/start
  # for 38+ minutes and was still climbing when ServiceStuckActivating caught it.
  #
  # 30 min is ~3.8x the worst observed real run (7m56s on 2026-07-31; 4m00s and 3m58s the two
  # days before), so a genuinely slow summarisation still completes. Deliberately generous:
  # TimeoutStartSec is ENFORCED, and setting a previously-ignored cap too tight has broken a
  # working unit on this host before -- see the RuntimeMaxSec regression.
  #
  # This bounds the UNIT regardless of what the script does. The 7200s request timeout in
  # log-summarizer.py is separately excessive and worth lowering, but that is a script change
  # and this is the general safety net.
  # Raised 30min -> 45min on 2026-08-03 at the operator's request, after the cap
  # was actually hit twice in four days (timed out 04:30 on Aug 1 and Aug 3;
  # completed in 3m45s on Aug 2 and 7m56s on Jul 31). The comment above still
  # holds -- 30 min WAS ~3.8x the worst observed run -- but the worst observed
  # run has since grown past it, because logwatch digests `range = "since 24
  # hours ago"` and journal volume is now ~800k entries/day.
  #
  # This is the safety net, not the fix. The volume itself is dominated by
  # container-user session churn (systemd + systemd-logind + sd-pam + o-bridge
  # ~= 17.3k entries/hour, 56% of the journal), created by
  # container-health-exporter.timer running systemd-run per rootless container
  # user every 120s. Lowering that cadence is the actual lever; see the note in
  # modules/monitoring/services/container-health-exporter.nix.
  systemd.services.logwatch.serviceConfig.TimeoutStartSec = "45min";

  # The "Backblaze B2 Buckets" section needs the B2 application key. It arrives
  # as a systemd credential so the value is read by PID 1 into this unit's
  # private credential directory, rather than via EnvironmentFile= which would
  # place it in the environment inherited by every other custom service logwatch
  # runs -- including ai-log-summary, which makes outbound HTTP calls.
  #
  # The empty SetCredential= is deliberate, not filler. systemd.exec(5): when
  # SetCredential= supplies a default, "not being able to retrieve the
  # credential from the path specified in LoadCredential= ... is not considered
  # fatal". Without it, a missing /run/secrets/aws-keys would fail the UNIT and
  # cost the entire daily report -- AI summary, failed services, certificates,
  # ZFS and all -- to report one absent section. With it, the empty credential
  # trips the `[ ! -s ]` guard in the script and only that section degrades, to
  # a named error.
  systemd.services.logwatch.serviceConfig.LoadCredential = "aws-keys:/run/secrets/aws-keys";
  systemd.services.logwatch.serviceConfig.SetCredential = "aws-keys:";

  services = {
    logwatch = {
      enable = true;
      range = "since 24 hours ago for those hours";
      mailto = "johnw@vulcan.lan";
      mailfrom = "logwatch@vulcan.lan";
      customServices = [
        {
          name = "ai-log-summary";
          title = "AI-Powered System Log Analysis";
          script = lib.getExe logwatchAiScript;
        }
        {
          name = "systemctl-failed";
          title = "Failed systemctl services";
          script = lib.getExe systemctlFailedScript;
        }
        { name = "sshd"; }
        { name = "sudo"; }
        # { name = "fail2ban"; }
        { name = "kernel"; }
        # { name = "audit"; }
        {
          name = "certificate-validation";
          title = "Certificate Validation Report";
          script = lib.getExe certificateValidationScript;
        }
        {
          name = "database-sizes";
          title = "Database Storage Sizes";
          script = lib.getExe databaseSizesScript;
        }
        {
          name = "zpool";
          title = "ZFS Pool Status";
          script = lib.getExe zpoolScript;
        }
        {
          name = "zfs-snapshot";
          title = "ZFS Snapshots";
          script = lib.getExe zfsSnapshotScript;
        }
        {
          name = "restic";
          title = "Backblaze B2 Buckets";
          script = lib.getExe resticBucketTable;
        }
      ];
    };
  };

  # Create history directory for AI analysis deduplication (d = create only, never empties)
  systemd.tmpfiles.rules = [
    "d /var/log/logwatch-ai 0755 root root -"
  ];

  # Make analyze-logs available in PATH
  environment.systemPackages = [ analyzeLogsScript ];
}
