{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openclawHermesSmoke;

  smokeScript = pkgs.writers.writePython3Bin "openclaw-hermes-smoke" {
    flakeIgnore = [
      "E501" # long lines in JSON-RPC payload formatting
      "W503"
      "E265" # shebang flagged as non-conforming block comment
      "E203" # whitespace before ':' (Black-style slicing)
    ];
  } (builtins.readFile ../../../scripts/openclaw_hermes_smoke.py);
in
{
  options.services.openclawHermesSmoke = {
    enable = lib.mkEnableOption "OpenClaw ↔ Hermes bridge-level smoke probe";

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = ''
        Probe cadence in seconds. Each invocation costs a Hermes model
        inference; default 900 (15 min) ≈ 8 model-minutes/day of synthetic
        load. Drop to 300 to match hermes-health-check at 3x the load.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.openclaw-hermes-smoke = {
      description = "OpenClaw ↔ Hermes bridge-level smoke probe";
      after = [
        "hermes-mcp.service"
        "microvm@hermes.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "hermes-mcp";
        Group = "hermes-mcp";
        ExecStart = "${smokeScript}/bin/openclaw-hermes-smoke";
        # Cap runtime so a wedged read doesn't pile up zombie units.
        # Budget is BUDGET_SECONDS (90s) inside the script; 120s on
        # the systemd side leaves margin for python startup.
        TimeoutStartSec = "120s";
        # Hardening (matches modules/monitoring/services/hermes-health-check.nix)
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
      };
    };

    systemd.timers.openclaw-hermes-smoke = {
      description = "OpenClaw ↔ Hermes smoke probe timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        RandomizedDelaySec = "60s";
        AccuracySec = "15s";
        Unit = "openclaw-hermes-smoke.service";
        Persistent = true;
      };
    };
  };
}
