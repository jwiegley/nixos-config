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
          description: "The fetchmail-good service (IDLE mode for Good folder) has been down for more than 5 minutes. Check logs: journalctl -u fetchmail-good and /var/log/fetchmail-good/fetchmail.log"

      # FetchmailGoodFailed deleted 2026-07-29: strict subset of SystemdServiceFailed
      # (systemd.yaml, for=60s, no exclusion list); FetchmailGoodDown above carries the impact.
      # Its one unique string, the /var/log/fetchmail-good/fetchmail.log path, was moved up into
      # FetchmailGoodDown's description rather than dropped -- the journal alone does not hold
      # fetchmail's own verbose per-poll output.

      # FetchmailGoodFlapping deleted 2026-08-18 (nixos-w3w). It read:
      #
      #     rate(node_systemd_unit_state{name="fetchmail-good.service",
      #          state="activating"}[15m]) > 0.05
      #
      # UNFIREABLE, for two compounding reasons. node_systemd_unit_state is a
      # 0/1 gauge, so rate() over it yields an artifact rather than a restart
      # frequency: measured max over 7 days was 0.00112 against a 0.05
      # threshold, 45x below. And the threshold itself was mis-scaled -- 0.05/s
      # sustained over 15m means 45 restarts in 15 minutes, while fetchmail-good
      # actually manages 8 state changes in 7 DAYS. Zero firing series in 14d.
      #
      # NOT REPLACED WITH A FETCHMAIL-SPECIFIC REWRITE. Two generic rules in
      # systemd.yaml now cover this unit correctly and on the right metric
      # (node_systemd_service_restart_total): ServiceRestartLooping catches
      # bursts (>3 in 30m) and ServiceRestartingFrequently catches chronic churn
      # (>8 in 6h), the latter written specifically because fetchmail-good's
      # slow-burn shape is what a burst detector misses. A dedicated rule would
      # need a threshold in the narrow band between fetchmail-good's benign peak
      # (4.00 restarts/6h, from transient IMAP errors that self-heal) and the
      # generic trigger at 8 -- a guess with no incident to calibrate against,
      # which is precisely how the dead rule above came to exist.
  '';
in
{
  # Prometheus alert rules for fetchmail monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ fetchmailRulesFile ];
}
