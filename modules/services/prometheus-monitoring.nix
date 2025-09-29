{ config, lib, pkgs, ... }:

let
  # Alert rules directory
  alertRulesDir = ../monitoring/alerts;

  # Load all alert rules from YAML files
  alertRuleFiles = builtins.map (file: "${alertRulesDir}/${file}") [
    "system.yaml"
    "database.yaml"
    "storage.yaml"
    "certificates.yaml"
    "chainweb.yaml"
  ];
in
{
  # Phase 1: Basic monitoring foundation with node_exporter

  services = {
    # Prometheus node exporter for system metrics
    prometheus.exporters = {
      node = {
        enable = true;
        port = 9100;

        # Enable additional collectors
        enabledCollectors = [
          "systemd"
          "processes"
          "logind"
        ];

        # Disable collectors that might have security implications
        disabledCollectors = [
          "wifi"
        ];

        extraFlags = [
          "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker)($|/)"
          "--collector.netclass.ignored-devices=^(lo|podman[0-9]|br-|veth).*"
        ];
      };

      # PostgreSQL exporter
      postgres = {
        enable = true;
        port = 9187;
        runAsLocalSuperUser = true;
      };

      # Systemd exporter for service status
      systemd = {
        enable = true;
        port = 9558;
      };
    };

    # Basic Prometheus server (Phase 1 - local monitoring only)
    prometheus = {
      enable = true;
      port = 9090;

      # Only listen on localhost for now
      listenAddress = "127.0.0.1";

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
        (builtins.pathExists ../monitoring/alerts/custom.yaml)
        ../monitoring/alerts/custom.yaml
      );

      # Scrape configurations
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ];
            labels = {
              alias = "vulcan";
            };
          }];
        }
        {
          job_name = "postgres";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.postgres.port}" ];
          }];
        }
        {
          job_name = "systemd";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.systemd.port}" ];
          }];
        }
        {
          job_name = "chainweb";
          static_configs = [{
            targets = [ "localhost:9101" ];
            labels = {
              alias = "kadena-chainweb";
              blockchain = "kadena";
            };
          }];
          scrape_interval = "30s";  # Scrape more frequently for blockchain metrics
        }
      ];

      # Alertmanager configuration
      alertmanagers = lib.mkIf (config.services.prometheus.alertmanager.enable or false) [
        {
          static_configs = [{
            targets = [ "localhost:9093" ];
          }];
        }
      ];
    };
  };

  # Open firewall for Prometheus exporters (only localhost access for now)
  networking.firewall = {
    interfaces."lo" = {
      allowedTCPPorts = [
        config.services.prometheus.exporters.node.port
        config.services.prometheus.exporters.postgres.port
        config.services.prometheus.exporters.systemd.port
        config.services.prometheus.port
      ];
    };
  };

  # Create a script to check monitoring health
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-monitoring" ''
      echo "=== Node Exporter Status ==="
      curl -s localhost:9100/metrics | head -5
      echo ""
      echo "=== Prometheus Targets ==="
      curl -s localhost:9090/api/v1/targets | ${pkgs.jq}/bin/jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
      echo ""
      echo "=== Active Alerts ==="
      curl -s localhost:9090/api/v1/alerts | ${pkgs.jq}/bin/jq '.data.alerts[] | {alertname: .labels.alertname, state: .state}'
    '')

    (writeShellScriptBin "reload-prometheus" ''
      echo "Reloading Prometheus configuration..."
      ${pkgs.systemd}/bin/systemctl reload prometheus
      echo "Prometheus configuration reloaded"
    '')

    (writeShellScriptBin "validate-alerts" ''
      echo "Validating Prometheus alert rules..."
      for file in ${toString alertRuleFiles}; do
        echo "Checking $file..."
        ${pkgs.prometheus}/bin/promtool check rules "$file" || exit 1
      done
      echo "All alert rules are valid"
    '')
  ];

  # Fix exporter startup issues - ensure they start after network is ready
  systemd.services = {
    "prometheus-node-exporter" = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    "prometheus-postgres-exporter" = {
      wants = [ "network-online.target" "postgresql.service" ];
      after = [ "network-online.target" "postgresql.service" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    "prometheus-systemd-exporter" = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };
  };

  # Documentation
  environment.etc."prometheus/README.md" = {
    text = ''
      # Prometheus Monitoring Configuration

      ## Alert Rules
      Alert rules are stored in `/etc/nixos/modules/monitoring/alerts/`:
      - system.yaml: System-level alerts (CPU, memory, disk)
      - database.yaml: Database-specific alerts
      - storage.yaml: Storage and backup alerts
      - certificates.yaml: Certificate expiration alerts
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
      - PostgreSQL Exporter: http://localhost:9187/metrics
      - Systemd Exporter: http://localhost:9558/metrics
      - Chainweb: http://localhost:9101/metrics
    '';
    mode = "0644";
  };
}
