# Hermes self-heal — polls hermes_health.prom and recovers from common
# failure modes without operator intervention.
#
# This is simpler than the openclaw-self-heal daemon: no Alertmanager
# webhook, no Python daemon, no L3 action allowlist. A systemd timer
# runs a small shell script every N minutes; the script reads the
# Prometheus textfile, applies a small state machine of "if X failing
# for ≥ M ticks, restart Y", and writes its own state to /var/lib.
#
# Failure modes handled:
#
#   1. hermes_mcp_sse_open_ok == 0 for ≥2 ticks   → restart hermes-mcp.service
#   2. hermes_api_server_ok == 0 for ≥2 ticks     → restart microvm@hermes.service
#   3. hermes_mcp_ask_hermes_ok == 0 for ≥3 ticks → restart microvm@hermes.service
#      (covers Discord-WS-zombie too, since restarting the VM clears it)
#   4. hermes_discord_last_event_age_seconds > 1800
#      AND no recent self-heal action               → restart microvm@hermes.service
#
# Cooldown: never restart the same unit more than once per 15 minutes,
# so a deeper outage doesn't get into a restart loop.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hermesSelfHeal;
  stateDir = "/var/lib/hermes-self-heal";
  metricsFile = "/var/lib/prometheus-node-exporter-textfiles/hermes_health.prom";

  healScript = pkgs.writeShellApplication {
    name = "hermes-self-heal";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gawk
      systemd
    ];
    text = ''
      set -euo pipefail

      METRICS_FILE='${metricsFile}'
      STATE_DIR='${stateDir}'
      COOLDOWN_SECONDS=${toString cfg.cooldownSeconds}
      DISCORD_AGE_THRESHOLD=${toString cfg.discordAgeThresholdSeconds}

      # Read a single Prometheus textfile metric value (returns empty if missing).
      get_metric() {
        local name="$1"
        # Match exact metric name at start-of-line followed by space, then capture
        # the floating-point value. Skip lines starting with `#`.
        grep -E "^''${name} " "$METRICS_FILE" 2>/dev/null | awk '{print $2}' | head -1
      }

      # Check whether `unit` was last restarted within COOLDOWN_SECONDS.
      in_cooldown() {
        local unit="$1"
        local stamp
        stamp="$STATE_DIR/last-restart-$(echo "$unit" | tr '/@:' '___')"
        if [ -f "$stamp" ]; then
          local last
          last=$(cat "$stamp")
          local now
          now=$(date +%s)
          local age=$(( now - last ))
          if [ "$age" -lt "$COOLDOWN_SECONDS" ]; then
            echo "  cooldown: $unit was restarted $age s ago; skipping"
            return 0
          fi
        fi
        return 1
      }

      restart_unit() {
        local unit="$1"
        local reason="$2"
        if in_cooldown "$unit"; then
          return 0
        fi
        echo "RESTART $unit (reason: $reason)"
        local stamp
        stamp="$STATE_DIR/last-restart-$(echo "$unit" | tr '/@:' '___')"
        date +%s > "$stamp"
        systemctl restart "$unit"
        # Reset the consecutive-failure counters so the next tick is a fresh window.
        : > "$STATE_DIR/counters"
      }

      # Increment consecutive-failure counter; return new value.
      bump_counter() {
        local key="$1"
        local cur=0
        if [ -f "$STATE_DIR/counters" ]; then
          cur=$(grep -E "^''${key}=" "$STATE_DIR/counters" 2>/dev/null | tail -1 | cut -d= -f2 || true)
          cur=''${cur:-0}
        fi
        cur=$((cur + 1))
        # Rewrite counters file atomically.
        local tmp="$STATE_DIR/counters.tmp"
        : > "$tmp"
        if [ -f "$STATE_DIR/counters" ]; then
          grep -vE "^''${key}=" "$STATE_DIR/counters" >> "$tmp" || true
        fi
        printf '%s=%d\n' "$key" "$cur" >> "$tmp"
        mv "$tmp" "$STATE_DIR/counters"
        echo "$cur"
      }

      reset_counter() {
        local key="$1"
        if [ -f "$STATE_DIR/counters" ]; then
          local tmp="$STATE_DIR/counters.tmp"
          grep -vE "^''${key}=" "$STATE_DIR/counters" > "$tmp" 2>/dev/null || true
          mv "$tmp" "$STATE_DIR/counters"
        fi
      }

      # --- Main ---

      if [ ! -f "$METRICS_FILE" ]; then
        echo "metrics file missing — nothing to do"
        exit 0
      fi

      mkdir -p "$STATE_DIR"

      sse_ok=$(get_metric hermes_mcp_sse_open_ok)
      api_ok=$(get_metric hermes_api_server_ok)
      ask_ok=$(get_metric hermes_mcp_ask_hermes_ok)
      disco_age=$(get_metric hermes_discord_last_event_age_seconds)

      printf 'metrics: sse=%s api=%s ask=%s disco_age=%s\n' \
        "$sse_ok" "$api_ok" "$ask_ok" "$disco_age"

      # SSE bridge failure → restart hermes-mcp
      if [ "$sse_ok" = "0" ]; then
        n=$(bump_counter sse_fails)
        if [ "$n" -ge 2 ]; then
          restart_unit hermes-mcp.service "sse_open_ok=0 for $n ticks"
        fi
      else
        reset_counter sse_fails
      fi

      # API server failure → restart microvm@hermes
      if [ "$api_ok" = "0" ]; then
        n=$(bump_counter api_fails)
        if [ "$n" -ge 2 ]; then
          restart_unit microvm@hermes.service "api_server_ok=0 for $n ticks"
        fi
      else
        reset_counter api_fails
      fi

      # End-to-end ask_hermes failing → restart microvm@hermes
      # (also catches Discord-WS-zombie if mcp-side path went stale through it)
      if [ "$ask_ok" = "0" ]; then
        n=$(bump_counter ask_fails)
        if [ "$n" -ge 3 ]; then
          restart_unit microvm@hermes.service "ask_hermes_ok=0 for $n ticks"
        fi
      else
        reset_counter ask_fails
      fi

      # Discord-WS zombie: gateway.log hasn't moved.
      # Use bc for float comparison since shell can't do it natively.
      if [ -n "$disco_age" ]; then
        gt=$(awk -v a="$disco_age" -v t="$DISCORD_AGE_THRESHOLD" 'BEGIN{print (a > t) ? 1 : 0}')
        if [ "$gt" = "1" ]; then
          restart_unit microvm@hermes.service "discord_event_age=''${disco_age}s > ''${DISCORD_AGE_THRESHOLD}s"
        fi
      fi

      echo "done"
    '';
  };
in
{
  options.services.hermesSelfHeal = {
    enable = lib.mkEnableOption "Hermes self-heal watchdog";

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "How often the watchdog polls the metrics file (seconds).";
    };

    cooldownSeconds = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = ''
        Minimum seconds between two restarts of the *same* unit.
        Prevents a deeper outage from looping the watchdog.
      '';
    };

    discordAgeThresholdSeconds = lib.mkOption {
      type = lib.types.int;
      default = 14400;
      description = ''
        Trigger a Hermes VM restart when the Discord gateway log has
        not seen an event in this many seconds. Default 4 hours,
        matching the HermesDiscordZombieSuspected alert. Hermes
        gateway.log doesn't record idle heartbeats — only connect,
        reconnect, inbound, outbound, and platform-error events —
        so anything < 1h would flood false positives on quiet days.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
    ];

    systemd.services.hermes-self-heal = {
      description = "Hermes watchdog — react to hermes_health.prom and restart on persistent failure";
      after = [
        "hermes-health-check.service"
        "prometheus-node-exporter.service"
      ];

      # We have to run as root because we systemctl restart system units.
      # The script is small, hardened, reads only one metrics file plus its
      # own state, and the only privileged action is `systemctl restart`.
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${healScript}/bin/hermes-self-heal";

        ReadWritePaths = [ stateDir ];
        ReadOnlyPaths = [
          "/var/lib/prometheus-node-exporter-textfiles"
        ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RuntimeMaxSec = "60s";
      };
    };

    systemd.timers.hermes-self-heal = {
      description = "Timer for hermes-self-heal";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Start 5 min after boot, after the first health-check has run.
        OnBootSec = "5min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        Unit = "hermes-self-heal.service";
        AccuracySec = "15s";
      };
    };
  };
}
