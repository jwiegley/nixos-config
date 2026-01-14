{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define fetchmail monitoring rules as a separate file
  fetchmailRulesFile = pkgs.writeText "fetchmail-alerts.yml" ''
    groups:
    - name: fetchmail_alerts
      interval: 60s
      rules:
      # Alert if fetchmail-good service is down
      - alert: FetchmailGoodDown
        expr: node_systemd_unit_state{name="fetchmail-good.service",state="active"} == 0
        for: 5m
        labels:
          severity: critical
          service: fetchmail
          instance: good
        annotations:
          summary: "Fetchmail Good folder service is down"
          description: "The fetchmail-good service (IDLE mode for Good folder) has been down for more than 5 minutes. Check logs: journalctl -u fetchmail-good"

      # Alert if fetchmail-spam service is down
      - alert: FetchmailSpamDown
        expr: node_systemd_unit_state{name="fetchmail-spam.service",state="active"} == 0
        for: 5m
        labels:
          severity: critical
          service: fetchmail
          instance: spam
        annotations:
          summary: "Fetchmail Spam folder service is down"
          description: "The fetchmail-spam service (polling mode for Spam folder) has been down for more than 5 minutes. Check logs: journalctl -u fetchmail-spam"

      # Alert if fetchmail-good service is failed
      - alert: FetchmailGoodFailed
        expr: node_systemd_unit_state{name="fetchmail-good.service",state="failed"} == 1
        for: 1m
        labels:
          severity: critical
          service: fetchmail
          instance: good
        annotations:
          summary: "Fetchmail Good folder service has failed"
          description: "The fetchmail-good service is in failed state. Check logs: journalctl -u fetchmail-good and /var/log/fetchmail-good/fetchmail.log"

      # Alert if fetchmail-spam service is failed
      - alert: FetchmailSpamFailed
        expr: node_systemd_unit_state{name="fetchmail-spam.service",state="failed"} == 1
        for: 1m
        labels:
          severity: critical
          service: fetchmail
          instance: spam
        annotations:
          summary: "Fetchmail Spam folder service has failed"
          description: "The fetchmail-spam service is in failed state. Check logs: journalctl -u fetchmail-spam and /var/log/fetchmail-spam/fetchmail.log"

      # Alert if fetchmail-good service is restarting frequently
      - alert: FetchmailGoodFlapping
        expr: rate(node_systemd_unit_state{name="fetchmail-good.service",state="activating"}[15m]) > 0.05
        for: 5m
        labels:
          severity: warning
          service: fetchmail
          instance: good
        annotations:
          summary: "Fetchmail Good folder service is restarting frequently"
          description: "The fetchmail-good service is restarting more than once every 5 minutes. This may indicate connection issues or configuration problems."

      # Alert if fetchmail-spam service is restarting frequently
      - alert: FetchmailSpamFlapping
        expr: rate(node_systemd_unit_state{name="fetchmail-spam.service",state="activating"}[15m]) > 0.05
        for: 5m
        labels:
          severity: warning
          service: fetchmail
          instance: spam
        annotations:
          summary: "Fetchmail Spam folder service is restarting frequently"
          description: "The fetchmail-spam service is restarting more than once every 5 minutes. This may indicate connection issues or configuration problems."
  '';
in
{
  # Prometheus alert rules for fetchmail monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ fetchmailRulesFile ];
}
