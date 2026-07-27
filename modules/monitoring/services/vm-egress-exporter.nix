{ ... }:

# Intentionally empty placeholder — kept only so the import in ./default.nix
# resolves. No exporter is planned here.
#
# The vm-egress deferred spec ("Monitoring egress from the OpenClaw & Hermes
# agent microVMs" in docs/MONITORING_DEFERRED_SPECS.md) chose the rule-only
# option: NO new exporter, because both useful signals already exist. So the
# implementation (2026-06-10, "monitoring: implement deferred-spec exporters +
# alerts sweep") landed entirely outside this file:
#   * node_exporter's node_network_*_bytes_total on the VM tap devices, alerted
#     by modules/monitoring/alerts/vm-egress.yaml (VMAgentEgressVolumeHigh);
#   * a promtail bypass scrape, job_name = "vm-egress"
#     (modules/services/promtail.nix), so the kernel priority-6 egress LOG
#     lines reach Loki, where the LogQL tripwires in
#     modules/monitoring/loki-rules/vm-egress-tripwires.yaml and
#     vm-egress-dns.yaml evaluate them (wired via L+ symlinks in
#     modules/services/loki.nix, not auto-discovered).
{
}
