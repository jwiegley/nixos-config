{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openclawConfigDriftCheck;

  driftScript = pkgs.writers.writePython3Bin "openclaw-config-drift-check" {
    flakeIgnore = [
      "E501"
      "W503"
      "E265"
      "E203"
    ];
  } (builtins.readFile ../../../scripts/openclaw-config-drift-check.py);
in
{
  options.services.openclawConfigDriftCheck = {
    enable = lib.mkEnableOption "OpenClaw config schema-drift detector";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.openclaw-config-drift-check = {
      description = "Compare live openclaw.json key set against Nix template";
      after = [
        "openclaw-prepare-secrets.service"
        "microvm@openclaw.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      environment = {
        OPENCLAW_TEMPLATE_PATH = "${pkgs.openclaw-config-template}";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "openclaw-heal";
        Group = "openclaw-heal";
        ExecStart = "${driftScript}/bin/openclaw-config-drift-check";
        LoadCredential = [
          "probe-ssh-key:${config.sops.secrets."openclaw/probe-ssh-private-key".path}"
        ];
        Environment = [
          "OPENCLAW_PROBE_SSH_KEY=%d/probe-ssh-key"
        ];
        RuntimeMaxSec = "120s";
        # Hardening
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

    systemd.timers.openclaw-config-drift-check = {
      description = "Daily OpenClaw config schema-drift check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        RandomizedDelaySec = "20m";
        Persistent = true;
        Unit = "openclaw-config-drift-check.service";
      };
    };
  };
}
