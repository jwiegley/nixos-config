{
  config,
  lib,
  pkgs,
  ...
}:

let
  publishDir = "/var/lib/calendar-publisher";
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  outputFile = "${textfileDir}/calendar_publisher.prom";

  # End-to-end health check: hit the public URL the way subscribers do, so
  # this single fetch exercises DNS, the Cloudflare edge, the cloudflared
  # tunnel, nginx on 127.0.0.1:8090, and the file on disk in one shot. We
  # pick cluster.ics because it's the canonical "everything" calendar.
  publicUrl = "https://calendar.newartisans.com/cluster.ics";

  healthScript = pkgs.writeShellScript "calendar-publisher-health" ''
    set -euo pipefail

    NOW=$(${pkgs.coreutils}/bin/date +%s)

    # File metrics across all .ics outputs.
    FILE_COUNT=$(${pkgs.findutils}/bin/find ${publishDir} -maxdepth 1 -name '*.ics' -type f 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
    TOTAL_BYTES=$(${pkgs.findutils}/bin/find ${publishDir} -maxdepth 1 -name '*.ics' -type f -printf '%s\n' 2>/dev/null | ${pkgs.gawk}/bin/awk '{s+=$1} END {print s+0}')
    NEWEST_MTIME=$(${pkgs.findutils}/bin/find ${publishDir} -maxdepth 1 -name '*.ics' -type f -printf '%T@\n' 2>/dev/null | ${pkgs.coreutils}/bin/sort -n | ${pkgs.coreutils}/bin/tail -n 1 | ${pkgs.coreutils}/bin/cut -d. -f1)
    NEWEST_MTIME=''${NEWEST_MTIME:-0}

    # Last calendar-publisher.service Result. For a Type=oneshot unit
    # `systemctl show -p Result --value` survives across reboots.
    SVC_RESULT=$(${pkgs.systemd}/bin/systemctl show -p Result --value calendar-publisher.service 2>/dev/null || echo unknown)
    case "$SVC_RESULT" in
      success) SVC_OK=1 ;;
      "")      SVC_OK=-1 ;;
      *)       SVC_OK=0 ;;
    esac

    # Timer LastTriggerUSec is the most reliable "did it fire" signal.
    LAST_TRIG=$(${pkgs.systemd}/bin/systemctl show -p LastTriggerUSec --value calendar-publisher.timer 2>/dev/null || echo "")
    if [ -n "$LAST_TRIG" ] && [ "$LAST_TRIG" != "n/a" ] && [ "$LAST_TRIG" != "0" ]; then
      LAST_TRIG_EPOCH=$(${pkgs.coreutils}/bin/date -d "$LAST_TRIG" +%s 2>/dev/null || echo 0)
    else
      LAST_TRIG_EPOCH=0
    fi

    # End-to-end fetch. PrivateTmp gives us a writable scratch dir.
    TMP_BODY=$(${pkgs.coreutils}/bin/mktemp)
    trap 'rm -f "$TMP_BODY"' EXIT

    URL_CODE=$(${pkgs.curl}/bin/curl \
      --silent --location --max-time 15 \
      --output "$TMP_BODY" \
      --write-out '%{http_code}' \
      ${lib.escapeShellArg publicUrl} 2>/dev/null || echo "000")

    URL_BYTES=$(${pkgs.coreutils}/bin/wc -c < "$TMP_BODY" | ${pkgs.gawk}/bin/awk '{print $1}')
    URL_HEADER=$(${pkgs.coreutils}/bin/head -c 32 "$TMP_BODY" 2>/dev/null || true)

    if [ "$URL_CODE" = "200" ] && printf '%s' "$URL_HEADER" | ${pkgs.gnugrep}/bin/grep -q '^BEGIN:VCALENDAR'; then
      URL_UP=1
    else
      URL_UP=0
    fi

    TEMP_OUT=${outputFile}.$$
    ${pkgs.coreutils}/bin/cat > "$TEMP_OUT" <<EOF
    # HELP calendar_publisher_check_timestamp_seconds Unix time of the last calendar-publisher-health run
    # TYPE calendar_publisher_check_timestamp_seconds gauge
    calendar_publisher_check_timestamp_seconds $NOW

    # HELP calendar_publisher_output_mtime_seconds Mtime of the most recently written .ics file in ${publishDir}
    # TYPE calendar_publisher_output_mtime_seconds gauge
    calendar_publisher_output_mtime_seconds $NEWEST_MTIME

    # HELP calendar_publisher_output_file_count Number of .ics files in ${publishDir}
    # TYPE calendar_publisher_output_file_count gauge
    calendar_publisher_output_file_count $FILE_COUNT

    # HELP calendar_publisher_output_bytes_total Total bytes across all .ics files in ${publishDir}
    # TYPE calendar_publisher_output_bytes_total gauge
    calendar_publisher_output_bytes_total $TOTAL_BYTES

    # HELP calendar_publisher_service_result Last calendar-publisher.service Result (1=success, 0=failure, -1=unknown)
    # TYPE calendar_publisher_service_result gauge
    calendar_publisher_service_result $SVC_OK

    # HELP calendar_publisher_timer_last_trigger_seconds Unix time of the last calendar-publisher.timer trigger
    # TYPE calendar_publisher_timer_last_trigger_seconds gauge
    calendar_publisher_timer_last_trigger_seconds $LAST_TRIG_EPOCH

    # HELP calendar_publisher_url_up Whether the public calendar URL returns HTTP 200 with a VCALENDAR body
    # TYPE calendar_publisher_url_up gauge
    calendar_publisher_url_up{url="${publicUrl}"} $URL_UP

    # HELP calendar_publisher_url_status_code Last HTTP status code observed for the public calendar URL (000 = transport failure)
    # TYPE calendar_publisher_url_status_code gauge
    calendar_publisher_url_status_code{url="${publicUrl}"} $URL_CODE

    # HELP calendar_publisher_url_body_bytes Body size in bytes for the last fetch of the public calendar URL
    # TYPE calendar_publisher_url_body_bytes gauge
    calendar_publisher_url_body_bytes{url="${publicUrl}"} $URL_BYTES
    EOF

    ${pkgs.coreutils}/bin/mv "$TEMP_OUT" ${outputFile}
    ${pkgs.coreutils}/bin/chmod 644 ${outputFile}
  '';
in
{
  # Daily health check for the Sacramento Cluster calendar mirror.
  #
  # Verifies that calendar-publisher.service is producing fresh .ics output
  # AND that the public URL (cloudflared tunnel + nginx) is still serving a
  # valid VCALENDAR. Writes a Prometheus textfile-collector .prom; alert
  # rules in modules/monitoring/alerts/calendar-publisher.yaml decide when
  # to page.

  systemd.services.calendar-publisher-health = {
    description = "Health-check metrics for the Sacramento Cluster calendar mirror";
    after = [
      "network-online.target"
      "calendar-publisher.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = healthScript;

      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ReadOnlyPaths = [ publishDir ];
      ReadWritePaths = [ textfileDir ];
    };
  };

  systemd.timers.calendar-publisher-health = {
    description = "Daily timer for calendar-publisher health check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Publisher fires at 04:00 + up to 5m random delay and typically
      # finishes in seconds. 05:00 gives ample slack for a slow run.
      OnCalendar = "*-*-* 05:00:00";
      OnBootSec = "15min";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
