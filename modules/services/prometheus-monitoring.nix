{ config, lib, pkgs, ... }:

{
  # Modular Prometheus monitoring configuration
  # Each service is configured in its own module in modules/monitoring/services/

  imports = [
    # Core monitoring infrastructure
    ../monitoring/services/prometheus-server.nix
    ../monitoring/services/system-exporters.nix  # Consolidated: node, systemd, zfs

    # Service-specific exporters
    ../monitoring/services/postgres-exporter.nix
    ../monitoring/services/postfix-exporter.nix
    ../monitoring/services/prometheus-nginx.nix
    ../monitoring/services/nginx-exporter.nix
    ../monitoring/services/redis-exporter.nix
    ../monitoring/services/phpfpm-exporter.nix

    # Application-specific exporters
    ../monitoring/services/home-assistant-backup-exporter.nix
    ../monitoring/services/litellm-exporter.nix
    ../monitoring/services/mindsdb-exporter.nix
    ../monitoring/services/mindsdb-alerts.nix
    ../monitoring/services/node-red-exporter.nix
    ../monitoring/services/n8n-exporter.nix
    ../monitoring/services/n8n-alerts.nix
    ../monitoring/services/jupyterlab-alerts.nix
    ../monitoring/services/vdirsyncer-exporter.nix
    ../monitoring/services/gitea-exporter.nix
    ../monitoring/services/paperless-exporter.nix
    ../monitoring/services/paperless-ai-exporter.nix
    ../monitoring/services/aria2-exporter.nix
    ../monitoring/services/aria2-alerts.nix

    # Infrastructure monitoring
    ../monitoring/services/certificate-exporter.nix
    ../monitoring/services/restic-metrics.nix
    ../monitoring/services/health-check-exporters.nix
    ../monitoring/services/git-workspace-alerts.nix

    # External systems monitoring
    ../monitoring/services/opnsense-monitoring.nix
    ../monitoring/services/technitium-dns-monitoring.nix
    ../monitoring/services/dns-query-logs.nix
    ../monitoring/services/remote-nodes.nix

    # Utilities
    ../monitoring/services/monitoring-utils.nix
  ];
}
