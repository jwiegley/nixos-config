{
  config,
  lib,
  pkgs,
  ...
}:

# AIDE (Advanced Intrusion Detection Environment)
# File integrity monitoring for critical system files and backups
#
# This module configures AIDE to monitor:
# - System binaries and libraries
# - SSH keys and configuration files
# - SOPS secrets configuration
#
# It does NOT monitor the backup directories: /tank/Backups/Images,
# /tank/Backups/Messages and /tank/Backups/PostgreSQL are excluded outright by
# `!` rules below (a recursive negative rule adds nothing at all to the AIDE
# database), so their integrity is covered by ZFS scrub/snapshots, not AIDE.

{
  # Install AIDE package
  environment.systemPackages = with pkgs; [
    aide
  ];

  # AIDE configuration file
  environment.etc."aide.conf".text = ''
    # AIDE Configuration
    # Database paths
    database_in=file:/var/lib/aide/aide.db
    database_out=file:/var/lib/aide/aide.db.new
    database_new=file:/var/lib/aide/aide.db.new

    # Report configuration
    report_url=stdout

    # Logging level (error, warning, notice, info, debug)
    log_level=notice

    # Report detail level
    report_level=changed_attributes
    report_detailed_init=yes
    report_base16=no
    report_quiet=no
    report_append=no
    report_summarize_changes=yes

    # Custom rule definitions
    # R = Read-only files (permissions + inode + size + checksums)
    # L = Log files (growing, permissions may change)
    # E = Empty directories
    # > = Growing log files
    # N = Ignore everything (for exclusions)

    # Comprehensive monitoring for critical files
    # Using modern hash algorithms (sha256+sha512) - removed deprecated md5, rmd160, tiger
    CRITICAL = p+i+n+u+g+s+b+m+c+sha256+sha512

    # Read-only files (no changes expected)
    READONLY = p+i+n+u+g+s+b+m+c+sha256

    # Configuration files (may change, but we want to know)
    CONFIG = p+i+n+u+g+s+b+m+c+sha256

    # Immutable backups (should NEVER change)
    # Note: For multi-TB directories, we only monitor metadata, not file contents
    # Use ZFS snapshots for content integrity verification
    IMMUTABLE = p+i+n+u+g+s+b+m+c+sha256+sha512

    # Log files (can grow, but structure shouldn't change)
    LOGS = p+i+n+u+g+S

    # Directories only
    DIRONLY = p+i+n+u+g

    # ===== CRITICAL SYSTEM FILES =====

    # System binaries (should be read-only)
    /bin READONLY
    /sbin READONLY
    /usr/bin READONLY
    /usr/sbin READONLY

    # System libraries
    /lib READONLY
    /lib64 READONLY
    /usr/lib READONLY
    /usr/lib64 READONLY

    # NixOS-specific
    /run/current-system READONLY
    /nix/var/nix/profiles/system READONLY

    # Boot files
    /boot CRITICAL

    # ===== SSH AND SECURITY =====

    # SSH keys and configuration
    /etc/ssh CRITICAL
    /root/.ssh CRITICAL

    # SOPS configuration
    /etc/nixos/secrets.yaml CONFIG
    # Exclude private age keys (should never be committed)
    !/etc/nixos/.*.age$

    # ===== CRITICAL BACKUPS (IMMUTABLE) =====

    # Images backup directory (2.1TB) - Monitor directory metadata only
    # File content integrity verified via ZFS scrub and snapshots
    !/tank/Backups/Images

    # Messages backup directory (109GB) - Monitor directory metadata only
    # File content integrity verified via ZFS scrub and snapshots
    !/tank/Backups/Messages

    # PostgreSQL backups - Excluded to avoid daily alerts from automated backups
    # Backup integrity verified via daily backup service monitoring
    !/tank/Backups/PostgreSQL

    # ===== CONFIGURATION FILES =====

    # NixOS configuration
    /etc/nixos CONFIG
    # Exclude .git directory
    !/etc/nixos/\.git
    # Exclude build results
    !/etc/nixos/result
    # Exclude build lock file
    !/etc/nixos/\.nixos-build
    # Exclude the obr cache. `.obr/` is a PER-MACHINE cache -- a SQLite database
    # plus history snapshots -- that obr rewrites on essentially every command,
    # and it self-ignores in git for exactly that reason. It is not configuration
    # and its integrity is not meaningful.
    #
    # Measured 2026-08-16: the 00:24 aide-check reported 12 added and 11 changed
    # entries, and ALL TWELVE additions were .obr/history/PLAN.*.org snapshots
    # plus their .meta.json siblings, with obr.db, obr.db-wal, last-touched and
    # merge.base.jsonl among the changes. So a routine issue-tracking session --
    # the very thing that happens during every health cycle -- was enough to
    # raise AideChangesDetected.
    #
    # That is the failure this module already warns about in the aide-update
    # note: an alert that is permanently on "is no control at all". The
    # post-rebuild re-baseline cannot help here, because the churn is not tied to
    # rebuilds; it happens whenever obr runs. Real integrity changes elsewhere
    # under /etc/nixos are still caught -- the same check also correctly flagged
    # docs/PLAN.org and modules/services/databases.nix, which were genuine edits.
    !/etc/nixos/\.obr

    # System configuration
    /etc/systemd CONFIG
    /etc/security CONFIG

    # ===== CROWN-JEWEL MUTABLE CONFIG =====
    # Home Assistant hand-edited YAML + Node-RED flows.json are high-value
    # config artifacts that change OUTSIDE a nixos-rebuild (HA UI / NR deploy).
    # AIDE gives the broad daily heads-up here; the per-file deploy-window
    # sharpshooter is config-drift-exporter.nix (config_file_drift). We watch
    # ONLY the human-authored YAML and the flows file — NEVER the churning,
    # token-bearing .storage/ tree or runtime state.
    /var/lib/hass/configuration.yaml CONFIG
    /var/lib/hass/automations.yaml CONFIG
    /var/lib/hass/scripts.yaml CONFIG
    /var/lib/hass/scenes.yaml CONFIG
    /var/lib/node-red/flows.json CONFIG

    # Exclude everything else under these dirs (constantly-churning runtime
    # state, OAuth/refresh tokens in .storage, logs, deps). The explicit file
    # rules above still apply; these negations cover the siblings.
    !/var/lib/hass/\.storage
    !/var/lib/hass/home-assistant_v2\.db
    !/var/lib/hass/home-assistant\.log
    !/var/lib/hass/deps
    !/var/lib/hass/tts
    !/var/lib/node-red/\.flows\.json\.backup
    !/var/lib/node-red/node_modules
    !/var/lib/node-red/\.config
    !/var/lib/node-red/lib

    # ===== EXCLUSIONS =====

    # Temporary files
    !/tmp
    !/var/tmp
    !/run

    # Log directories (monitored separately)
    !/var/log

    # Proc and sys
    !/proc
    !/sys
    !/dev

    # Nix store changes frequently during updates
    !/nix/store

    # Cache and transient data
    !/var/cache
    !/home/.*/\.cache
    !/root/\.cache

    # Browser and application caches
    !/\.mozilla
    !/\.config/google-chrome

    # ZFS snapshots
    !/tank/\.zfs
  '';

  # Create necessary directories
  systemd.tmpfiles.rules = [
    "d /var/lib/aide 0700 root root -"
    "d /var/log/aide 0755 root root -"
  ];

  # AIDE initialization service (run once to create initial database)
  systemd.services.aide-init = {
    description = "Initialize AIDE database";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.aide}/bin/aide --init";
      ExecStartPost = "${pkgs.coreutils}/bin/mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db";
      RemainAfterExit = true;
    };
  };

  # AIDE check service (manual or timer-triggered)
  systemd.services.aide-check = {
    description = "AIDE file integrity check";
    after = [ "aide-init.service" ];
    requires = [ "aide-init.service" ];

    serviceConfig = {
      Type = "oneshot";
      # SINGLE SOURCE OF TRUTH for every check-derived AIDE metric.
      #
      # Before 2026-07-29 this was a bare `aide --check` and the metrics were
      # computed TWICE, independently, from TWO separate full-filesystem walks:
      #   * aide-metrics.nix parsed its OWN `aide --check` into aide.prom
      #     (aide_check_status, aide_added/removed/changed_files, aide_total_entries)
      #   * this unit's ExecStopPost derived aide_changes_detected from
      #     $EXIT_STATUS into aide_result.prom
      # The two disagreed live (aide_check_status=0 while aide_changes_detected=1
      # and aide_changed_files=71 in the SAME scrape) because aide-metrics.nix
      # used the shape `OUT=$(aide --check || true); EC=$?` — the `|| true` makes
      # the command substitution succeed, so `$?` is ALWAYS 0. aide_check_status
      # therefore had a 30-day maximum of 0, which made both AIDEChangesDetected
      # and AIDECheckError structurally unfirable. A file-integrity control that
      # reports two contradictory answers is worse than none.
      #
      # Now ONE walk produces both the parsed counts AND the real exit code, and
      # ONE emitter writes them all to aide_result.prom. `set +e` around a bare
      # assignment (no `||`) preserves the true exit status.
      #
      # aide_database_exists / aide_database_age_seconds are DELIBERATELY NOT
      # emitted here: they are the only dead-man for "aide-check never ran at
      # all", so they keep their own independent timer and their own file
      # (aide.prom, aide-metrics.nix). aide*.prom is in NEITHER
      # TextfileCollectorStale tier (meta-monitoring.yaml:324,336), so that
      # independence is the only thing standing between a dead check and silence.
      # (aide.prom mtime IS watched by nagios-tier1-mirror.nix:263 at 26h/50h.)
      #
      # COUNTS/BOOLEANS/TIMESTAMPS ONLY in the .prom — never AIDE report lines
      # or paths. The full report still goes to the journal (report_url=stdout,
      # see the aide.conf above: there is NO report file on disk to parse).
      ExecStart = "${pkgs.writeShellScript "aide-check-emit" ''
        set -u
        DIR=/var/lib/prometheus-node-exporter-textfiles
        OUT="$DIR/aide_result.prom"
        TMP="$OUT.$$"

        # ---- the one and only walk -------------------------------------------
        # NOTE the shape: `set +e`, a bare assignment, then `EC=$?`. Do NOT
        # reintroduce `|| true` — that is exactly what destroyed the exit code.
        set +e
        REPORT=$(${pkgs.aide}/bin/aide --check 2>&1)
        EC=$?
        # Re-emit the report so `journalctl -u aide-check` still shows it.
        # BUILTIN printf, deliberately -- do NOT add a ${pkgs.coreutils}/bin/ prefix to the two
        # whole-report printfs. An external printf receives the entire AIDE report as ONE argv
        # element and dies with E2BIG past MAX_ARG_STRLEN (32 * PAGESIZE = 524288 bytes here,
        # but only 131072 on a 4K-page host). At roughly 338 bytes per changed entry that is
        # breached around 1,550 of the 3,189 watched entries. The failure is silent in the worst
        # way: the report vanishes from the journal AND every parsed count zeroes while
        # aide_check_status still reads 1 -- "changes detected, 0 added, 0 removed, 0 changed"
        # with no report to consult. That is exactly the large-change case this control exists
        # to catch. The shell builtin has no argv limit. The short .prom printfs below are fine.
        printf '%s\n' "$REPORT"

        # ---- parse the summary block -----------------------------------------
        # AIDE 0.19.2 prints "  Total number of entries:<tab>N"; older releases
        # printed "Number of entries:". Match case-insensitively on the common
        # substring so a package bump cannot silently zero the gauge (the old
        # case-sensitive "Number of entries:" grep is why aide_total_entries read
        # 0 live while its 30-day max was 3163).
        num() {
          case "$1" in
            "" | *[!0-9]*) ${pkgs.coreutils}/bin/printf '0\n' ;;
            *)             ${pkgs.coreutils}/bin/printf '%s\n' "$1" ;;
          esac
        }
        field() {
          printf '%s\n' "$REPORT" \
            | ${pkgs.gnugrep}/bin/grep -i -m1 -e "$1" \
            | ${pkgs.gawk}/bin/awk '{print $NF}'
        }
        # The two-space anchor keeps us inside the Summary block: the per-file
        # detail section further down repeats "Changed entries:" unindented and
        # with no number.
        TOTAL=$(num "$(field 'number of entries:')")
        ADDED=$(num "$(field '^  Added entries:')")
        REMOVED=$(num "$(field '^  Removed entries:')")
        CHANGED=$(num "$(field '^  Changed entries:')")

        # ---- authoritative status from the REAL exit code --------------------
        # 0 = clean, 1-7 = additive change bits (1 new, 2 removed, 4 changed),
        # 14+ = genuine error (config/database unreadable, etc).
        if [ "$EC" -eq 0 ]; then
          STATUS=0; CHANGES=0
        elif [ "$EC" -ge 1 ] && [ "$EC" -le 7 ]; then
          STATUS=1; CHANGES=1
        else
          STATUS=2; CHANGES=0
        fi

        [ -d "$DIR" ] || ${pkgs.coreutils}/bin/mkdir -p "$DIR"
        {
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_check_status Status of last AIDE check (0=OK, 1=changes, 2=error)'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_check_status gauge'
          ${pkgs.coreutils}/bin/printf 'aide_check_status %s\n' "$STATUS"
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_changes_detected 1 if the last aide --check reported changes (exit 1-7), 0 otherwise'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_changes_detected gauge'
          ${pkgs.coreutils}/bin/printf 'aide_changes_detected %s\n' "$CHANGES"
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_added_files Number of files added since last database update'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_added_files gauge'
          ${pkgs.coreutils}/bin/printf 'aide_added_files %s\n' "$ADDED"
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_removed_files Number of files removed since last database update'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_removed_files gauge'
          ${pkgs.coreutils}/bin/printf 'aide_removed_files %s\n' "$REMOVED"
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_changed_files Number of files changed since last database update'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_changed_files gauge'
          ${pkgs.coreutils}/bin/printf 'aide_changed_files %s\n' "$CHANGED"
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_total_entries Total number of database entries'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_total_entries gauge'
          ${pkgs.coreutils}/bin/printf 'aide_total_entries %s\n' "$TOTAL"
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_last_check_timestamp_seconds Unix time the last aide --check completed'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_last_check_timestamp_seconds gauge'
          ${pkgs.coreutils}/bin/printf 'aide_last_check_timestamp_seconds %s\n' "$(${pkgs.coreutils}/bin/date +%s)"
        } > "$TMP"
        ${pkgs.coreutils}/bin/chmod 0644 "$TMP"
        ${pkgs.coreutils}/bin/mv -f "$TMP" "$OUT"

        # Propagate the real code so SuccessExitStatus below still absorbs
        # 1-7 (changes are informational) while a genuine 14+ error fails the
        # unit and reaches SystemdServiceFailed as well as AIDECheckError.
        exit "$EC"
      ''}";
      # AIDE exit codes: 0=no changes, 1-7=changes detected (all informational)
      # Treat changes as success so systemd doesn't enter "failed" state and trigger
      # SystemdServiceFailed alerts. Changes are tracked via aide_check_status Prometheus metric.
      SuccessExitStatus = [
        0
        1
        2
        3
        4
        5
        6
        7
      ];
      # NOTE: the former ExecStopPost "aide-result-emit" hook is GONE. It emitted
      # aide_changes_detected + aide_last_check_timestamp_seconds from
      # $EXIT_STATUS; both are now emitted by the ExecStart wrapper above, from
      # the same walk that produces the counts, so the two can no longer drift.
      # Moving the timestamp into ExecStart also FIXES the dead-man: the old hook
      # ran even when the check died and still advanced
      # aide_last_check_timestamp_seconds, which SUPPRESSED AideResultStale
      # (config-drift.yaml) exactly when it should have fired. Now the timestamp
      # only advances when a walk actually completed.
    };
  };

  # AIDE update service (updates database with approved changes)
  systemd.services.aide-update = {
    description = "Update AIDE database with current state";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.aide}/bin/aide --update";
      ExecStartPost = [
        "${pkgs.coreutils}/bin/mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
        # Re-check against the database we just installed, so the PUBLISHED metric
        # agrees with the baseline that now exists.
        #
        # Without this, AIDEChangesDetected latches for up to a full day after the
        # condition is resolved. aide-check runs daily and its ExecStopPost is the
        # single emitter of aide_result.prom, so a rebuild at 04:20 leaves the
        # 00:23 verdict published until 00:19 the next night — measured on
        # 2026-08-05, where the database was correctly re-baselined at 04:21:55 and
        # the alert nonetheless still read changes_detected=1, changed_files=77 for
        # a further sixteen hours. On a host that is rebuilt several times a day
        # that makes the alert permanently on, which is no control at all.
        #
        # This RE-MEASURES rather than asserting a clean result. Writing zeroes
        # here would have been cheaper and wrong twice over: it would duplicate the
        # emitter that lines 227-238 exist to warn against — two writers of these
        # gauges once had them contradicting each other in a single scrape — and it
        # would report a state nothing had verified.
        #
        # --no-block because this runs inside a ExecStartPost and aide-check has no
        # ordering relationship to this unit; blocking on it would deadlock the
        # transaction.
        "${pkgs.systemd}/bin/systemctl start --no-block aide-check.service"
      ];
      # AIDE exit codes: 0=no changes, 1-7=changes detected (all valid for update)
      # Codes are additive bits (1=new, 2=removed, 4=changed), so:
      # 1=new, 2=removed, 3=new+removed, 4=changed, 5=new+changed, 6=removed+changed, 7=all
      SuccessExitStatus = [
        0
        1
        2
        3
        4
        5
        6
        7
      ];
    };
  };

  # Automated daily AIDE check timer
  systemd.timers.aide-check = {
    description = "Daily AIDE integrity check";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30min"; # Prevent all systems from checking at once
    };
  };

  # Auto-update AIDE database after nixos-rebuild
  # Since all system changes are applied via Nix, the rebuild itself is the
  # approval of changes. This prevents false-positive integrity alerts from
  # expected NixOS store path changes after each rebuild.
  #
  # We delay the update by 60s because some system changes (e.g. /usr/bin/env
  # symlink recreation) happen after activation scripts complete. Without the
  # delay, aide-update can finish before all changes land, causing the next
  # aide-check to report false positives.
  system.activationScripts.aide-post-rebuild = lib.stringAfter [ "etc" ] ''
    if [ -f /var/lib/aide/aide.db ]; then
      ${pkgs.systemd}/bin/systemd-run --on-active=60 \
        --timer-property=AccuracySec=1 \
        --description="Post-rebuild AIDE database update" \
        ${pkgs.systemd}/bin/systemctl start aide-update.service 2>/dev/null || true
    fi
  '';

  # Re-baseline after GARBAGE COLLECTION too, for exactly the reason the
  # post-rebuild hook above exists. A rebuild is not the only thing that
  # legitimately changes what AIDE watches.
  #
  # /nix/var/nix/profiles/system is monitored READONLY (aide.conf line 65), and
  # `nix.gc` (modules/core/base.nix, weekly, --delete-older-than 30d) deletes the
  # numbered generation symlinks beside it. Measured 2026-08-17: nix-gc ran at
  # 00:00:02 and removed 37,344 store paths; the 00:09 aide-check then reported
  # 0 added, 0 changed and TEN removed entries, every one of them a
  # /nix/var/nix/profiles/system-22NN-link, and AideChangesDetected fired.
  #
  # Nothing was wrong. The database was baselined at 21:25 the previous evening,
  # before the collection, so the check was comparing against a pre-GC world.
  # Without this, every GC produces a fresh false positive that persists until
  # the next rebuild happens to re-baseline -- and rebuilds are not guaranteed to
  # follow a GC.
  #
  # onSuccess rather than a timer or an ExecStartPost: it fires only when the
  # collection actually SUCCEEDED, it needs no delay because nix-gc's deletions
  # are complete when the unit exits (unlike activation, where the 60s above
  # exists because changes land after the script returns), and a failure to
  # re-baseline cannot fail the collection itself.
  #
  # This does NOT weaken the control. The generation links stay monitored; what
  # changes is that a KNOWN, scheduled, privileged-process deletion is followed
  # by a re-measurement, exactly as a rebuild is. An unexplained removal between
  # collections still reports.
  systemd.services.nix-gc.onSuccess = [ "aide-update.service" ];

  # ===========================================================================
  # SOPS runtime-secret permission drift monitor
  # ---------------------------------------------------------------------------
  # /run/secrets/* are decrypted at runtime and MUST stay owner-only (0400/0600,
  # owned by the consuming service). A world-readable or group-writable secret
  # is a real exposure. node-exporter has no metric for this, so this tiny root
  # oneshot counts (COUNTS ONLY — never names, never contents; the values are
  # forbidden) the runtime secret files that are other-readable or group-writable
  # and emits a single gauge via the textfile-collector pattern (atomic tmp+mv,
  # 0644, /var/lib/prometheus-node-exporter-textfiles/, picked up by job=node).
  # Alert SecretsWorldReadable (security.yaml) fires on count > 0.
  # ===========================================================================
  systemd.services.secrets-perms-exporter = {
    description = "Export count of world-readable/group-writable /run/secrets files";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "secrets-perms-exporter" ''
        set -euo pipefail
        DIR=/var/lib/prometheus-node-exporter-textfiles
        OUT="$DIR/secrets-perms.prom"
        TMP="$OUT.$$"

        # Count regular files under /run/secrets that are readable by "other"
        # (-perm -o+r) OR writable by "group" (-perm -g+w). -L follows the
        # symlinks that SOPS lays down. Emit ONLY the integer count.
        if [ -d /run/secrets ]; then
          COUNT=$(${pkgs.findutils}/bin/find -L /run/secrets -type f \
            \( -perm -o+r -o -perm -g+w \) 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
        else
          COUNT=0
        fi

        # Write the exposition file with printf so no heredoc indentation leaks
        # into the .prom (Prometheus text format requires metric lines to start
        # at column 0).
        {
          ${pkgs.coreutils}/bin/printf '%s\n' '# HELP secrets_world_readable_count Number of /run/secrets files that are other-readable or group-writable'
          ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE secrets_world_readable_count gauge'
          ${pkgs.coreutils}/bin/printf 'secrets_world_readable_count %s\n' "$COUNT"
        } > "$TMP"
        ${pkgs.coreutils}/bin/chmod 0644 "$TMP"
        ${pkgs.coreutils}/bin/mv -f "$TMP" "$OUT"
      '';
    };
  };

  systemd.timers.secrets-perms-exporter = {
    description = "Hourly /run/secrets permission-drift check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      Persistent = true;
      RandomizedDelaySec = "2min";
    };
  };
}
