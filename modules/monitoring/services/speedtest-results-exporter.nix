{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  outputFile = "${textfileDir}/speedtest_results.prom";

  # speedtest-tracker (rootless container, vhost https://speedtracker.vulcan.lan)
  # persists every run to the PostgreSQL DB `speedtest_tracker`, table `results`
  # (columns verified: created_at timestamp, download/upload bigint = bits/sec,
  # status varchar). A green container + blackbox 2xx says nothing about whether
  # the hourly speedtest actually COMPLETED and recorded a result — the schedule
  # can silently stop, or every run can come back `failed`, and the web UI keeps
  # serving the last good row. This collector reads the newest COMPLETED row and
  # emits its timestamp + throughput so we can alert on results going stale or
  # bandwidth collapsing. Correctness signal, not soundness (soundness is the
  # existing blackbox probe in speedtest-tracker.yaml).
  exporterScript = pkgs.writeShellScript "speedtest-results-exporter" ''
    set -euo pipefail

    NOW=$(${pkgs.coreutils}/bin/date +%s)

    # Read-only, numeric/status columns only — NEVER select the `data`/`benchmarks`
    # JSON or `comments`. The query runs as the `postgres` system user via local
    # peer auth (same idiom as nodered-safety-exporter.nix). Newest COMPLETED row
    # only: a `failed` run leaves download/upload NULL and should not masquerade
    # as a fresh result. Output is a single pipe-delimited line:
    #   <epoch>|<download_bps>|<upload_bps>
    # COALESCE(...,0) on every field yields all-zero when the table is empty or
    # has no completed rows, making `time() - 0` enormous → staleness trips.
    ROW=$(${pkgs.util-linux}/bin/runuser -u postgres -- \
      ${pkgs.postgresql}/bin/psql -d speedtest_tracker -tAc \
      "SELECT COALESCE(EXTRACT(EPOCH FROM created_at),0)::bigint || '|' || COALESCE(download,0) || '|' || COALESCE(upload,0) FROM results WHERE status='completed' ORDER BY created_at DESC LIMIT 1" \
      2>/dev/null) || ROW=""
    ROW=''${ROW:-0|0|0}

    LAST_TS=''${ROW%%|*}
    REST=''${ROW#*|}
    DOWNLOAD=''${REST%%|*}
    UPLOAD=''${REST##*|}

    # Defend against any non-numeric output (psql error text, empty fields, etc.).
    LAST_TS=''${LAST_TS:-0}
    DOWNLOAD=''${DOWNLOAD:-0}
    UPLOAD=''${UPLOAD:-0}
    case "$LAST_TS" in *[!0-9]*) LAST_TS=0 ;; esac
    case "$DOWNLOAD" in *[!0-9]*) DOWNLOAD=0 ;; esac
    case "$UPLOAD" in *[!0-9]*) UPLOAD=0 ;; esac

    TEMP_OUT=${outputFile}.$$
    ${pkgs.coreutils}/bin/cat > "$TEMP_OUT" <<EOF
    # HELP speedtest_last_result_timestamp_seconds Unix time of the newest completed speedtest result row (created_at); 0 if none
    # TYPE speedtest_last_result_timestamp_seconds gauge
    speedtest_last_result_timestamp_seconds $LAST_TS

    # HELP speedtest_last_download_bps Download throughput (bits/sec) of the newest completed speedtest result; 0 if none
    # TYPE speedtest_last_download_bps gauge
    speedtest_last_download_bps $DOWNLOAD

    # HELP speedtest_last_upload_bps Upload throughput (bits/sec) of the newest completed speedtest result; 0 if none
    # TYPE speedtest_last_upload_bps gauge
    speedtest_last_upload_bps $UPLOAD

    # HELP speedtest_results_exporter_run_timestamp_seconds Unix time of the last speedtest-results-exporter run (distinguishes a dead collector from a stalled speedtest schedule)
    # TYPE speedtest_results_exporter_run_timestamp_seconds gauge
    speedtest_results_exporter_run_timestamp_seconds $NOW
    EOF

    ${pkgs.coreutils}/bin/mv "$TEMP_OUT" ${outputFile}
    ${pkgs.coreutils}/bin/chmod 644 ${outputFile}
  '';
in
{
  # Results-freshness / throughput collector for speedtest-tracker.
  #
  # Runs as root (matching nodered-safety-exporter.nix / container-health-
  # exporter.nix), shelling the SELECT out to the `postgres` user via runuser so
  # the DB read uses local peer auth and the textfile lands root:root 644 like
  # every other collector. SELECT-only, numeric/status columns only — no payload.
  # Alert rules live in modules/monitoring/alerts/speedtest-tracker.yaml.

  systemd.services.speedtest-results-exporter = {
    description = "Result-freshness/throughput exporter for speedtest-tracker";
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

  systemd.timers.speedtest-results-exporter = {
    description = "Timer for the speedtest-tracker results exporter";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "15min"; # speedtest runs hourly; 15-min poll is plenty
      AccuracySec = "30s";
    };
  };
}
