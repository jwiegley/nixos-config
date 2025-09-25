{ config, lib, pkgs, ... }:

{
  # Prometheus exporter for mbsync metrics (serves metrics for all mbsync users)
  systemd.services.mbsync-metrics-exporter = {
    description = "Export mbsync metrics for Prometheus (all users)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "nobody";
      Group = "nogroup";
      Restart = "always";
      RestartSec = "10s";

      ExecStart = pkgs.writeShellScript "mbsync-metrics-server" ''
        #!/usr/bin/env bash
        set -euo pipefail

        PORT=9280

        # Simple HTTP server using netcat
        while true; do
          {
            # Collect metrics from all mbsync users
            METRICS=""
            
            # Assembly user metrics
            if [ -f "/var/lib/mbsync-assembly/metrics" ]; then
              while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                  METRICS="$METRICS$line"$'\n'
                fi
              done < "/var/lib/mbsync-assembly/metrics"
            else
              METRICS="$METRICS# No metrics found for assembly user"$'\n'
            fi
            
            # Johnw user metrics
            if [ -f "/var/lib/mbsync-johnw/metrics" ]; then
              while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                  METRICS="$METRICS$line"$'\n'
                fi
              done < "/var/lib/mbsync-johnw/metrics"
            else
              METRICS="$METRICS# No metrics found for johnw user"$'\n'
            fi
            
            # If no metrics at all, provide defaults
            if [ -z "$METRICS" ]; then
              METRICS="mbsync_sync_status 0"
            fi

            # Add help text and type information
            RESPONSE="# HELP mbsync_assembly_sync_status Whether the last sync was successful (1) or failed (0) for assembly user
# TYPE mbsync_assembly_sync_status gauge
# HELP mbsync_assembly_last_success_timestamp Unix timestamp of last successful sync for assembly user
# TYPE mbsync_assembly_last_success_timestamp gauge
# HELP mbsync_assembly_last_failure_timestamp Unix timestamp of last failed sync for assembly user
# TYPE mbsync_assembly_last_failure_timestamp gauge
# HELP mbsync_assembly_inbox_messages Number of messages in INBOX for assembly user
# TYPE mbsync_assembly_inbox_messages gauge
# HELP mbsync_johnw_sync_status Whether the last sync was successful (1) or failed (0) for johnw user
# TYPE mbsync_johnw_sync_status gauge
# HELP mbsync_johnw_last_success_timestamp Unix timestamp of last successful sync for johnw user
# TYPE mbsync_johnw_last_success_timestamp gauge
# HELP mbsync_johnw_last_failure_timestamp Unix timestamp of last failed sync for johnw user
# TYPE mbsync_johnw_last_failure_timestamp gauge
# HELP mbsync_johnw_inbox_messages Number of messages in INBOX for johnw user
# TYPE mbsync_johnw_inbox_messages gauge
$METRICS"

            # Send HTTP response
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$RESPONSE"
          } | ${pkgs.netcat}/bin/nc -l -p "$PORT" -q 1
        done
      '';

      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadOnlyPaths = [ 
        "/var/lib/mbsync-assembly/metrics" 
        "/var/lib/mbsync-johnw/metrics" 
      ];
    };

    path = [ pkgs.coreutils pkgs.netcat ];
  };

  # Add mbsync monitoring to Prometheus
  services.prometheus.scrapeConfigs = lib.mkIf config.services.prometheus.enable [
    {
      job_name = "mbsync";
      static_configs = [{
        targets = [ "localhost:9280" ];
        labels = {
          service = "mbsync";
        };
      }];
      scrape_interval = "60s";
    }
  ];

  # Open firewall port for metrics exporter (internal only)
  networking.firewall.interfaces.lo.allowedTCPPorts = [ 9280 ];
}
