{
  config,
  lib,
  pkgs,
  ...
}:
let
  models = import ../../models.nix;
  cfg = config.services.hermesSelfHeal;
  daemonScript = pkgs.writeText "hermes-self-heal-daemon.py" (
    builtins.readFile ../../scripts/hermes-self-heal/daemon.py
  );
  user = "hermes-heal";
  actionsDir = "/etc/nixos/scripts/hermes-self-heal/actions";
  auxDir = "/etc/nixos/scripts/hermes-self-heal/aux";
in
{
  options.services.hermesSelfHeal = {
    enable = lib.mkEnableOption "hermes self-heal daemon";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9098;
      description = "Loopback port for the Alertmanager webhook.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = "/var/lib/hermes-self-heal";
      createHome = true;
      homeMode = "0700";
      description = "Hermes self-heal daemon";
    };
    users.groups.${user} = { };

    # Persistent state directory — `d` directive preserves contents across rebuilds.
    # On the first rebuild after the rewrite, this re-chowns the dir to hermes-heal
    # (previously owned by root from the shell-watchdog era). Old last-restart-*
    # files keep their root ownership but are harmless; the new daemon never reads
    # them. See spec §10.
    systemd.tmpfiles.rules = [
      "d /var/lib/hermes-self-heal 0700 ${user} ${user} -"
      "d /var/log/hermes-self-heal  0750 ${user} ${user} -"
    ];

    # Suppress sudo's mail-on-error for hermes-heal. Mirrors the
    # openclaw-heal defense against the stuck sendmail loop (see
    # openclaw spec §10, 2026-05-08 → 2026-05-15 incident).
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
            command = "${actionsDir}/restart_mcp";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${actionsDir}/restage_secrets";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${actionsDir}/reset_credential_pool";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${actionsDir}/restart_health_check";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${auxDir}/read_log_tail";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${auxDir}/kick_health_check";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    systemd.services.hermes-self-heal = {
      description = "Hermes self-heal webhook receiver and remediation runner";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "alertmanager.service"
      ];
      wants = [ "network-online.target" ];
      # PATH must include /run/wrappers/bin so the daemon's bare `sudo`
      # invocations resolve to NixOS's setuid sudo wrapper. The daemon
      # never asks sudo to run a bare command — only absolute paths
      # under /etc/nixos/scripts/hermes-self-heal/{actions,aux}/
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
        # Allow a long-running action (240s timeout) + 30s buffer to finish
        # gracefully before systemd SIGKILLs on `systemctl stop`. Default
        # TimeoutStopSec is 90s which would kill mid-action.
        TimeoutStopSec = "270s";
        # Hardening mirrors openclaw-self-heal.
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = false; # needs setuid sudo wrapper
        PrivateTmp = true;
        RestrictSUIDSGID = false; # sudo wrapper is setuid
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # python compiles bytecode
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
          "/var/lib/hermes-self-heal"
          "/var/log/hermes-self-heal"
          "/var/lib/prometheus-node-exporter-textfiles"
          # See openclaw-self-heal.nix comment block: /run/sudo needed even
          # with NOPASSWD, otherwise sudo fails AND spawns a stuck sendmail.
          "/run/sudo"
        ];
      };
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
