{ config, lib, pkgs, ... }:

{
  # Modular Prometheus monitoring configuration
  # Each service is configured in its own module in modules/monitoring/services/

  imports = [
    ../monitoring/services/prometheus-server.nix
    ../monitoring/services/node-exporter.nix
    ../monitoring/services/postgres-exporter.nix
    ../monitoring/services/systemd-exporter.nix
    ../monitoring/services/postfix-exporter.nix
    ../monitoring/services/zfs-exporter.nix
    ../monitoring/services/restic-metrics.nix
    ../monitoring/services/chainweb-exporters.nix
    ../monitoring/services/opnsense-monitoring.nix
    ../monitoring/services/technitium-dns-monitoring.nix
    ../monitoring/services/dns-query-logs.nix
    ../monitoring/services/monitoring-utils.nix
    ../monitoring/services/prometheus-nginx.nix
    ../monitoring/services/nginx-exporter.nix
    ../monitoring/services/redis-exporter.nix
    ../monitoring/services/phpfpm-exporter.nix
    ../monitoring/services/health-check-exporters.nix
    ../monitoring/services/certificate-exporter.nix
    ../monitoring/services/remote-nodes.nix
    ../monitoring/services/home-assistant-backup-exporter.nix
    ../monitoring/services/litellm-exporter.nix
    ../monitoring/services/minio-exporter.nix
    ../monitoring/services/paperless-exporter.nix
    ../monitoring/services/paperless-ai-exporter.nix
    ../monitoring/services/node-red-exporter.nix
  ];
}
