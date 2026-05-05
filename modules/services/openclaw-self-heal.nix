{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openclawSelfHeal;
  daemonScript = pkgs.writeText "openclaw-self-heal-daemon.py" (
    builtins.readFile ../../scripts/openclaw-self-heal/daemon.py
  );
  user = "openclaw-heal";
  actionsDir = "/etc/nixos/scripts/openclaw-self-heal/actions";
  auxDir = "/etc/nixos/scripts/openclaw-self-heal/aux";
in
{
  options.services.openclawSelfHeal = {
    enable = lib.mkEnableOption "openclaw self-heal daemon";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9092;
      description = "Loopback port for the Alertmanager webhook.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = "/var/lib/openclaw-self-heal";
      createHome = true;
      homeMode = "0700";
      description = "OpenClaw self-heal daemon";
    };
    users.groups.${user} = { };

    # State directory (persistent — uses `d` directive, NOT `D`).
    systemd.tmpfiles.rules = [
      "d /var/lib/openclaw-self-heal 0700 ${user} ${user} -"
      "d /var/log/openclaw-self-heal  0750 ${user} ${user} -"
    ];

    # Sudoers allowlist is **only absolute paths to scripts under our
    # control**. No bare commands like `tail` or `systemctl` — those
    # would let the daemon read /etc/shadow or restart arbitrary units.
    # Every script does its own argument validation. The action
    # scripts are state-changing (matched by the L3 allowlist in the
    # daemon); the aux scripts are read-only/trivial helpers.
    security.sudo.extraRules = [
      {
        users = [ user ];
        commands = [
          {
            command = "${actionsDir}/restart_microvm";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${actionsDir}/doctor_fix";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${actionsDir}/prune_stale_plugin_deps";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${auxDir}/read_log_tail";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${auxDir}/kick_canary";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # LiteLLM master-key access for the daemon. The same key is used by
    # other vulcan LiteLLM clients (rspamd, openclaw-microvm, etc.).
    sops.secrets."litellm-vulcan-lan-self-heal" = {
      key = "litellm-vulcan-lan";
      owner = user;
      mode = "0400";
      restartUnits = [ "openclaw-self-heal.service" ];
    };

    systemd.services.openclaw-self-heal = {
      description = "OpenClaw self-heal webhook receiver and remediation runner";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "alertmanager.service"
      ];
      wants = [ "network-online.target" ];
      # PATH must include /run/wrappers/bin so the daemon's bare `sudo`
      # invocations resolve to NixOS's setuid sudo wrapper. The daemon
      # never asks sudo to run a bare command — only absolute paths
      # under /etc/nixos/scripts/openclaw-self-heal/{actions,aux}/
      # which are matched by exact path in the sudoers allowlist.
      path = [
        "/run/wrappers"
        pkgs.coreutils
        pkgs.systemd
      ];
      environment = {
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        Restart = "always";
        RestartSec = "5s";
        LoadCredential = [
          "litellm-key:${config.sops.secrets."litellm-vulcan-lan-self-heal".path}"
        ];
        # Hardening (mirrors openclaw-canary patterns)
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = false; # needs setuid sudo wrapper
        PrivateTmp = true;
        RestrictSUIDSGID = false; # sudo wrapper is setuid
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # python compiles bytecode
        CapabilityBoundingSet = "";
        ReadWritePaths = [
          "/var/lib/openclaw-self-heal"
          "/var/log/openclaw-self-heal"
          "/var/lib/prometheus-node-exporter-textfiles"
        ];
      };
      # `script` synthesises ExecStart; do not set ExecStart in serviceConfig
      # when using this attribute. The wrapper just sources the credential
      # into env before exec-ing the python daemon.
      script = ''
        export LITELLM_KEY="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/litellm-key")"
        exec ${pkgs.python3}/bin/python3 ${daemonScript}
      '';
    };

    networking.firewall.allowedTCPPorts = [ ]; # 127.0.0.1 only — no firewall change needed
  };
}
