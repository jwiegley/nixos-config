{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  outputFile = "${textfileDir}/nodered_safety.prom";

  # The Node-RED "Away" tab (id ba13e5bae3dfce24) is the home-safety alerting
  # layer (leak / high-flow / door-open+unlocked / freeze, scanned per minute).
  # Every node it touches logs a row to PostgreSQL DB `nodered_events`,
  # partitioned table `msg_events` (column `ts`). Live baseline: ~4 events/min
  # (~243/hour). If the flow dies (deploy error, websocket auth drop, crash),
  # nothing else notices — so this deadman watches the freshness of that log.
  safetyTabId = "ba13e5bae3dfce24";

  exporterScript = pkgs.writeShellScript "nodered-safety-exporter" ''
    set -euo pipefail

    NOW=$(${pkgs.coreutils}/bin/date +%s)

    # Read-only, timestamps only — NEVER select the payload column. The query
    # runs as the `postgres` system user via local peer auth (same idiom as
    # node-red-event-logger.nix). A 1-day window bounds the partition scan and
    # keeps the gauge from chasing very old rows; COALESCE(...,0) yields 0 when
    # the Away tab has logged nothing in the last day (a stalled flow), which
    # makes `time() - 0` enormous and trips the alert.
    LAST_EVENT=$(${pkgs.util-linux}/bin/runuser -u postgres -- \
      ${pkgs.postgresql}/bin/psql -d nodered_events -tAc \
      "SELECT COALESCE(EXTRACT(EPOCH FROM max(ts)),0)::bigint FROM msg_events WHERE tab_id='${safetyTabId}' AND ts > now() - interval '1 day'" \
      2>/dev/null) || LAST_EVENT=""
    LAST_EVENT=''${LAST_EVENT:-0}
    # Defend against any non-numeric output (psql error text, etc.).
    # LAST_EVENT is already defaulted to a non-empty "0" above, so the only
    # case to reject is a value containing a non-digit.
    case "$LAST_EVENT" in
      *[!0-9]*) LAST_EVENT=0 ;;
    esac

    TEMP_OUT=${outputFile}.$$
    ${pkgs.coreutils}/bin/cat > "$TEMP_OUT" <<EOF
    # HELP nodered_safety_last_event_timestamp_seconds Unix time of the most recent msg_events row logged by the Node-RED Away/safety tab (${safetyTabId}) within the last day; 0 if none
    # TYPE nodered_safety_last_event_timestamp_seconds gauge
    nodered_safety_last_event_timestamp_seconds{tab_id="${safetyTabId}"} $LAST_EVENT

    # HELP nodered_safety_exporter_run_timestamp_seconds Unix time of the last nodered-safety-exporter run (distinguishes a dead collector from a dead flow)
    # TYPE nodered_safety_exporter_run_timestamp_seconds gauge
    nodered_safety_exporter_run_timestamp_seconds $NOW
    EOF

    ${pkgs.coreutils}/bin/mv "$TEMP_OUT" ${outputFile}
    ${pkgs.coreutils}/bin/chmod 644 ${outputFile}
  '';
in
{
  # Deadman's switch for the Node-RED home-safety flow.
  #
  # Runs as root (matching calendar-publisher-health.nix / container-health-
  # exporter.nix), shelling the SELECT out to the `postgres` user via runuser
  # so the DB read uses local peer auth and the textfile lands root:root 644
  # like every other collector. SELECT-only, timestamps only — no payload.
  # Alert rules live in modules/monitoring/alerts/node-red-safety.yaml.

  systemd.services.nodered-safety-exporter = {
    description = "Deadman exporter for the Node-RED home-safety (Away) flow";
    after = [
      "network.target"
      "postgresql.service"
    ];
    wants = [ "postgresql.service" ];
    # No wantedBy - service only runs via timer.

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = exporterScript;

      # runuser needs to switch users, so NoNewPrivileges must stay off.
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ReadWritePaths = [ textfileDir ];
    };
  };

  systemd.timers.nodered-safety-exporter = {
    description = "Timer for the Node-RED home-safety deadman exporter";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "60s"; # 1 minute — flow logs ~4 events/min
      AccuracySec = "5s";
    };
  };
}
