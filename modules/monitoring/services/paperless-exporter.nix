{ config, lib, pkgs, ... }:

let
  # Script that checks Paperless-ngx health via API
  paperlessHealthCheck = pkgs.writeShellScript "paperless-health-check" ''
    set -euo pipefail

    API_URL="http://127.0.0.1:${toString config.services.paperless.port}/api"

    # Check if service is responding
    HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
      "$API_URL/" \
      --max-time 10 \
      --connect-timeout 5) || HTTP_CODE=0

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "302" ]; then
      # 401 is expected without auth, 302 is redirect - both mean service is up
      echo "paperless_up 1"

      # Try to get task queue stats (requires auth, so this might fail)
      # For now, just mark service as healthy if it responds
      echo "# Last successful check: $(date -Iseconds)"
    else
      echo "paperless_up 0"
      echo "# HTTP error: $HTTP_CODE"
    fi
  '';

  # Script that checks document processing queue
  paperlessQueueCheck = pkgs.writeShellScript "paperless-queue-check" ''
    set -euo pipefail

    # Check systemd services for paperless components
    SCHEDULER_ACTIVE=0
    CONSUMER_ACTIVE=0
    WEBSERVER_ACTIVE=0

    if systemctl is-active --quiet paperless-scheduler.service; then
      SCHEDULER_ACTIVE=1
    fi

    if systemctl is-active --quiet paperless-consumer.service; then
      CONSUMER_ACTIVE=1
    fi

    if systemctl is-active --quiet paperless-web.service; then
      WEBSERVER_ACTIVE=1
    fi

    echo "paperless_scheduler_active $SCHEDULER_ACTIVE"
    echo "paperless_consumer_active $CONSUMER_ACTIVE"
    echo "paperless_webserver_active $WEBSERVER_ACTIVE"

    # Check consumption directory for pending documents
    CONSUME_DIR="${config.services.paperless.consumptionDir}"
    if [ -d "$CONSUME_DIR" ]; then
      PENDING_DOCS=$(find "$CONSUME_DIR" -type f \( \
        -name "*.pdf" -o -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \
        -o -name "*.tiff" -o -name "*.tif" -o -name "*.doc" -o -name "*.docx" \
        -o -name "*.xls" -o -name "*.xlsx" -o -name "*.ppt" -o -name "*.pptx" \
      \) 2>/dev/null | wc -l) || PENDING_DOCS=0
      echo "paperless_pending_documents $PENDING_DOCS"
    else
      echo "paperless_pending_documents 0"
    fi

    # Check data directory size (suppress permission errors)
    DATA_DIR="${config.services.paperless.dataDir}"
    if [ -d "$DATA_DIR" ]; then
      DATA_SIZE_MB=$(du -sm "$DATA_DIR" 2>/dev/null | cut -f1) || DATA_SIZE_MB=0
      echo "paperless_data_size_mb $DATA_SIZE_MB"
    else
      echo "paperless_data_size_mb 0"
    fi

    # Check media directory size (suppress permission errors)
    MEDIA_DIR="${config.services.paperless.mediaDir}"
    if [ -d "$MEDIA_DIR" ]; then
      MEDIA_SIZE_MB=$(du -sm "$MEDIA_DIR" 2>/dev/null | cut -f1) || MEDIA_SIZE_MB=0
      echo "paperless_media_size_mb $MEDIA_SIZE_MB"
    else
      echo "paperless_media_size_mb 0"
    fi
  '';

  # Prometheus textfile exporter script
  exporterScript = pkgs.writeShellScript "paperless-exporter" ''
    set -euo pipefail

    METRICS_DIR="/var/lib/prometheus-node-exporter-textfiles"
    METRICS_FILE="$METRICS_DIR/paperless.prom"
    TEMP_FILE="$METRICS_DIR/paperless.prom.$$"

    # Ensure directory exists
    mkdir -p "$METRICS_DIR"

    # Run health checks and write to temp file
    {
      echo "# HELP paperless_up Paperless-ngx service availability (1=up, 0=down)"
      echo "# TYPE paperless_up gauge"
      echo "# HELP paperless_scheduler_active Paperless scheduler service status"
      echo "# TYPE paperless_scheduler_active gauge"
      echo "# HELP paperless_consumer_active Paperless consumer service status"
      echo "# TYPE paperless_consumer_active gauge"
      echo "# HELP paperless_webserver_active Paperless webserver service status"
      echo "# TYPE paperless_webserver_active gauge"
      echo "# HELP paperless_pending_documents Number of documents pending processing"
      echo "# TYPE paperless_pending_documents gauge"
      echo "# HELP paperless_data_size_mb Size of paperless data directory in MB"
      echo "# TYPE paperless_data_size_mb gauge"
      echo "# HELP paperless_media_size_mb Size of paperless media directory in MB"
      echo "# TYPE paperless_media_size_mb gauge"

      ${paperlessHealthCheck} || echo "paperless_up 0"
      ${paperlessQueueCheck}
    } > "$TEMP_FILE"

    # Atomic move
    mv "$TEMP_FILE" "$METRICS_FILE"
  '';
in
{
  # Systemd service to run the exporter
  systemd.services.paperless-exporter = {
    description = "Paperless-ngx Prometheus Exporter";
    after = [ "paperless-scheduler.service" "node-exporter.service" ];
    requires = [ "paperless-scheduler.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = exporterScript;
      User = "node-exporter";
      Group = "node-exporter";
    };
  };

  # Timer to run every 5 minutes
  systemd.timers.paperless-exporter = {
    description = "Paperless-ngx Prometheus Exporter Timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Unit = "paperless-exporter.service";
    };
  };
}
