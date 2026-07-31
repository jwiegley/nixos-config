# SINGLE SOURCE OF TRUTH for alert rule files that are deliberately NOT loaded.
#
# Both consumers readDir their rule directories independently:
#
#   modules/monitoring/services/alerting.nix              -> services.prometheus.ruleFiles
#   modules/monitoring/services/nagios-prometheus-mirror.nix -> one `define service`
#                                                               (PROM-MIRROR <alertname>)
#                                                               per rule
#
# That duplication is why this file exists. On 2026-07-31 shlink was disabled and its rules
# were parked in alerting.nix alone; Prometheus correctly stopped loading them, but the Nagios
# mirror kept generating eight `PROM-MIRROR Shlink*` services from the same yaml, so Nagios
# went on checking a container that no longer existed. Parking a file in one place and not the
# other is worse than not parking it at all, because the remaining half looks authoritative.
#
# Keys match `ruleDirs` in nagios-prometheus-mirror.nix. Values are basenames within that
# directory. alerting.nix consumes `prometheus`; vmalert.nix consumes `vm` if it ever needs to.
# Both consumers assert that every name listed here actually exists -- a typo would otherwise
# park nothing and fail silently, which is the same failure in a different disguise.
#
# To re-enable a service, remove its entry here in the SAME change that re-enables the
# service itself.
{
  # shlink: disabled in full 2026-07-31 pending a release fixing the 2026-07 security
  # advisory. See the commented imports in hosts/vulcan/default.nix and
  # modules/containers/quadlet.nix, and the commented Nagios checks in
  # modules/services/nagios.nix ("Shlink API Health", "Shlink Web Client HTTP").
  prometheus = [ "shlink.yaml" ];
  loki = [ ];
  vm = [ ];
}
