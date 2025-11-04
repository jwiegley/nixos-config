{ config, lib, pkgs, ... }:

let
  # Define Rspamd monitoring rules
  rspamdRulesFile = pkgs.writeText "rspamd-alerts.yml" ''
    groups:
    - name: rspamd_alerts
      interval: 60s
      rules:
      # Alert if Rspamd service is down
      - alert: RspamdServiceDown
        expr: up{job="rspamd"} == 0
        for: 5m
        labels:
          severity: critical
          service: rspamd
        annotations:
          summary: "Rspamd service is down"
          description: "The Rspamd spam filtering service has been down for more than 5 minutes. Spam filtering is not functioning."

      # Alert if Rspamd is processing messages slowly
      - alert: RspamdHighProcessingTime
        expr: rspamd_scan_time_seconds > 5
        for: 10m
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "Rspamd processing time is high"
          description: "Rspamd is taking {{ $value }}s to process messages, which is unusually slow. Normal processing should be under 1 second."

      # Alert if Rspamd spam detection rate is abnormally high
      - alert: RspamdHighSpamRate
        expr: (rate(rspamd_spam_total[1h]) / rate(rspamd_messages_total[1h])) > 0.8
        for: 1h
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "Unusually high spam detection rate"
          description: "Over 80% of messages are being marked as spam in the last hour. This might indicate misconfiguration or an actual spam flood."

      # Alert if Rspamd has not learned any spam in 7 days
      - alert: RspamdNoRecentSpamLearning
        expr: (time() - rspamd_learned_spam_timestamp) > 604800
        for: 1h
        labels:
          severity: info
          service: rspamd
        annotations:
          summary: "No spam learning activity in 7 days"
          description: "Rspamd hasn't learned any new spam messages in 7 days. Users may not be training the filter."

      # Alert if Redis backend for Rspamd is unavailable
      - alert: RspamdRedisUnavailable
        expr: redis_up{job="redis-rspamd"} == 0
        for: 5m
        labels:
          severity: critical
          service: rspamd
        annotations:
          summary: "Rspamd Redis backend is unavailable"
          description: "The Redis instance used for Rspamd Bayes learning is down. Spam detection will be degraded."

      # Alert if Bayes database is getting too large
      - alert: RspamdBayesDatabaseLarge
        expr: rspamd_bayes_tokens > 10000000
        for: 1h
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "Rspamd Bayes database is very large"
          description: "The Bayes classifier database has grown to {{ $value }} tokens. Consider pruning old tokens to maintain performance."

      # Alert if Rspamd rejects high number of messages
      - alert: RspamdHighRejectionRate
        expr: (rate(rspamd_action_reject_total[1h]) / rate(rspamd_messages_total[1h])) > 0.5
        for: 30m
        labels:
          severity: warning
          service: rspamd
        annotations:
          summary: "High message rejection rate"
          description: "Over 50% of messages are being rejected by Rspamd. This might indicate a spam attack or overly aggressive settings."
  '';
in
{
  # Prometheus alert rules for Rspamd monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ rspamdRulesFile ];
}
