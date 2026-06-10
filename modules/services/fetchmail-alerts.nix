{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define fetchmail monitoring rules as a separate file.
  #
  # NOTE (2026-06-10, P2 monitoring sweep): only fetchmail-good is an active
  # systemd unit. The fetchmail-spam service is commented out in fetchmail.nix
  # (the Spam-folder pull pipeline does not run), so `fetchmail-spam.service`
  # has LoadState=not-found and emits ZERO node_systemd_unit_state series. The
  # former FetchmailSpamDown / FetchmailSpamFailed / FetchmailSpamFlapping rules
  # matched nothing and were permanently dead (their ==0/==1 comparisons can
  # never evaluate), while misleadingly implying the Spam pull was monitored.
  # They were removed here. If fetchmail-spam is ever re-enabled, restore the
  # spam rules alongside it (mirror the -good rules below).
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
  '';
in
{
  # Prometheus alert rules for fetchmail monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ fetchmailRulesFile ];
}
