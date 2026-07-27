{
  config,
  lib,
  pkgs,
  ...
}:

# Dovecot FTS (Xapian/flatcurve) index-staleness monitor.
#
# Dovecot full-text search runs on the flatcurve (Xapian "glass") backend with
# fts_autoindex = yes (modules/services/dovecot.nix:333-338). The autoindexer is
# supposed to keep a per-mailbox Xapian index in step with delivered mail, but
# nothing detects when it falls behind: if indexer-worker wedges, a folder's
# index corrupts, or a glass write fails mid-rotation, the service stays green
# (dovecot_up=1, the IMAPS probe passes) while search silently returns stale or
# empty results — a "correctness" gap, the weakest pillar in the coverage plan.
#
# This daily root oneshot, modeled on dovecot-imapsieve-monitor.nix, computes per
# mail user the maximum-over-folders lag between the newest delivered-mail mtime
# and the newest flatcurve-index mtime (clamped >= 0, since flatcurve rewrites the
# whole glass DB each pass and the index mtime is usually AHEAD of the mail). It
# emits fts_index_lag_seconds{user} plus a last-run/success freshness pair.
#
# SECURITY: pure filesystem metadata only. find -printf '%T@' returns timestamps,
# never filenames/headers/bodies/sender data. No IMAP login, no doveadm call, no
# mail-content read. Runs as root solely because the maildirs are 0700 <user>:users
# and node-exporter (the textfile-collector owner) cannot read them. The .prom
# output is mtimes and their differences — non-sensitive, chmod 644 like every
# other textfile metric.
#
# Index layout (where the signal lives): per-mailbox under
#   <maildir>/[.<folder>/]fts-flatcurve/current.<id>/{postlist,termlist}.glass
# plus rotated index.<n>/ snapshots. mailLocation = maildir:/var/mail/%u
# (dovecot.nix:88); /var/mail -> /var/spool/mail. The tmpfiles-created
# /var/lib/dovecot-fts dir is EMPTY — flatcurve stores indexes inside the maildir,
# not there.
#
# Baseline measured live 2026-06-10: clamped max lag = 0 s for all three users
# (johnw 29 fts-flatcurve folders, assembly 2, bia 1) at ~211-306 delivered
# msgs/day, so the 48h/7d thresholds sit far above noise. A fourth mail user,
# rbcca, was added on 2026-07-02 (commit 68b8c27) and is covered by the loop
# below but is not part of that baseline measurement.
#
# FORMAL RETIREMENT — DovecotHighConnectionCount: this intent is consciously
# CLOSED, not deferred. The dovecot Prometheus exporter (:9166, job=dovecot)
# exposes only dovecot_user_* auth/IO/cache counters — there is NO
# concurrent-connection gauge to alert against, and it was already removed from
# the rule set in the 2026-06-09 dead-metric sweep. vulcan is a single-user mail
# server with mail_max_userip_connections = 100 for the LAN (dovecot.nix:319), so
# a connection-count alert would protect against a load profile that cannot occur.
# Reviving it would require a custom exporter scraping `doveadm who`/proc for a
# metric of zero operational value here. Up/down is already covered by
# up{job="dovecot"} and the IMAPS blackbox probe. See docs/MONITORING_COVERAGE_PLAN.md
# and docs/MONITORING_DEFERRED_SPECS.md (#email-fts-staleness).

let
  ftsStalenessCheckScript = pkgs.writeShellScript "dovecot-fts-staleness-check" ''
    set -euo pipefail

    METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/fts_staleness.prom"
    TMP="$METRICS_FILE.tmp"

    # Mail users (matches the maildirs declared in dovecot.nix:463-466). Could be
    # derived from /var/spool/mail/* dirs, but an explicit list keeps the loop
    # from accidentally scanning non-mailbox entries under the spool dir.
    USERS="johnw assembly bia rbcca"

    {
      echo "# HELP fts_index_lag_seconds Max over folders of (newest mail mtime - newest flatcurve index mtime), clamped >=0"
      echo "# TYPE fts_index_lag_seconds gauge"
      for u in $USERS; do
        root="/var/spool/mail/$u"
        [ -d "$root" ] || continue
        maxlag=0
        # Iterate only folders that actually have a flatcurve index dir. A dormant
        # folder with no new mail keeps lag ~0 by construction (both mtimes old).
        while IFS= read -r ftsdir; do
          d=$(dirname "$ftsdir")
          # Single-pass awk max instead of `sort -nr | head -1`: head closes the
          # pipe after one line, sort then dies on SIGPIPE, and `set -o pipefail`
          # turns that into a script failure (broken-pipe, exit 2) on any folder
          # with >1 file. awk reads the whole stream, so no pipe ever breaks.
          # Prints nothing for an empty folder, preserving the `-z` checks below.
          mail=$(find "$d/cur" "$d/new" -type f -printf '%T@\n' 2>/dev/null | awk '{t=int($1); if (NR==1 || t>m) m=t} END {if (NR) print m}')
          idx=$(find "$ftsdir" -type f -name '*.glass' -printf '%T@\n' 2>/dev/null | awk '{t=int($1); if (NR==1 || t>m) m=t} END {if (NR) print m}')
          [ -z "$mail" ] && continue
          [ -z "$idx" ] && idx=0
          lag=$((mail - idx))
          [ "$lag" -lt 0 ] && lag=0
          [ "$lag" -gt "$maxlag" ] && maxlag=$lag
        done < <(find "$root" -type d -name fts-flatcurve 2>/dev/null)
        echo "fts_index_lag_seconds{user=\"$u\"} $maxlag"
      done

      echo "# HELP fts_staleness_last_run_timestamp_seconds Unix time the FTS staleness check last completed"
      echo "# TYPE fts_staleness_last_run_timestamp_seconds gauge"
      echo "fts_staleness_last_run_timestamp_seconds $(date +%s)"

      echo "# HELP fts_staleness_check_success Whether the FTS staleness check completed (1=ok)"
      echo "# TYPE fts_staleness_check_success gauge"
      echo "fts_staleness_check_success 1"
    } > "$TMP"

    mv "$TMP" "$METRICS_FILE"
    chmod 644 "$METRICS_FILE"

    echo "OK: FTS staleness check completed"
  '';
in
{
  # Daily root oneshot: read maildir + flatcurve-index mtimes, emit lag metric.
  # No SuccessExitStatus gymnastics: set -euo pipefail and let a real failure exit
  # non-zero so fts_staleness_check_success / the timestamp goes STALE (caught by
  # FtsStalenessCheckStale) rather than lying with a frozen value.
  systemd.services.dovecot-fts-staleness-check = {
    description = "Monitor Dovecot FTS (flatcurve) index staleness";
    after = [ "dovecot2.service" ];
    wants = [ "dovecot2.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ftsStalenessCheckScript}";
      User = "root"; # 0700 maildirs are unreadable by node-exporter
      Group = "root";
    };

    path = with pkgs; [
      coreutils
      findutils
      gawk # newest-mtime max is computed with awk (SIGPIPE-safe vs sort|head)
    ];
  };

  # Daily timer. 04:30 sits after the nightly flatcurve index rotation (~03:00)
  # and after backups, so it measures a settled state. Persistent catches up a
  # missed run after downtime.
  systemd.timers.dovecot-fts-staleness-check = {
    description = "Timer for dovecot-fts-staleness-check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  # Prometheus alerting rules (inline ruleFiles, mirroring imapsieve).
  # Baseline live 2026-06-10: lag = 0 s for all users, so 48h/7d thresholds sit
  # six orders of magnitude above noise. A dormant folder cannot trip the alert.
  services.prometheus.ruleFiles = [
    (pkgs.writeText "fts-staleness-alerts.yml" ''
      groups:
        - name: fts-staleness
          interval: 5m
          rules:
            # Warning: index >48h behind delivered mail. At ~211-306 msgs/day with
            # a measured 0 s baseline, anything above a few hours means autoindex
            # stopped. 48h tolerates a weekend of indexer trouble before paging.
            - alert: FtsIndexStale
              expr: fts_index_lag_seconds > 172800
              for: 30m
              labels:
                severity: warning
                category: email
                service: dovecot
                component: mail
              annotations:
                summary: "Dovecot FTS index stale for {{ $labels.user }}"
                description: "Newest mail is {{ $value | humanizeDuration }} ahead of the newest flatcurve index for {{ $labels.user }}. Search results may be incomplete. Remediate: doveadm index -u {{ $labels.user }} '*'  (or  doveadm fts rescan -u {{ $labels.user }})."

            # Critical: index >7d behind. The indexer-worker is almost certainly
            # wedged; this is unambiguous breakage.
            - alert: FtsIndexSeverelyStale
              expr: fts_index_lag_seconds > 604800
              for: 30m
              labels:
                severity: critical
                category: email
                service: dovecot
                component: mail
              annotations:
                summary: "Dovecot FTS index SEVERELY stale for {{ $labels.user }}"
                description: "FTS index for {{ $labels.user }} is >7d behind delivered mail. The indexer-worker is likely wedged. Check: systemctl status dovecot2; journalctl -u dovecot2 | grep -i 'fts\\|index'."

            # Freshness guard for the collector itself. The daily oneshot rewrites
            # fts_staleness.prom; if the timer dies, the lag metric freezes rather
            # than reporting fresh 0. 36h = 1 daily cadence + a generous grace.
            - alert: FtsStalenessCheckStale
              expr: (time() - fts_staleness_last_run_timestamp_seconds) > 129600
              for: 1h
              labels:
                severity: warning
                category: email
                service: dovecot
                component: mail
              annotations:
                summary: "FTS staleness collector not running"
                description: "fts_staleness check hasn't completed in {{ $value | humanizeDuration }}. The fts_index_lag_seconds metric is now frozen. Check: systemctl status dovecot-fts-staleness-check.timer dovecot-fts-staleness-check.service."
    '')
  ];

  # Optional MONTHLY remediation oneshot (self-heal, NOT a probe). doveadm fts
  # rescan -A is I/O-heavy against the 800MB+ INBOX index, so it is intentionally
  # left commented/off. Enable only if FtsIndexStale ever fires; the manual form
  # is documented in the alert annotation regardless.
  #
  # systemd.services.dovecot-fts-rescan = {
  #   description = "Monthly Dovecot FTS (flatcurve) rescan (self-heal)";
  #   after = [ "dovecot2.service" ];
  #   wants = [ "dovecot2.service" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = "${pkgs.dovecot}/bin/doveadm fts rescan -A";
  #     User = "root";
  #   };
  # };
  # systemd.timers.dovecot-fts-rescan = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig = {
  #     OnCalendar = "monthly";
  #     Persistent = true;
  #     RandomizedDelaySec = "1h";
  #   };
  # };
}
