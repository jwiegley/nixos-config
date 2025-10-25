{ config, lib, pkgs, ... }:

let
  # Package the Python script
  dns-query-log-exporter = pkgs.writeScriptBin "dns-query-log-exporter" (builtins.readFile ../scripts/dns-query-log-exporter.py);
in
{
  # DNS Query Log Exporter - pushes Technitium DNS query logs to Loki
  # and exposes Prometheus metrics on port 9101
  systemd.services.dns-query-log-exporter = {
    description = "Technitium DNS Query Log Exporter for Loki and Prometheus";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "loki.service" ];
    wants = [ "loki.service" ];

    # Restart on failure
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "30s";
      User = "dns-query-exporter";
      Group = "dns-query-exporter";

      # State directory for tracking last processed row
      StateDirectory = "dns-query-exporter";

      # Environment variables
      Environment = [
        "TECHNITIUM_URL=http://10.88.0.1:5380"
        "LOKI_URL=http://localhost:3100"
        "POLL_INTERVAL=15"
        "STATE_FILE=/var/lib/dns-query-exporter/last_row.txt"
        "BATCH_SIZE=100"
        "METRICS_PORT=9275"
        "PYTHONUNBUFFERED=1"
      ];

      # Load Technitium API token from SOPS secret
      EnvironmentFile = config.sops.secrets."technitium-dns-exporter-env".path;

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ReadWritePaths = [ "/var/lib/dns-query-exporter" ];
    };

    # Use Python script we created
    script = ''
      export TECHNITIUM_TOKEN="$TECHNITIUM_API_DNS_TOKEN"
      exec ${pkgs.python3.withPackages (ps: [ ps.requests ps.prometheus-client ])}/bin/python3 \
        ${dns-query-log-exporter}/bin/dns-query-log-exporter
    '';
  };

  # Create user for the service
  users.users.dns-query-exporter = {
    isSystemUser = true;
    group = "dns-query-exporter";
    description = "DNS Query Log Exporter service user";
  };

  users.groups.dns-query-exporter = {};

  # SOPS secret configuration
  # Override quadlet's root:root to allow both container (root) and service (dns-query-exporter) to read
  sops.secrets."technitium-dns-exporter-env" = lib.mkForce {
    owner = "dns-query-exporter";
    group = "root";
    mode = "0440";  # Owner and group can read
    restartUnits = [ "dns-query-log-exporter.service" "technitium-dns-exporter.service" ];
  };

  # Prometheus scrape configuration for DNS query log metrics
  # Exposes metrics on port 9275
  services.prometheus.scrapeConfigs = [
    {
      job_name = "dns_query_logs";
      static_configs = [{
        targets = [ "localhost:9275" ];
        labels = {
          alias = "vulcan-dns-queries";
          role = "dns-logs";
          service = "dns-query-exporter";
        };
      }];
      # Scrape frequently to track query patterns
      scrape_interval = "15s";
      scrape_timeout = "10s";
    }
  ];
}
