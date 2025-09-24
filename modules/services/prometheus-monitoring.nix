{ config, lib, pkgs, ... }:

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

        # settings = {
        #   # Automatically discover databases
        #   auto_discover_databases = true;

        #   # Exclude template databases
        #   exclude_databases = [ "template0" "template1" ];
        # };
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

      # Define alert rules
      rules = [
        ''
          groups:
            - name: system_alerts
              interval: 30s
              rules:
                # Disk space alerts
                - alert: DiskSpaceLow
                  expr: node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs|squashfs"} / node_filesystem_size_bytes < 0.1
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "Low disk space on {{ $labels.instance }}"
                    description: "{{ $labels.device }} on {{ $labels.instance }} has less than 10% free space"

                - alert: DiskSpaceCritical
                  expr: node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs|squashfs"} / node_filesystem_size_bytes < 0.05
                  for: 1m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Critical disk space on {{ $labels.instance }}"
                    description: "{{ $labels.device }} on {{ $labels.instance }} has less than 5% free space"

                # Memory alerts
                - alert: MemoryPressure
                  expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.9
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "High memory usage on {{ $labels.instance }}"
                    description: "Memory usage is above 90% on {{ $labels.instance }}"

                # CPU alerts
                - alert: HighCPUUsage
                  expr: 100 - (avg(irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
                  for: 10m
                  labels:
                    severity: warning
                  annotations:
                    summary: "High CPU usage on {{ $labels.instance }}"
                    description: "CPU usage has been above 80% for 10 minutes"

                # Service alerts
                - alert: SystemdServiceFailed
                  expr: node_systemd_unit_state{state="failed"} > 0
                  for: 1m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Systemd service failed on {{ $labels.instance }}"
                    description: "Service {{ $labels.name }} is in failed state"

                # PostgreSQL alerts
                - alert: PostgreSQLDown
                  expr: up{job="postgres"} == 0
                  for: 1m
                  labels:
                    severity: critical
                  annotations:
                    summary: "PostgreSQL is down"
                    description: "PostgreSQL exporter cannot connect to database"

                - alert: PostgreSQLTooManyConnections
                  expr: pg_stat_database_numbackends / pg_settings_max_connections > 0.8
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "PostgreSQL has too many connections"
                    description: "PostgreSQL instance has more than 80% of max connections in use"

                # ZFS alerts
                - alert: ZFSPoolDegraded
                  expr: node_zfs_zpool_health{state!="online"} > 0
                  for: 1m
                  labels:
                    severity: critical
                  annotations:
                    summary: "ZFS pool degraded on {{ $labels.instance }}"
                    description: "ZFS pool {{ $labels.pool }} is in {{ $labels.state }} state"

                # Certificate expiration alerts
                - alert: CertificateExpiringSoon
                  expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 30
                  for: 1h
                  labels:
                    severity: warning
                  annotations:
                    summary: "SSL certificate expiring soon"
                    description: "Certificate for {{ $labels.instance }} expires in {{ $value }} days"

                - alert: CertificateExpiringCritical
                  expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 7
                  for: 1h
                  labels:
                    severity: critical
                  annotations:
                    summary: "SSL certificate expiring very soon"
                    description: "Certificate for {{ $labels.instance }} expires in {{ $value }} days"
        ''
      ];

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
}
