{
  config,
  lib,
  pkgs,
  ...
}:

# vmalert — alerting/recording-rule engine for the VictoriaMetrics TSDB.
#
# WHY THIS EXISTS: Home Assistant pushes its metrics (the unit-named *_value /
# state_* series, the Flume water-attribution series, etc.) into VictoriaMetrics
# (127.0.0.1:8428) via InfluxDB line protocol. Prometheus and VictoriaMetrics are
# DISJOINT TSDBs (see project_monitoring_tsdb_architecture): Prometheus never sees
# those series, so a rule placed in modules/monitoring/alerts/*.yaml can NEVER
# evaluate them. Until this module, the entire HA-pushed dataset had ZERO
# alerting. vmalert closes that gap by evaluating rules directly against VM and
# shipping any firing alerts to the SAME Alertmanager (127.0.0.1:9093) Prometheus
# already uses, so they flow through the existing routes (severity=critical ->
# iPhone + email; severity=warning -> email).
#
# RULES: modules/monitoring/vm-alerts/*.yaml, auto-discovered below and pinned as
# immutable nix store paths (mirrors how alerting.nix discovers
# modules/monitoring/alerts/*.yaml). Unlike Prometheus rule files these are NOT
# validated at build time — vmalert checks rule syntax at unit start, so after a
# switch verify `systemctl status vmalert` and `curl 127.0.0.1:8880/api/v1/rules`.
#
# PORT: vmalert's own web/API + self-metrics listen on 127.0.0.1:8880 (loopback
# only; orchestrator registers it in docs/ports.txt). The self-scrape job below
# pulls vmalert's /metrics into Prometheus so vmalert itself is monitored.

let
  ruleDir = ../vm-alerts;

  ruleFiles = builtins.map (name: "${ruleDir}/${name}") (
    builtins.filter (name: lib.hasSuffix ".yaml" name) (builtins.attrNames (builtins.readDir ruleDir))
  );
in
{
  services.vmalert.instances."" = {
    enable = true;
    settings = {
      "datasource.url" = "http://127.0.0.1:8428";
      "notifier.url" = [ "http://127.0.0.1:9093" ];
      "httpListenAddr" = "127.0.0.1:8880";

      # External URL used in alert/notification links back to vmalert's UI.
      "external.url" = "http://127.0.0.1:8880";

      # Pin the rule set to our store-path YAML files. mkForce replaces the
      # module's default (/etc/vmalert/rules.yml, generated from the empty
      # `rules` Nix option) so vmalert loads only these files.
      "rule" = lib.mkForce ruleFiles;
    };
  };

  # Scrape vmalert's own metrics so the alerting engine for the VM TSDB is itself
  # monitored (up{job="vmalert"}, vmalert_alerting_rules_*, etc.). 8880 is
  # loopback-only and listens once vmalert is up; no new externally-exposed port.
  services.prometheus.scrapeConfigs = [
    {
      job_name = "vmalert";
      static_configs = [
        { targets = [ "127.0.0.1:8880" ]; }
      ];
    }
  ];
}
