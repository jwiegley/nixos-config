# Replacement for the dead-rule detection capability lost when the external alert mirror
# was removed (2026-07-31).
#
# That mirror re-evaluated every Prometheus expression through a SECOND, independent
# scheduler, which is how the 2026-06-09 "123 rules could never fire" defect was caught --
# rules selecting `systemd_unit_state` when the exporter publishes `node_systemd_unit_state`.
# Prometheus does not consider that an error: the query is valid, returns no series, and the
# rule sits `inactive` forever behind a wall of reassuring green.
#
# This restores the detection without a second scheduler: it asks the TSDB whether the
# metrics each rule selects actually exist.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  auditor = pkgs.writers.writePython3Bin "prometheus-rule-audit" {
    flakeIgnore = [
      "E501" # long doc lines
      "W503"
      "E265"
    ];
  } (builtins.readFile ../../../scripts/prometheus-rule-audit.py);
in
{
  systemd.services.prometheus-rule-audit = {
    description = "Audit Prometheus alert rules for ones that can never fire";
    # after network-online is deliberately NOT used: this only talks to loopback.
    after = [ "prometheus.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${auditor}/bin/prometheus-rule-audit";
      User = "root";
      Group = "root";

      # It queries once per distinct metric name across ~508 rules, with a local cache, so
      # a few hundred loopback queries worst case. 300s is far above the observed runtime
      # (~10s) but must stay generous: TimeoutStartSec is ENFORCED here, and a previously
      # ignored cap becoming enforced has bitten this host before.
      TimeoutStartSec = "300s";

      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_UNIX"
      ];
    };
  };

  systemd.timers.prometheus-rule-audit = {
    description = "Periodic Prometheus dead-rule audit";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # OnActiveSec, not OnBootSec: on a host with long uptime an OnBootSec timer that has
      # already passed never fires again, which is how discord-canary-hermes.timer sat dead
      # for 27 days. Hourly thereafter -- rule sets change only on a switch.
      OnActiveSec = "10min";
      OnUnitActiveSec = "1h";
      Unit = "prometheus-rule-audit.service";
    };
  };

  # Register the new textfile in the hourly staleness tier, so the detector cannot itself go
  # blind. An exporter without a freshness guard is the exact failure class it exists to
  # catch, and shipping one that way would be self-refuting.
  #
  # (The allowlist lives in modules/monitoring/alerts/meta-monitoring.yaml
  # TextfileCollectorStaleHourly; this comment is the pointer, the entry is made there.)
}
