{ config, lib, pkgs, ... }:

let
  mkMbsyncLib = import ../lib/mkMbsyncModule.nix { inherit config lib pkgs; };
  inherit (mkMbsyncLib) mkMbsyncService;
in
{
  imports = [
    # Johnw configuration
    (mkMbsyncService {
      name = "johnw";
      user = "johnw";
      group = "users";
      secretName = "johnw-fastmail-password";

      remoteConfig = ''
        Host imap.fastmail.com
        User johnw@newartisans.com
        PassCmd "cat /run/secrets/johnw-fastmail-password"
        TLSType IMAPS
        CertificateFile /etc/ssl/certs/ca-certificates.crt
        Port 993
        PipelineDepth 1
      '';

      channels = ''
        # Sync all folders from Fastmail (pull only)
        Channel fastmail-all
        Far :johnw-remote:
        Near :dovecot-local:
        Patterns *
        Create Near
        Remove None
        Expunge None
        Sync Pull
        SyncState /var/lib/mbsync-johnw/
        CopyArrivalDate yes
      '';

      timerInterval = "15min";

      extraServiceConfig = {
        RemainAfterExit = true;
      };
    })

    # Assembly configuration
    (mkMbsyncService {
      name = "assembly";
      user = "assembly";
      group = "assembly";
      secretName = "carmichael-imap-gmail-com";

      remoteConfig = ''
        Host imap.gmail.com
        User carmichaellsa@gmail.com
        PassCmd "cat /run/secrets/carmichael-imap-gmail-com"
        Port 993
        TLSType IMAPS
        CertificateFile /etc/ssl/certs/ca-certificates.crt
      '';

      channels = ''
        # Gmail to Dovecot channel
        Channel gmail-all
        Far :assembly-remote:
        Near :dovecot-local:
        Patterns * !"[Gmail]/All Mail" !"[Gmail]/Important" !"[Gmail]/Starred"
        Create Near
        Remove Near
        Expunge Near
        Sync Pull
        SyncState /var/lib/mbsync-assembly/
      '';

      timerInterval = "15min";

      extraServiceConfig = {
        RemainAfterExit = true;
      };
    })
  ];

  # Prometheus exporter for mbsync metrics
  services.prometheus.exporters.node.extraFlags = lib.mkAfter [
    "--collector.textfile.directory=/var/lib/mbsync-metrics"
  ];

  # Create metrics directory
  systemd.tmpfiles.rules = [
    "d /var/lib/mbsync-metrics 0755 root root -"
  ];

  # Install isync package to make mbsync available
  environment.systemPackages = [ pkgs.isync ];

  # Aggregate metrics from all mbsync instances
  systemd.services.mbsync-metrics-aggregator = {
    description = "Aggregate mbsync metrics for Prometheus";
    after = [ "mbsync-johnw.service" "mbsync-assembly.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "aggregate-mbsync-metrics" ''
        #!/bin/sh
        set -eu

        METRICS_DIR="/var/lib/mbsync-metrics"
        OUTPUT_FILE="$METRICS_DIR/mbsync.prom"

        # Clear existing file
        > "$OUTPUT_FILE.tmp"

        # Aggregate metrics from all mbsync instances
        for user in johnw assembly; do
          METRICS_FILE="/var/lib/mbsync-$user/metrics.prom"
          if [ -f "$METRICS_FILE" ]; then
            cat "$METRICS_FILE" >> "$OUTPUT_FILE.tmp"
          fi
        done

        # Add aggregation timestamp
        echo "# HELP mbsync_metrics_aggregation_timestamp Unix timestamp of last aggregation" >> "$OUTPUT_FILE.tmp"
        echo "# TYPE mbsync_metrics_aggregation_timestamp gauge" >> "$OUTPUT_FILE.tmp"
        echo "mbsync_metrics_aggregation_timestamp $(date +%s)" >> "$OUTPUT_FILE.tmp"

        # Atomic move
        mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
      '';
    };
  };

  # Timer to aggregate metrics regularly
  systemd.timers.mbsync-metrics-aggregator = {
    description = "Timer for mbsync metrics aggregation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };

  # Alert configuration for mbsync failures
  environment.etc."mbsync/alerts.yaml" = {
    text = ''
      groups:
        - name: mbsync_alerts
          interval: 30s
          rules:
            - alert: MbsyncSyncFailed
              expr: mbsync_last_sync_status == 0
              for: 5m
              labels:
                severity: warning
                service: mbsync
              annotations:
                summary: "Mbsync synchronization failed for {{ $labels.user }}"
                description: "Mbsync sync has been failing for more than 5 minutes"

            - alert: MbsyncSyncStale
              expr: (time() - mbsync_last_sync_timestamp) > 3600
              for: 5m
              labels:
                severity: warning
                service: mbsync
              annotations:
                summary: "Mbsync synchronization is stale for {{ $labels.user }}"
                description: "No successful sync in the last hour"
    '';
    mode = "0644";
  };
}
