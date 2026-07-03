{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Custom Prometheus exporter for the Schwab OAuth refresh-token lifetime.
  #
  # Context (memory: project_stock_trader): the Schwab refresh token dies ~every
  # 7 days. Renewal is a manual runbook (re-bootstrap on hera in a browser, push
  # the new token to vulcan, install 0600, restart stock-trader) and today it is
  # always REACTIVE — the trader breaks first, then we notice. This collector
  # turns that into a PROACTIVE signal: it reads the token file server-side and
  # exposes only the *expiry timestamp* (never any token value) so an alert can
  # fire ~2 days out, while the hera re-bootstrap is still comfortable.
  #
  # Token file: /var/lib/stock-trader/schwab_token.json (DynamicUser StateDirectory,
  # mode 0600, owned by an ephemeral uid → only root reads it reliably). The live
  # file (schwab-py / stock-trader format) carries ISO-8601 `refresh_expires_at`,
  # which is the authoritative refresh-token expiry — we read it directly rather
  # than re-derive it. Fallbacks (for older schwab-py token shapes that store a
  # top-level integer-epoch `creation_timestamp` instead): creation + 604800; and
  # if neither field is present, the file mtime + 604800 (7d Schwab lifetime).
  #
  # SECURITY: this script reads a secret file but emits ONLY integer epoch
  # timestamps to a world-readable 644 textfile. It NEVER writes token values.
  #
  # Metrics exposed:
  # - schwab_token_file_exists 1|0
  # - schwab_token_creation_timestamp_seconds <epoch>      (token issuance)
  # - schwab_refresh_token_expiry_timestamp_seconds <epoch> (refresh-token death)
  schwab-token-exporter = pkgs.writeShellApplication {
    name = "schwab-token-exporter";
    runtimeInputs = with pkgs; [
      jq
      coreutils
    ];
    text = ''
      # Prometheus textfile exporter for the Schwab OAuth refresh-token expiry.
      # Outputs metrics to /var/lib/prometheus-node-exporter-textfiles/schwab_token.prom

      TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"
      TEMP_FILE="$TEXTFILE_DIR/schwab_token.prom.$$"
      OUTPUT_FILE="$TEXTFILE_DIR/schwab_token.prom"
      TOKEN_FILE="/var/lib/stock-trader/schwab_token.json"

      # Schwab refresh-token lifetime (seconds) — 7 days. Only used by the
      # fallbacks; the live token file carries an authoritative expiry.
      REFRESH_LIFETIME=604800

      mkdir -p "$TEXTFILE_DIR"

      file_exists=0
      creation_ts=""
      expiry_ts=""

      if [ -f "$TOKEN_FILE" ]; then
        file_exists=1

        # Authoritative: ISO-8601 refresh_expires_at (current stock-trader /
        # schwab-py token shape). `date -d` parses the "+HH:MM" offset form.
        re_iso=$(jq -r '.refresh_expires_at // empty' "$TOKEN_FILE" 2>/dev/null || echo "")
        if [ -n "$re_iso" ]; then
          expiry_ts=$(date -d "$re_iso" +%s 2>/dev/null || echo "")
        fi

        # Older schwab-py shape: top-level integer-epoch creation_timestamp.
        creation_raw=$(jq -r '.creation_timestamp // empty' "$TOKEN_FILE" 2>/dev/null || echo "")
        if printf '%s' "$creation_raw" | grep -Eq '^[0-9]+$'; then
          creation_ts="$creation_raw"
          # Fallback expiry if the ISO field was missing/unparsable.
          if [ -z "$expiry_ts" ]; then
            expiry_ts=$((creation_ts + REFRESH_LIFETIME))
          fi
        fi

        # If we have an expiry but no explicit creation, derive issuance as
        # expiry - lifetime so the creation metric still carries signal.
        if [ -z "$creation_ts" ] && [ -n "$expiry_ts" ]; then
          creation_ts=$((expiry_ts - REFRESH_LIFETIME))
        fi

        # Last-resort fallback: file mtime (token was written at renewal).
        if [ -z "$creation_ts" ]; then
          creation_ts=$(stat -c '%Y' "$TOKEN_FILE" 2>/dev/null || echo "")
        fi
        if [ -z "$expiry_ts" ] && [ -n "$creation_ts" ]; then
          expiry_ts=$((creation_ts + REFRESH_LIFETIME))
        fi
      fi

      {
        echo "# HELP schwab_token_file_exists Schwab OAuth token file present on disk (1=yes, 0=no)"
        echo "# TYPE schwab_token_file_exists gauge"
        echo "schwab_token_file_exists $file_exists"

        if [ -n "$creation_ts" ]; then
          echo "# HELP schwab_token_creation_timestamp_seconds Unix timestamp the Schwab token was issued"
          echo "# TYPE schwab_token_creation_timestamp_seconds gauge"
          echo "schwab_token_creation_timestamp_seconds $creation_ts"
        fi

        if [ -n "$expiry_ts" ]; then
          echo "# HELP schwab_refresh_token_expiry_timestamp_seconds Unix timestamp the Schwab refresh token expires (re-bootstrap before this)"
          echo "# TYPE schwab_refresh_token_expiry_timestamp_seconds gauge"
          echo "schwab_refresh_token_expiry_timestamp_seconds $expiry_ts"
        fi
      } > "$TEMP_FILE"

      # Atomic move to prevent partial reads
      mv "$TEMP_FILE" "$OUTPUT_FILE"
      chmod 644 "$OUTPUT_FILE"
    '';
  };
in
{
  # ============================================================================
  # Schwab OAuth Refresh-Token Expiry Prometheus Exporter
  # Custom exporter using textfile collector — proactive token-death warning
  # (docs/MONITORING_COVERAGE_PLAN.md P0 #15)
  # ============================================================================

  systemd.timers."schwab-token-exporter" = {
    description = "Schwab OAuth Refresh-Token Expiry Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "30s";
      AccuracySec = "1min";
      Unit = "schwab-token-exporter.service";
      Persistent = true;
    };
  };

  systemd.services."schwab-token-exporter" = {
    description = "Schwab OAuth Refresh-Token Expiry Exporter";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe schwab-token-exporter}";
      # Root needed: the token file lives under a DynamicUser StateDirectory
      # (mode 0600, ephemeral uid). Reads only a timestamp; writes only epochs.
      User = "root";
      Group = "root";
      TimeoutStartSec = "30s";
      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      LockPersonality = true;
      # Read-only access to the token directory; the symlink + DynamicUser
      # real path both live under /var/lib, covered by these read paths.
      ReadOnlyPaths = [
        "/var/lib/stock-trader"
        "/var/lib/private/stock-trader"
      ];
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
    };
  };
}
