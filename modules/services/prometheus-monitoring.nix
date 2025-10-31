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
    ../monitoring/services/node-red-exporter.nix
    ../monitoring/services/changedetection-exporter.nix

    # Infrastructure monitoring
    ../monitoring/services/certificate-exporter.nix
    ../monitoring/services/restic-metrics.nix
    ../monitoring/services/health-check-exporters.nix

    # External systems monitoring
    ../monitoring/services/opnsense-monitoring.nix
    ../monitoring/services/technitium-dns-monitoring.nix
    ../monitoring/services/dns-query-logs.nix
    ../monitoring/services/remote-nodes.nix

    # Utilities
    ../monitoring/services/monitoring-utils.nix
  ];
}
