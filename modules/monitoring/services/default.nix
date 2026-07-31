{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Modular monitoring configuration
  # Each service is configured in its own module in this directory

  imports = [
    # Core monitoring infrastructure
    ./prometheus-server.nix
    ./victoriametrics.nix
    ./self-scrape.nix # Prometheus + VictoriaMetrics self-monitoring scrape jobs
    ./alerting.nix # Auto-discovers alert rules from alerts/
    # P0 monitoring-coverage collectors (docs/MONITORING_COVERAGE_PLAN.md)
    ./smartctl-exporter.nix # SMART health of UAS disks + NVMe
    ./asymmetric-routing-exporter.nix # ip-rule presence gauge (post-boot drift)
    ./nodered-safety-exporter.nix # HA-safety-flow deadman (nodered_events)
    # P1 monitoring-coverage additions (docs/MONITORING_COVERAGE_PLAN.md phase 3)
    ./vmalert.nix # alerting on the VictoriaMetrics TSDB (HA-pushed series)
    ./system-age-exporter.nix # is-the-system-being-patched gauges
    # P2 monitoring-coverage additions (docs/MONITORING_COVERAGE_PLAN.md phase 4)
    # KEPT: this is the REVERSE direction (Nagios state INTO Prometheus), not a mirror.
    # Nagios still exists after the 2026-07-31 de-duplication, so this bridge must too --
    # without it, 5 of the 7 rules in alerts/nagios.yaml lose their only input and a Nagios
    # CRITICAL on a check unique to Nagios would be invisible to Alertmanager.
    ./nagios-status-exporter.nix # Nagios status.dat aggregate counts bridge
    # ./nagios-mirror-divergence.nix REMOVED 2026-07-31 with the tier-2 mirror it reconciled.
    ./speedtest-results-exporter.nix # speedtest RESULT freshness/throughput
    # Deferred-spec implementations (docs/MONITORING_DEFERRED_SPECS.md)
    ./container-cve-exporter.nix # trivy CVE scan of running images
    ./port-drift-exporter.nix # listening-socket drift vs ports.txt registry
    ./config-drift-exporter.nix # crown-jewel config-file change detection + AIDE result metrics
    ./container-image-staleness-exporter.nix # skopeo moving-tag digest drift
    ./microvm-resource-exporter.nix # host-cgroup CPU/mem + backing-volume gauges for the agent VMs
    ./vm-egress-exporter.nix # empty placeholder — the agent-microVM egress signals ship as alerts/vm-egress.yaml + Loki rules, not as an exporter (see the file header)
    ./system-exporters.nix # Consolidated: node, systemd, zfs

    # Service-specific exporters
    ./postgres-exporter.nix
    ./memory-vault-stats-exporter.nix # memory_vault DB store stats -> textfile
    ./postfix-exporter.nix
    ./prometheus-nginx.nix
    ./nginx-exporter.nix
    ./redis-exporter.nix
    ./git-workspace-exporter.nix

    # Application-specific exporters
    ./home-assistant-backup-exporter.nix
    ./immich-exporter.nix
    ./litellm-exporter.nix
    ./node-red-exporter.nix
    ./jupyterlab-alerts.nix
    ./vdirsyncer-exporter.nix
    ./gitea-exporter.nix
    ./gitea-push-mirror-exporter.nix
    ./nut-exporter.nix
    ./nvme-smart-exporter.nix
    ./cgroup-pressure-exporter.nix
    ./hass-entity-availability-exporter.nix
    ./aria2-exporter.nix
    ./aria2-alerts.nix
    ./qdrant-exporter.nix
    ./stock-trader-exporter.nix

    # Infrastructure monitoring
    ./certificate-exporter.nix
    ./restic-metrics.nix
    ./zfs-pool-health-exporter.nix
    ./health-check-exporters.nix
    ./git-workspace-alerts.nix
    # ./litellm-availability-alerts.nix removed 2026-07-29 — its three rules were
    # duplicates of alerts/litellm.yaml at drifted thresholds/dwells; consolidated
    # there (successors named in that file's header). It existed only to
    # interpolate models.nix's primary model name into rule text; that is now a
    # `model` label stamped by litellm-exporter.nix.
    ./aide-metrics.nix
    ./openclaw-canary.nix
    ./openclaw-mcporter-check.nix
    ./hermes-health-check.nix
    ./drafts-mcp-check.nix

    # External systems monitoring
    ./opnsense-monitoring.nix
    ./technitium-dns-monitoring.nix
    ./dns-query-logs.nix
    ./remote-nodes.nix

    # Utilities
    ./monitoring-utils.nix
  ];
}
