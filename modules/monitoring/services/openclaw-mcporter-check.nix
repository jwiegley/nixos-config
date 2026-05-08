{
  config,
  lib,
  pkgs,
  ...
}:
let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  mcporterCheckScript = pkgs.writeScript "openclaw-mcporter-check.py" ''
    #!${pkgs.python3}/bin/python3
    """Probe mcporter.json structure and HA MCP endpoint, emit Prometheus textfile metrics.

    Runs on the host as user "openclaw" so it can read:
      * /var/lib/openclaw/.openclaw/.mcporter/mcporter.json (mode 600 owned by openclaw)
      * /run/secrets/openclaw/home-assistant-token        (mode 0400 owned by openclaw)

    Emits to ${textfileDir}/openclaw_mcporter.prom:
      openclaw_mcporter_server_ok{name="..."}        1=structurally valid, 0=missing/malformed
      openclaw_mcporter_ha_auth_ok                   1=HA accepted the Bearer token, 0=401/403/no-token
      openclaw_mcporter_ha_endpoint_reachable        1=got any HTTP response, 0=network error
      openclaw_mcporter_ha_token_present             1=token file exists and is non-empty
      openclaw_mcporter_check_last_run_timestamp_seconds
    """
    from __future__ import annotations

    import json
    import os
    import pathlib
    import time
    import urllib.request
    import urllib.error

    MCPORTER_JSON = pathlib.Path("/var/lib/openclaw/.openclaw/.mcporter/mcporter.json")
    HA_TOKEN_FILE = pathlib.Path("/run/secrets/openclaw/home-assistant-token")
    HA_URL = "http://127.0.0.1:8123/api/mcp"
    OUT_FINAL = pathlib.Path("${textfileDir}/openclaw_mcporter.prom")
    OUT_TMP = OUT_FINAL.with_suffix(".prom.tmp")

    EXPECTED_SERVERS = (
        "home-assistant",
        "stock-trader",
        "drafts",
        "email-contacts",
        "google-calendar-personal",
        "google-calendar-work",
    )


    def check_servers() -> dict[str, int]:
        """Return {name: 1|0} indicating structural validity per server."""
        out: dict[str, int] = {name: 0 for name in EXPECTED_SERVERS}
        try:
            data = json.loads(MCPORTER_JSON.read_text())
            servers = data.get("mcpServers", {}) or {}
        except (OSError, json.JSONDecodeError):
            return out

        for name, cfg in servers.items():
            if not isinstance(cfg, dict):
                continue
            ok = 0
            cmd = cfg.get("command")
            url = cfg.get("url") or cfg.get("baseUrl")

            if isinstance(cmd, str) and cmd:
                ok = 1
            elif isinstance(url, str) and url.startswith(("http://", "https://")):
                ok = 1

            # HA-specific check: must be a stdio command pointing at the
            # mcp-proxy bridge script, not a direct HTTP/SSE entry.  Direct
            # HTTP entries trigger mcporter's auto-OAuth flow which HA
            # cannot satisfy (no RFC 7591 dynamic client registration).
            if name == "home-assistant":
                ok = 0
                # Nix store paths end with "<hash>-mcp-proxy-ha-bridge",
                # not "/mcp-proxy-ha-bridge" — match the script name only.
                if isinstance(cmd, str) and cmd.endswith("mcp-proxy-ha-bridge"):
                    ok = 1
            out[name] = ok

        return out


    def probe_ha_endpoint() -> tuple[int, int, int]:
        """Probe HA /api/mcp with token. Return (auth_ok, reachable, token_present)."""
        if not HA_TOKEN_FILE.is_file():
            return (0, 0, 0)
        try:
            token = HA_TOKEN_FILE.read_text().strip()
        except OSError:
            return (0, 0, 0)
        if not token:
            return (0, 0, 1)

        req = urllib.request.Request(
            HA_URL,
            method="GET",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json, text/event-stream",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return (1 if resp.status not in (401, 403) else 0, 1, 1)
        except urllib.error.HTTPError as e:
            # 401/403 mean auth failed; any other HTTP error means the endpoint
            # is reachable AND the token was accepted (e.g., 405 Method Not Allowed).
            return (0 if e.code in (401, 403) else 1, 1, 1)
        except (urllib.error.URLError, OSError, TimeoutError):
            return (0, 0, 1)


    def write_metrics(
        server_ok: dict[str, int],
        ha_auth_ok: int,
        ha_reachable: int,
        ha_token_present: int,
    ) -> None:
        OUT_FINAL.parent.mkdir(parents=True, exist_ok=True)
        with OUT_TMP.open("w") as f:
            f.write(
                "# HELP openclaw_mcporter_server_ok 1 if the mcporter entry is structurally valid\n"
                "# TYPE openclaw_mcporter_server_ok gauge\n"
            )
            for name, ok in sorted(server_ok.items()):
                f.write(f'openclaw_mcporter_server_ok{{name="{name}"}} {ok}\n')
            f.write(
                "# HELP openclaw_mcporter_ha_auth_ok 1 if HA /api/mcp accepts the staged Bearer token (not 401/403)\n"
                "# TYPE openclaw_mcporter_ha_auth_ok gauge\n"
                f"openclaw_mcporter_ha_auth_ok {ha_auth_ok}\n"
                "# HELP openclaw_mcporter_ha_endpoint_reachable 1 if HA /api/mcp returned any HTTP response (no network error)\n"
                "# TYPE openclaw_mcporter_ha_endpoint_reachable gauge\n"
                f"openclaw_mcporter_ha_endpoint_reachable {ha_reachable}\n"
                "# HELP openclaw_mcporter_ha_token_present 1 if /run/secrets/openclaw/home-assistant-token exists and is non-empty\n"
                "# TYPE openclaw_mcporter_ha_token_present gauge\n"
                f"openclaw_mcporter_ha_token_present {ha_token_present}\n"
                "# HELP openclaw_mcporter_check_last_run_timestamp_seconds When the mcporter check last ran\n"
                "# TYPE openclaw_mcporter_check_last_run_timestamp_seconds gauge\n"
                f"openclaw_mcporter_check_last_run_timestamp_seconds {time.time()}\n"
            )
        os.replace(OUT_TMP, OUT_FINAL)


    def main() -> int:
        server_ok = check_servers()
        ha_auth_ok, ha_reachable, ha_token_present = probe_ha_endpoint()
        write_metrics(server_ok, ha_auth_ok, ha_reachable, ha_token_present)
        return 0


    if __name__ == "__main__":
        raise SystemExit(main())
  '';
in
{
  systemd.services.openclaw-mcporter-check = {
    description = "Probe mcporter.json structure and HA MCP endpoint";
    after = [
      "openclaw-prepare-secrets.service"
      "microvm@openclaw.service"
      "home-assistant.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "openclaw";
      Group = "openclaw";
      ExecStart = "${mcporterCheckScript}";

      # Hardening — match the canary's profile but with read-only access to
      # /var/lib/openclaw and /run/secrets so we can read mcporter.json and
      # the staged HA token.
      ReadWritePaths = [ textfileDir ];
      ReadOnlyPaths = [
        "/var/lib/openclaw"
        "/run/secrets"
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
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
    };
  };

  systemd.timers.openclaw-mcporter-check = {
    description = "Timer for openclaw-mcporter-check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Wait until openclaw is reasonably warm before the first check, then
      # poll every 5 minutes.  This is slower than the canary (30s) because
      # the HA endpoint probe is the slowest step (~50ms typical, 5s timeout).
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
      Unit = "openclaw-mcporter-check.service";
      AccuracySec = "10s";
    };
  };
}
