{
  config,
  lib,
  pkgs,
  ...
}:
let
  models = import ../../models.nix;
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
    # Suppress sudo's mail-on-error for openclaw-heal. Belt-and-braces
    # alongside the /run/sudo ReadWritePath below (in the unit's
    # serviceConfig.ReadWritePaths): if sudo ever still
    # fails for any reason in this confined namespace, we do NOT want
    # it to spawn a sendmail child that hangs on a read-only maildrop.
    security.sudo.extraConfig = ''
      Defaults:${user} !mail_no_perms,!mail_no_user,!mail_badpass,!mail_always
    '';

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
            command = "${actionsDir}/restage_secrets";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${actionsDir}/restart_canary";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${actionsDir}/restart_mcporter_check";
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
        pkgs.bashInteractive
        pkgs.curl
        pkgs.jq
      ];
      environment = {
        PYTHONUNBUFFERED = "1";
        LLM_MODEL = models.llm.agent.name;
      };
      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        Restart = "always";
        RestartSec = "5s";
        # Hardening (mirrors openclaw-canary patterns)
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = false; # needs setuid sudo wrapper
        PrivateTmp = true;
        RestrictSUIDSGID = false; # sudo wrapper is setuid
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # python compiles bytecode
        # CAP_SETUID/CAP_SETGID/CAP_AUDIT_WRITE/CAP_SYS_RESOURCE are required
        # for the setuid sudo wrapper to exec successfully under this unit.
        # CAP_DAC_OVERRIDE is needed so sudo can read its own files when
        # running as a non-root user.
        CapabilityBoundingSet = [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_AUDIT_WRITE"
          "CAP_SYS_RESOURCE"
          "CAP_DAC_OVERRIDE"
          "CAP_DAC_READ_SEARCH"
          "CAP_FOWNER"
          "CAP_CHOWN"
          "CAP_KILL"
          "CAP_SYS_ADMIN"
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        ReadWritePaths = [
          "/var/lib/openclaw-self-heal"
          "/var/log/openclaw-self-heal"
          "/var/lib/prometheus-node-exporter-textfiles"
          # sudo writes a per-uid timestamp file at /run/sudo/ts/<uid>
          # even with NOPASSWD entries; without RW access it fails with
          # "Read-only file system" and (worse) tries to mail root via
          # sendmail, whose postdrop also fails in the namespace, leaving
          # a stuck sendmail/postdrop chain forever (observed 2026-05-08
          # through 2026-05-15).
          "/run/sudo"
        ];
      };
      # `script` synthesises ExecStart; do not set ExecStart in serviceConfig
      # when using this attribute. The wrapper just sources the credential
      # into env before exec-ing the python daemon.
      script = ''
        # SENTINEL, not a credential. The daemon posts this as a bearer token to
        # the host LLM gateway on 127.0.0.1:4000, which injects the real upstream
        # Authorization header and discards whatever the client sent. The daemon
        # only requires the variable to be set (it raises GatewayUnreachable
        # otherwise), so a fixed placeholder is sufficient and removes this
        # module's dependency on a stale SOPS secret name.
        export LLM_GATEWAY_KEY="gateway-injects-real-key"
        exec ${pkgs.python3}/bin/python3 ${daemonScript}
      '';
    };

    networking.firewall.allowedTCPPorts = [ ]; # 127.0.0.1 only — no firewall change needed
  };
}
