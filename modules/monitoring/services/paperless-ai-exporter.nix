{ config, lib, pkgs, ... }:

{
  # Prometheus exporter for paperless-ai service
  # Monitors service availability and container status

  # Note: textfiles directory is managed by node-exporter service

  systemd.services.paperless-ai-exporter = {
    description = "Paperless-AI Prometheus Exporter";
    after = [ "paperless-ai.service" "prometheus-node-exporter.service" ];
    wants = [ "paperless-ai.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";

      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
    };

    script = let
      healthCheck = pkgs.writeShellScript "paperless-ai-health-check" ''
        set -euo pipefail

        METRICS_FILE="/var/lib/prometheus-node-exporter-textfiles/paperless_ai.prom"

        # Check if paperless-ai web interface is responding
        HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
          http://127.0.0.1:3001/ --max-time 10 --connect-timeout 5) || HTTP_CODE=0

        # Check if systemd service is active (better than checking container directly)
        if ${pkgs.systemd}/bin/systemctl is-active --quiet paperless-ai.service; then
          SERVICE_RUNNING=1
        else
          SERVICE_RUNNING=0
        fi

        # Write metrics
        {
          echo "# HELP paperless_ai_up Whether the paperless-ai service is responding (1 = up, 0 = down)"
          echo "# TYPE paperless_ai_up gauge"
          if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
            echo "paperless_ai_up 1"
          else
            echo "paperless_ai_up 0"
          fi

          echo "# HELP paperless_ai_service_active Whether the paperless-ai systemd service is active"
          echo "# TYPE paperless_ai_service_active gauge"
          echo "paperless_ai_service_active $SERVICE_RUNNING"

          echo "# HELP paperless_ai_http_response_code HTTP response code from health check"
          echo "# TYPE paperless_ai_http_response_code gauge"
          echo "paperless_ai_http_response_code $HTTP_CODE"
        } > "$METRICS_FILE.tmp"

        mv "$METRICS_FILE.tmp" "$METRICS_FILE"

        # Set proper permissions
        chown node-exporter:node-exporter "$METRICS_FILE"
        chmod 644 "$METRICS_FILE"
      '';
    in ''
      ${healthCheck}
    '';
  };

  # Run exporter every 30 seconds
  systemd.timers.paperless-ai-exporter = {
    description = "Paperless-AI Prometheus Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
      Unit = "paperless-ai-exporter.service";
    };
  };
}
