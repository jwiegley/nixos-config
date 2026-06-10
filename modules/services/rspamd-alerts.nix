{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define Rspamd monitoring rules.
  #
  # 2026-06-10 (P1 monitoring sweep): rewrote 5 of 7 rules that queried
  # metric names the rspamd exporter never emits (verified live against the
  # exporter on localhost:11334 / job="rspamd"). Old -> new mapping:
  #   rspamd_scan_time_seconds        -> rspamd_scan_time_average  (gauge, ms)
  #   rspamd_messages_total           -> rspamd_scanned_total
  #   rspamd_action_reject_total      -> rspamd_actions_total{type="reject"}
  #   rspamd_learned_spam_timestamp   -> increase(rspamd_learned_total[7d])
  #   rspamd_bayes_tokens             -> rspamd_statfiles_used
  # The dead rules silently never fired. RspamdServiceDown (up==0) stays as
  # the canonical down-signal; the duplicate-named systemd-state rule was
  # removed from email-services.yaml to avoid an alert-name collision.
  rspamdRulesFile = pkgs.writeText "rspamd-alerts.yml" ''
    groups:
    - name: rspamd_alerts
      interval: 60s
      rules:
      # Alert if Rspamd is down (controller/exporter unreachable).
      - alert: RspamdServiceDown
        expr: up{job="rspamd"} == 0
        for: 5m
        labels:
          severity: critical
          service: rspamd
        annotations:
          summary: "Rspamd service is down"
          description: "The Rspamd spam filtering service has been down for more than 5 minutes. Spam filtering is not functioning."

      # Alert if Rspamd is processing messages slowly.
      # rspamd_scan_time_average is the lifetime average scan time reported by
      # the controller (unit is undocumented in /metrics HELP but tracks the
      # controller's scan_time.avg, milliseconds). Observed healthy baseline on
      # this host is ~5-6 (range 4.9-6.2 over 6h), so the old `> 5` threshold
      # would have fired chronically. Threshold set well above baseline to catch
      # a genuine ~8-10x regression without false positives.
      - alert: RspamdHighProcessingTime
        expr: rspamd_scan_time_average > 50
        for: 15m
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "Rspamd processing time is high"
          description: "Rspamd average scan time is {{ $value }} (healthy baseline ~5-6). A large sustained rise can indicate a slow Lua rule, an overloaded host, or a backend (redis/DNS) timing out."

      # Alert if Rspamd spam detection rate is abnormally high.
      # rspamd_scanned_total is the total-scanned counter; rspamd_spam_total is
      # the spam-classified counter. Baseline spam fraction on this host is
      # ~0.001, so 0.8 is a wide margin for a genuine flood/misconfiguration.
      - alert: RspamdHighSpamRate
        expr: (rate(rspamd_spam_total[1h]) / clamp_min(rate(rspamd_scanned_total[1h]), 1)) > 0.8
        for: 1h
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "Unusually high spam detection rate"
          description: "Over 80% of messages are being marked as spam in the last hour. This might indicate misconfiguration or an actual spam flood."

      # Alert if Rspamd has learned no spam/ham in 7 days.
      # rspamd_learned_total is the cumulative Bayes learn counter; on this host
      # it advances ~32/7d, so `increase == 0` only fires if training truly stops.
      - alert: RspamdNoRecentSpamLearning
        expr: increase(rspamd_learned_total[7d]) == 0
        for: 1h
        labels:
          severity: info
          service: rspamd
        annotations:
          summary: "No Bayes learning activity in 7 days"
          description: "Rspamd has not learned any new messages in 7 days. Users may not be training the filter (move-to-Junk / learn pipes), or the learn path is broken."

      # Alert if Redis backend for Rspamd is unavailable. The rspamd redis
      # (127.0.0.1:6381) is probed by the redis-multi /scrape job, whose
      # relabeling stamps instance with the redis URL — select that instance
      # rather than a dedicated job name.
      - alert: RspamdRedisUnavailable
        expr: redis_up{job="redis-multi",instance=~".*:6381"} == 0
        for: 5m
        labels:
          severity: critical
          service: rspamd
        annotations:
          summary: "Rspamd Redis backend is unavailable"
          description: "The Redis instance used for Rspamd Bayes learning is down. Spam detection will be degraded."

      # Alert if Bayes database is getting too large.
      # rspamd_statfiles_used is the per-symbol token usage (BAYES_SPAM/BAYES_HAM,
      # redis-backed). Currently 0 on this host; 1e7 tokens would be an unusually
      # large classifier worth pruning.
      - alert: RspamdBayesDatabaseLarge
        expr: rspamd_statfiles_used > 1e7
        for: 1h
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "Rspamd Bayes database is very large"
          description: "The Bayes classifier ({{ $labels.symbol }}) has grown to {{ $value }} tokens. Consider pruning old tokens to maintain performance."

      # Alert if Rspamd rejects a high fraction of messages.
      # rspamd_actions_total{type="reject"} is the reject-action counter.
      - alert: RspamdHighRejectionRate
        expr: (rate(rspamd_actions_total{type="reject"}[1h]) / clamp_min(rate(rspamd_scanned_total[1h]), 1)) > 0.5
        for: 30m
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "High message rejection rate"
          description: "Over 50% of scanned messages are being rejected by Rspamd. This might indicate a spam attack or overly aggressive settings."
  '';
in
{
  # Prometheus alert rules for Rspamd monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ rspamdRulesFile ];
}
