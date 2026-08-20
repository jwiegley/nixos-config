# SINGLE SOURCE OF TRUTH for alert rule files that are deliberately NOT loaded.
#
# Today exactly one consumer reads this list:
#
#   modules/monitoring/services/alerting.nix -> services.prometheus.ruleFiles
#
# It exists as a shared file, rather than a local list inside alerting.nix, because parking
# is a property of the RULE FILE, not of one loader. The motivating case: a service was
# disabled and its rules parked in the Prometheus loader alone, while a second generator
# doing its own independent readDir over the same directory kept emitting checks for a
# container that no longer existed. Parking a file in one consumer and not another is worse
# than not parking it at all, because the remaining half looks authoritative. Any consumer
# that readDirs one of these rule directories should filter through this list.
#
# One key per rule directory. Values are basenames within that directory:
#   prometheus -> modules/monitoring/alerts      readDir'ed by alerting.nix, WHICH READS
#                                                THIS LIST. Parking works here.
#   loki       -> modules/monitoring/loki-rules  readDir'ed by modules/services/loki.nix,
#                                                which does NOT read this list.
#   vm         -> modules/monitoring/vm-alerts   readDir'ed by vmalert.nix, which does NOT
#                                                read this list.
# So a name added under `loki` or `vm` today parks NOTHING -- wire the consumer up in the
# same change, or the entry is decoration. alerting.nix asserts that every name it reads
# actually exists; a typo would otherwise park nothing and fail silently, which is the same
# failure in a different disguise.
#
# To re-enable a service, remove its entry here in the SAME change that re-enables the
# service itself.
{
  prometheus = [ ];
  loki = [ ];
  vm = [ ];
}
