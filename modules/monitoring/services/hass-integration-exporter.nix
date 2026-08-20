# Home Assistant integration health as Prometheus metrics.
#
# This is the ONE capability the Nagios retirement audit found to be genuinely unique: no
# Prometheus rule anywhere watches whether an HA *integration* is loaded. Disproving queries
# were run -- {__name__=~".*integration.*"} returns only alertmanager_integrations and
# grafana_alerting_alertmanager_integrations, and {__name__=~"hass.*|home_assistant.*"}
# returns only home_assistant_backup_* and hass_entity_*.
#
# It matters because the failure is invisible to everything else already deployed:
# SystemdServiceFailed on home-assistant.service reads healthy, and the hass.vulcan.lan
# blackbox probe returns 200, straight through an integration that has stopped working. That
# is the 2025-10-27 OAuth-token failure, and the BMW CarData and opnsense ones.
#
# hass_entity_unavailable_by_domain was considered as a cheap proxy and REJECTED: it is a
# live but orphaned collector (161 unavailable entities right now, referenced by zero rules),
# yet it measures entity availability, not config-entry health. Its 30d range is 160-254 with
# six >50-entity jumps, and an HA restart produces the same signature as an integration drop,
# so any threshold over it is either noisy or blind. This asks the same question Nagios did,
# of the same endpoint.
#
# NO NEW SECRET. sops.secrets."monitoring/home-assistant-token" is declared below and read
# from its path at runtime; it never enters the Nix store. The declaration used to live in
# modules/monitoring/homeassistant-nagios-check.nix and moved here when Nagios was removed.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # This list was inherited verbatim from the Nagios check this exporter replaced, so the
  # retirement was a like-for-like swap rather than a silent change of scope. Adding to it
  # is now a deliberate widening, not a restoration.
  integrations = [
    "august"
    "nest"
    "ring"
    "enphase_envoy"
    "flume"
    "miele"
    "lg_thinq"
    "cast"
    "withings"
    "webostv"
    "homekit"
    "nws"
  ];

  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  tokenPath = config.sops.secrets."monitoring/home-assistant-token".path;

  exporter = pkgs.writeShellApplication {
    name = "hass-integration-exporter";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      OUT="${textfileDir}/hass_integrations.prom"
      TMP="$(mktemp "${textfileDir}/hass_integrations.XXXXXX.tmp")"
      # Never leave a stale .tmp behind if curl or jq fails midway.
      trap 'rm -f "$TMP"' EXIT

      emit_header() {
        {
          echo "# HELP hass_integration_loaded 1 if the integration appears in Home Assistant's loaded components, 0 if not."
          echo "# TYPE hass_integration_loaded gauge"
        } >> "$TMP"
      }

      if [ ! -r "${tokenPath}" ]; then
        # Fail VISIBLY rather than writing a file full of zeros, which would look like
        # twelve simultaneous integration failures.
        {
          echo "# HELP hass_integration_check_up 1 if the exporter reached the HA API."
          echo "# TYPE hass_integration_check_up gauge"
          echo "hass_integration_check_up 0"
          echo "# HELP hass_integration_check_last_run_timestamp_seconds Unix time of the last completed run."
          echo "# TYPE hass_integration_check_last_run_timestamp_seconds gauge"
          echo "hass_integration_check_last_run_timestamp_seconds $(date +%s)"
        } > "$TMP"
        mv "$TMP" "$OUT"
        trap - EXIT
        echo "hass-integration-exporter: token unreadable at ${tokenPath}" >&2
        exit 0
      fi

      TOKEN="$(cat "${tokenPath}")"

      # -sS so transport failures surface on stderr; the body is the only thing captured.
      if ! BODY="$(curl -sS --max-time 20 \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            http://127.0.0.1:8123/api/config 2>/dev/null)"; then
        BODY=""
      fi

      COMPONENTS="$(printf '%s' "$BODY" | jq -r '.components[]?' 2>/dev/null || true)"

      : > "$TMP"
      if [ -z "$COMPONENTS" ]; then
        # API unreachable or unparseable. Emit up=0 and NO per-integration series: a zero for
        # every integration would be indistinguishable from all twelve failing at once.
        {
          echo "# HELP hass_integration_check_up 1 if the exporter reached the HA API."
          echo "# TYPE hass_integration_check_up gauge"
          echo "hass_integration_check_up 0"
        } >> "$TMP"
      else
        {
          echo "# HELP hass_integration_check_up 1 if the exporter reached the HA API."
          echo "# TYPE hass_integration_check_up gauge"
          echo "hass_integration_check_up 1"
        } >> "$TMP"
        emit_header
        for i in ${lib.concatStringsSep " " integrations}; do
          if printf '%s\n' "$COMPONENTS" | grep -qx "$i"; then
            echo "hass_integration_loaded{integration=\"$i\"} 1" >> "$TMP"
          else
            echo "hass_integration_loaded{integration=\"$i\"} 0" >> "$TMP"
          fi
        done

        # CONFIG ENTRY STATE -- a DIFFERENT thing from the component load above,
        # and the reason this block exists (nixos-fgp).
        #
        # On 2026-08-17 three Google Calendar config entries sat in setup_error
        # for two days with a rejected OAuth refresh token, and nothing here
        # noticed. The obvious repair -- add "google" to the integrations list
        # above -- would have been a NO-OP that looked like coverage:
        # hass_integration_loaded reports whether the COMPONENT is in HA's
        # loaded_components, and the google component was loaded fine. It was the
        # ENTRIES that failed. Every one of the twelve integrations above has the
        # same blind spot.
        #
        # /api/config/config_entries/entry is a real REST endpoint and the
        # existing token already authorises it (verified 2026-08-19: HTTP 200, 90
        # entries). No new secret, no websocket client.
        #
        # DELIBERATELY AGGREGATED BY domain+state, not emitted per entry. Entry
        # titles are account identifiers -- email addresses for the Google
        # entries -- and a Prometheus label is forever. Domain and state are
        # enough to alert on and carry no PII. Cardinality is bounded by the
        # entries that actually exist, ~90 series today.
        ENTRIES="$(curl -sS --max-time 20 \
              -H "Authorization: Bearer $TOKEN" \
              -H "Content-Type: application/json" \
              http://127.0.0.1:8123/api/config/config_entries/entry 2>/dev/null || true)"

        # Only emit when the response is the array we expect. A failure here must
        # not fabricate zeros: absent series read as "unknown" to the alert below,
        # whereas a zero would read as "everything is healthy".
        if printf '%s' "$ENTRIES" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
          {
            echo "# HELP hass_config_entries Home Assistant config entries by integration domain and state."
            echo "# TYPE hass_config_entries gauge"
            printf '%s' "$ENTRIES" | jq -r '
              group_by([.domain, (.state // "unknown")])[]
              | "hass_config_entries{domain=\"\(.[0].domain)\",state=\"\(.[0].state // "unknown")\"} \(length)"
            '
            echo "# HELP hass_config_entries_read 1 if the config-entry listing was read and parsed."
            echo "# TYPE hass_config_entries_read gauge"
            echo "hass_config_entries_read 1"
          } >> "$TMP"
        else
          {
            echo "# HELP hass_config_entries_read 1 if the config-entry listing was read and parsed."
            echo "# TYPE hass_config_entries_read gauge"
            echo "hass_config_entries_read 0"
          } >> "$TMP"
        fi
      fi

      {
        echo "# HELP hass_integration_check_last_run_timestamp_seconds Unix time of the last completed run."
        echo "# TYPE hass_integration_check_last_run_timestamp_seconds gauge"
        echo "hass_integration_check_last_run_timestamp_seconds $(date +%s)"
      } >> "$TMP"

      chmod 0644 "$TMP"
      mv "$TMP" "$OUT"
      trap - EXIT
    '';
  };
in
{
  # Sole consumer of this token, so it is declared here. RELOCATED 2026-08-19
  # from modules/monitoring/homeassistant-nagios-check.nix, which the Nagios
  # removal deletes; leaving it there would have taken the declaration with it
  # and broken this exporter.
  #
  # owner/group root, NOT nagios: that user ceases to exist in the same removal.
  # This matters more than it looks -- sops-install-secrets validates EVERY
  # secret before writing ANY of them, so a single unresolvable owner aborts the
  # whole run, and because /run/secrets.d is ramfs the next boot would come up
  # with no secrets at all.
  #
  # Not DynamicUser: sops-nix cannot chown to a uid allocated at unit start.
  # Moving this unit off User=root needs LoadCredential=, which is a separate
  # change from a removal.
  sops.secrets."monitoring/home-assistant-token" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  systemd.services.hass-integration-exporter = {
    description = "Export Home Assistant integration health to a node-exporter textfile";
    after = [
      "home-assistant.service"
      "sops-nix.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${exporter}/bin/hass-integration-exporter";
      # Runs as root ONLY to read the SOPS token, which is mode 0400 root:root.
      # Moving to a dedicated user or DynamicUser requires switching to
      # LoadCredential= first -- sops-nix cannot chown to a uid that does not
      # exist until the unit starts.
      User = "root";
      Group = "root";
      # Above the 20s curl timeout with room for a slow HA; TimeoutStartSec is ENFORCED and a
      # previously-ignored cap becoming enforced has bitten this host before.
      TimeoutStartSec = "120s";
      ReadWritePaths = [ textfileDir ];
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };

  systemd.timers.hass-integration-exporter = {
    description = "Timer for the Home Assistant integration health exporter";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # OnActiveSec rather than OnBootSec: on a long-uptime host an OnBootSec timer whose
      # moment has already passed never fires again, which left discord-canary-hermes.timer
      # dead for 27 days. 5 min matches the cadence the Nagios check already ran at.
      OnActiveSec = "3min";
      OnUnitActiveSec = "5min";
      Unit = "hass-integration-exporter.service";
    };
  };
}
