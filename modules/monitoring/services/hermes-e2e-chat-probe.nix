# Hermes end-to-end chat probe
#
# Exercises the actual chat completion path Discord conversations use,
# so any routing/auth regression in the main streaming-off code path
# shows up within one probe interval (default 5 min). Complements (does
# not replace) the openclaw-hermes-smoke probe — that one now tests
# only the MCP transport/handshake (`tools/list`; it was `ask_hermes`
# until 2026-07-22) and deliberately triggers no model inference, so
# it does not exercise the LLM gateway + MLX backend.
#
# History: added 2026-05-24 after the smoke probe greened up for 24h
# while Discord chat returned HTTP 401 from openrouter.ai. Root cause
# was the streaming-off chat path bypassing OPENROUTER_BASE_URL; this
# probe would have caught that within minutes.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  models = import ../../../models.nix;
  cfg = config.services.hermesE2eChatProbe;

  probeScript = pkgs.writers.writePython3Bin "hermes-e2e-chat-probe" {
    flakeIgnore = [
      "E501" # long lines in JSON payload formatting
      "W503"
      "E265"
    ];
  } (builtins.readFile ../../../scripts/hermes_e2e_chat_probe.py);
in
{
  options.services.hermesE2eChatProbe = {
    enable = lib.mkEnableOption "Hermes end-to-end chat completion probe";

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        Probe cadence in seconds. Default 300 (5 min). Each invocation
        runs a real chat completion through the MLX backend (~2-7s of
        model time); at 5 min cadence that's ~14 min of compute/day,
        about 0.5% of the day. Drop to 60 for faster detection if you
        can afford the load.
      '';
    };

    chatUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://10.99.1.2:8080/v1/chat/completions";
      description = "Hermes Agent api_server chat completions endpoint.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = models.llm.agent.name;
      description = ''
        Model identifier to use for the probe. Should match
        config.settings.model.default in hermes-vm.nix so the probe
        exercises the same model Discord uses.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hermes-e2e-chat-probe = {
      description = "Hermes end-to-end chat completion probe";
      after = [
        "microvm@hermes.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      environment = {
        HERMES_E2E_CHAT_URL = cfg.chatUrl;
        HERMES_E2E_CHAT_MODEL = cfg.model;
      };

      serviceConfig = {
        Type = "oneshot";
        # Reuse the hermes-mcp user — it already has the same
        # EnvironmentFile pattern for talking to Hermes' api_server.
        User = "hermes-mcp";
        Group = "hermes-mcp";
        # systemd reads EnvironmentFile as PID 1 (root) before
        # dropping to User=, so the runtime user does NOT need read
        # access to /run/secrets/hermes/env. Same pattern as
        # hermes-mcp.service.
        EnvironmentFile = config.sops.secrets."hermes/env".path;
        ExecStart = "${probeScript}/bin/hermes-e2e-chat-probe";
        # 90s per-attempt budget inside the script, with one retry on
        # failure (2 attempts x 90s + ~2s backoff); 210s wall leaves
        # margin for python startup and the atomic write. The retry
        # absorbs transient flaps (Qwen reasoning truncation, a one-off
        # MLX cold-load timeout) so only a persistent breakage pages.
        TimeoutStartSec = "210s";
        # Hardening (matches openclaw-hermes-smoke.nix and hermes-health-check.nix)
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # Exit-code 1 means "probe failed" (e.g. 401) — that's the
        # interesting signal we want in Prometheus, not an alert about
        # the systemd unit. Mark it as "successful failure".
        SuccessExitStatus = [
          0
          1
        ];
      };
    };

    systemd.timers.hermes-e2e-chat-probe = {
      description = "Hermes end-to-end chat probe timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        # Spread across instances; node-exporter scrape every 15s so
        # we want sub-15s jitter to avoid scrape-time collisions.
        RandomizedDelaySec = "30s";
        AccuracySec = "10s";
        Unit = "hermes-e2e-chat-probe.service";
        Persistent = true;
      };
    };
  };
}
