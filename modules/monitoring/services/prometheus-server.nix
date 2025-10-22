{ config, lib, pkgs, ... }:

let
  # Alert rules directory
  alertRulesDir = ../../monitoring/alerts;

  # Load all alert rules from YAML files
  alertRuleFiles = builtins.map (file: "${alertRulesDir}/${file}") [
    "system.yaml"
    "systemd.yaml"
    "database.yaml"
    # "mssql.yaml"
    "storage.yaml"
    "certificates.yaml"
    "dns.yaml"
    "network.yaml"
    "nextcloud.yaml"
    "litellm-availability.yaml"
    "home-assistant.yaml"
    "home-assistant-backup.yaml"
  ];
in
{
  # Core Prometheus server configuration
  services.prometheus = {
    enable = true;
    port = 9090;

    # Disable config check since token files may not exist at build time
    checkConfig = false;

    # Only listen on localhost for now
    listenAddress = "127.0.0.1";

    # Enable admin API for administrative operations
    extraFlags = [
      "--web.enable-admin-api"
    ];

    # Global configuration
    globalConfig = {
      scrape_interval = "15s";
      evaluation_interval = "15s";
      external_labels = {
        monitor = "vulcan";
        environment = "production";
      };
    };

    # Load alert rules from external YAML files
    ruleFiles = alertRuleFiles ++ (lib.optional
      (builtins.pathExists ../../monitoring/alerts/custom.yaml)
      ../../monitoring/alerts/custom.yaml
    );

    # Alertmanager configuration
    alertmanagers = lib.mkIf (config.services.prometheus.alertmanager.enable or false) [
      {
        static_configs = [{
          targets = [ "localhost:9093" ];
        }];
      }
    ];
  };

  # Firewall configuration for Prometheus server
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.port
  ];

  # Documentation
  environment.etc."prometheus/README.md" = {
    text = ''
      # Prometheus Monitoring Configuration

      ## Alert Rules
      Alert rules are stored in `/etc/nixos/modules/monitoring/alerts/`:
      - system.yaml: System-level alerts (CPU, memory, disk)
      - systemd.yaml: Systemd service health and state alerts
      - database.yaml: Database-specific alerts
      - storage.yaml: Storage and backup alerts
      - certificates.yaml: Certificate expiration alerts
      - home-assistant.yaml: Home Assistant IoT device alerts (security, safety, energy)
      - custom.yaml: Custom site-specific alerts (optional)

      ## Useful Commands
      - `check-monitoring`: Check status of monitoring stack
      - `validate-alerts`: Validate alert rule syntax
      - `reload-prometheus`: Reload Prometheus configuration

      ## Adding Custom Alerts
      Create `/etc/nixos/modules/monitoring/alerts/custom.yaml` with your custom rules.
      The file will be automatically loaded if it exists.

      ## Metrics Endpoints
      - Prometheus: http://localhost:9090
      - Node Exporter: http://localhost:9100/metrics
        - Includes textfile collector for custom metrics (restic, etc.)
      - PostgreSQL Exporter: http://localhost:9187/metrics
      - Systemd Exporter: http://localhost:9558/metrics
      - Dovecot Exporter: http://localhost:9166/metrics
      - Postfix Exporter: http://localhost:9154/metrics
      - ZFS Exporter: http://localhost:9134/metrics
      - Blackbox Exporter: http://localhost:9115/metrics

      ## Restic Monitoring
      Restic metrics are collected via textfile collector for all repositories:
      Audio, Backups, Databases, Home, Nasim, Photos, Video, doc, src

      Metrics are updated every 6 hours via systemd timer.
      To manually refresh: systemctl start restic-metrics.service
    '';
    mode = "0644";
  };
}
