# Drafts MCP self-heal — a one-action Alertmanager webhook receiver.
#
# DraftsMcpBridgeDown / DraftsMcpAskFailing (service=drafts-mcp,
# self_heal_eligible=true) → POST /alert here → `systemctl restart
# drafts-mcp.service`. That restart re-execs mcp-proxy's single shared ssh
# child to hera (the design-D9 zombie fix). It is the ONLY automated
# remediation, it is pure systemctl, and it is orthogonal to drafts_run_action.
#
# Deliberately NOT reusing hermes-self-heal: that daemon is hermes-keyed
# (ACTION_MAP on hermes alert names, reads hermes_health.prom, ignores unknown
# alerts) and routing a DraftsMcp* alert at it would no-op without
# cross-contaminating an unrelated critical service.
#
# DraftsMcpTccAutomationLost is intentionally NOT in HEALABLE (a lost hera GUI
# session — restarting drafts-mcp cannot fix it; it pages a human).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.draftsMcpSelfHeal;
  user = "drafts-mcp-heal";
  actionsDir = "/etc/nixos/scripts/drafts-mcp-self-heal/actions";

  daemonScript = pkgs.writeText "drafts-mcp-self-heal.py" ''
    #!${pkgs.python3}/bin/python3
    """Single-action Alertmanager webhook -> systemctl restart drafts-mcp.

    Listens on 127.0.0.1:${toString cfg.port}/alert. For each FIRING alert
    whose name is in HEALABLE, runs the (sudo-allowlisted) restart action,
    debounced. No AI tier, no incident store, no escalation ladder.
    """
    from __future__ import annotations

    import json
    import subprocess
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    PORT = ${toString cfg.port}
    ACTION = "${actionsDir}/restart_drafts_mcp"
    HEALABLE = {"DraftsMcpBridgeDown", "DraftsMcpAskFailing"}
    MIN_RESTART_INTERVAL_S = 300.0
    _last_restart = [0.0]


    def run_action(alertname: str) -> None:
        # stdout reaches the journal (PYTHONUNBUFFERED=1) — the Phase-4
        # verification gate reads delivery + debounce evidence from
        # `journalctl -u drafts-mcp-self-heal`.
        now = time.monotonic()
        if now - _last_restart[0] < MIN_RESTART_INTERVAL_S:
            print(f"debounced: {alertname} within "
                  f"{MIN_RESTART_INTERVAL_S:.0f}s of last restart", flush=True)
            return
        _last_restart[0] = now
        print(f"healing: {alertname} -> sudo {ACTION}", flush=True)
        try:
            r = subprocess.run(
                ["sudo", "-n", ACTION],
                capture_output=True, text=True, timeout=120,
            )
            print(f"action rc={r.returncode} out={r.stdout.strip()!r} "
                  f"err={r.stderr.strip()!r}", flush=True)
        except Exception as exc:
            print(f"action failed: {exc!r}", flush=True)


    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw or b"{}")
            except Exception:
                payload = {}
            for alert in payload.get("alerts", []):
                if alert.get("status") != "firing":
                    continue
                name = alert.get("labels", {}).get("alertname")
                if name in HEALABLE:
                    run_action(name)
                    break
                elif name:
                    print(f"delivered non-healable alert: {name} (no-op)",
                          flush=True)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")


    if __name__ == "__main__":
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  options.services.draftsMcpSelfHeal = {
    enable = lib.mkEnableOption "drafts-mcp self-heal webhook receiver";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9085;
      description = "Loopback port for the Alertmanager webhook (9085 — verified free vs 9097 MailArchiver collision; re-verify vs ss -ltnp).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      description = "Drafts MCP self-heal daemon";
    };
    users.groups.${user} = { };

    security.sudo.extraConfig = ''
      Defaults:${user} !mail_no_perms,!mail_no_user,!mail_badpass,!mail_always
    '';

    security.sudo.extraRules = [
      {
        users = [ user ];
        commands = [
          {
            command = "${actionsDir}/restart_drafts_mcp";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    systemd.services.drafts-mcp-self-heal = {
      description = "Drafts MCP self-heal webhook receiver (restart drafts-mcp.service)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "alertmanager.service"
      ];
      wants = [ "network-online.target" ];
      # PATH must include /run/wrappers/bin so the daemon's bare `sudo`
      # resolves to NixOS's setuid sudo wrapper (mirrors hermes-self-heal).
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
        ExecStart = "${pkgs.python3}/bin/python3 ${daemonScript}";
        # Hardening mirrors hermes-self-heal.nix, minus the caps its broader
        # actions need (KILL/SYS_ADMIN/NET_ADMIN/...): this daemon's only
        # action is a sudo'd `systemctl restart`, so the set below is just
        # the sudo plumbing (setuid transition, PAM audit, /run/sudo ts).
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = false; # needs the setuid sudo wrapper
        PrivateTmp = true;
        RestrictSUIDSGID = false; # sudo wrapper is setuid
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # python compiles bytecode
        CapabilityBoundingSet = [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_AUDIT_WRITE"
          "CAP_DAC_OVERRIDE"
          "CAP_DAC_READ_SEARCH"
          "CAP_FOWNER"
          "CAP_CHOWN"
        ];
        ReadWritePaths = [
          # See openclaw-self-heal.nix comment block: /run/sudo needed even
          # with NOPASSWD, otherwise sudo fails AND spawns a stuck sendmail.
          "/run/sudo"
        ];
      };
    };

    networking.firewall.allowedTCPPorts = [ ]; # 127.0.0.1 only
  };
}
