# Hermes fallback-chain counter
#
# Watches /var/lib/hermes/.hermes/logs/errors.log for "Non-retryable
# client error" log lines (the pattern Hermes emits when its agent
# loop hits an unrecoverable upstream failure — what surfaces to the
# user as "⚠️ Non-retryable error (HTTP N) — trying fallback…").
#
# Run as a system user in the hermes group so it can read the log
# without escalating privileges. Emits a monotonic counter to the
# node-exporter textfile collector; resets to 0 on log rotation,
# which Prometheus' increase() handles.
#
# Complements hermes-e2e-chat-probe: that probe checks the chat path
# proactively every 5 min; this counter records every actual user-
# visible failure as it happens.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermesFallbackCounter;

  counterScript = pkgs.writers.writePython3Bin "hermes-fallback-counter" {
    flakeIgnore = [
      "E501"
      "W503"
      "E265"
    ];
  } (builtins.readFile ../../../scripts/hermes_fallback_counter.py);
in
{
  options.services.hermesFallbackCounter = {
    enable = lib.mkEnableOption "Hermes errors.log fallback-chain counter";

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Refresh cadence in seconds. Default 60 (1 min); the counter
        only reads the log file so the cost is negligible.
      '';
    };

    logPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/.hermes/logs/errors.log";
      description = "Path to Hermes Agent errors.log on the host (shared with the VM).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Dedicated system user with read-only access to the Hermes log
    # via supplementary group membership.
    users.users.hermes-log-reader = {
      isSystemUser = true;
      group = "hermes-log-reader";
      extraGroups = [ "hermes" ];
      description = "Reads Hermes errors.log for fallback-chain counter";
    };
    users.groups.hermes-log-reader = { };

    systemd.services.hermes-fallback-counter = {
      description = "Hermes errors.log fallback-chain counter";
      after = [ "microvm@hermes.service" ];

      environment = {
        HERMES_FALLBACK_LOG_PATH = cfg.logPath;
      };

      serviceConfig = {
        Type = "oneshot";
        User = "hermes-log-reader";
        Group = "hermes-log-reader";
        # Note: extraGroups = [ "hermes" ] on the user above grants
        # supplementary group access; SupplementaryGroups= here would
        # be the alternative if we didn't want a dedicated user.
        ExecStart = "${counterScript}/bin/hermes-fallback-counter";
        RuntimeMaxSec = "30s";

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = [ "/var/lib/hermes" ];
        ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
      };
    };

    systemd.timers.hermes-fallback-counter = {
      description = "Hermes fallback-chain counter timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        RandomizedDelaySec = "15s";
        AccuracySec = "5s";
        Unit = "hermes-fallback-counter.service";
        Persistent = true;
      };
    };
  };
}
