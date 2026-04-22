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
    ./alerting.nix # Auto-discovers alert rules from alerts/
    ./system-exporters.nix # Consolidated: node, systemd, zfs

    # Service-specific exporters
    ./postgres-exporter.nix
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
    ./aria2-exporter.nix
    ./aria2-alerts.nix
    ./qdrant-exporter.nix

    # Infrastructure monitoring
    ./certificate-exporter.nix
    ./restic-metrics.nix
    ./zfs-pool-health-exporter.nix
    ./health-check-exporters.nix
    ./git-workspace-alerts.nix
    ./litellm-availability-alerts.nix
    ./aide-metrics.nix
    ./openclaw-canary.nix

    # External systems monitoring
    ./opnsense-monitoring.nix
    ./technitium-dns-monitoring.nix
    ./dns-query-logs.nix
    ./remote-nodes.nix

    # Utilities
    ./monitoring-utils.nix
  ];
}
