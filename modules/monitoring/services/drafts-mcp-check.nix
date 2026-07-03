# Drafts MCP bridge end-to-end health check.
#
# Probes the host-side drafts-mcp.service (mcp-proxy 0.8.2 SSE on
# 127.0.0.1:9082) the way an OpenClaw/Hermes guest would, then drives ONE
# read-only Drafts tool over the bridge to prove the full chain:
#
#     vulcan drafts-mcp.service ─ssh─► hera sshd ─forced-command─►
#       drafts-mcp-server ─osascript/AppleEvents─► Drafts.app (johnw Aqua)
#
# Six metrics, all derived from loopback-SSE MCP traffic — the check holds NO
# ssh credential (the bridge owns the key). It infers transport vs. grant
# health from the tool-call result envelope:
#
#   * drafts_mcp_bridge_up              systemd unit active
#   * drafts_mcp_sse_open_ok            /sse accepts the connection + endpoint
#   * drafts_mcp_ssh_hera_ok            tools/list returned (ssh child + hera
#                                       server answered MCP)
#   * drafts_mcp_tcc_automation_ok      a READ-ONLY tools/call returned a
#                                       NON-error result (Drafts grant intact).
#                                       ssh_ok=1 ∧ tcc_ok=0 == lost Automation
#                                       grant (johnw logout) — NEVER run_action.
#   * drafts_mcp_e2e_ok                 the full chain (sse∧ssh∧tcc)
#   * drafts_mcp_check_last_run_timestamp_seconds
#
# CRITICAL: ONLY read-only tools (drafts_list_workspaces). NEVER a write tool,
# above all NEVER drafts_run_action. Recovery is an EXTERNAL
# `systemctl restart drafts-mcp.service` driven by alerts/drafts.yaml + the
# drafts-mcp-self-heal receiver — the probe takes no remediation.
#
# Emits /var/lib/prometheus-node-exporter-textfiles/drafts_mcp.prom.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.draftsMcpCheck;
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  healthScript = pkgs.writeScript "drafts-mcp-check.py" ''
    #!${pkgs.python3.withPackages (ps: with ps; [ httpx ])}/bin/python3
    """End-to-end drafts-mcp bridge probe -> Prometheus textfile.

    Read-only by construction: the single tools/call is
    drafts_list_workspaces (readOnlyHint: true). run_action and every write
    tool are never invoked. All probes have hard timeouts so the unit cannot
    hang past TimeoutStartSec.
    """
    from __future__ import annotations

    import asyncio
    import json
    import os
    import pathlib
    import subprocess
    import time

    import httpx

    DRAFTS_MCP_SSE_URL = os.environ.get(
        "DRAFTS_MCP_SSE_URL", "http://127.0.0.1:9082/sse"
    )
    DRAFTS_MCP_UNIT = os.environ.get("DRAFTS_MCP_UNIT", "drafts-mcp.service")
    OUT_FINAL = pathlib.Path("${textfileDir}/drafts_mcp.prom")
    OUT_TMP = OUT_FINAL.with_suffix(".prom.tmp")

    SSE_OPEN_BUDGET_S = 5.0
    E2E_BUDGET_S = 45.0

    PROBE_TOOL = "drafts_list_workspaces"
    PROBE_ARGS: dict = {}


    def unit_is_active(unit: str) -> int:
        try:
            out = subprocess.run(
                ["${pkgs.systemd}/bin/systemctl", "is-active", unit],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
            return 1 if out == "active" else 0
        except Exception:
            return 0


    async def probe_sse_open() -> int:
        try:
            async with httpx.AsyncClient(timeout=SSE_OPEN_BUDGET_S) as c:
                async with c.stream("GET", DRAFTS_MCP_SSE_URL) as r:
                    if r.status_code != 200:
                        return 0
                    async for line in r.aiter_lines():
                        if line.startswith("data:") and "session_id=" in line:
                            return 1
            return 0
        except Exception:
            return 0


    def _is_tcc_failure(result_obj: dict) -> bool:
        """True if a tools/call result envelope looks like a hera-side TCC /
        AppleEvents grant failure. Any isError envelope counts (ssh already
        succeeded to return a JSON-RPC result). Also matches -1743 /
        'not authorized' in plain text content."""
        if result_obj.get("isError") is True:
            return True
        content = result_obj.get("content") or []
        text = " ".join(
            b.get("text", "") for b in content if b.get("type") == "text"
        ).lower()
        return ("-1743" in text) or ("not authorized" in text)


    async def probe_e2e() -> tuple[int, int, int]:
        """Open SSE -> init -> list -> ONE read-only tools/call.
        Returns (ssh_hera_ok, tcc_automation_ok, e2e_ok)."""
        ssh_ok = 0
        tcc_ok = 0
        try:
            async with httpx.AsyncClient(timeout=E2E_BUDGET_S) as c:
                async with c.stream("GET", DRAFTS_MCP_SSE_URL) as r:
                    if r.status_code != 200:
                        return (0, 0, 0)
                    lines = r.aiter_lines()
                    endpoint = None
                    async for line in lines:
                        if line.startswith("data:") and "/messages/" in line:
                            endpoint = line[len("data:"):].strip()
                            break
                    if not endpoint:
                        return (0, 0, 0)

                    base = DRAFTS_MCP_SSE_URL.rsplit("/sse", 1)[0]
                    post_url = f"{base}{endpoint}"

                    async def post(payload):
                        resp = await c.post(
                            post_url, json=payload,
                            headers={"Accept": "application/json, text/event-stream"},
                        )
                        resp.raise_for_status()

                    async def next_event():
                        async for line in lines:
                            if line.startswith("data:"):
                                return json.loads(line[len("data:"):].strip())
                        return None

                    await post({
                        "jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": {},
                            "clientInfo": {"name": "drafts-mcp-check", "version": "1"},
                        },
                    })
                    init = await next_event()
                    if not init or "result" not in init:
                        return (0, 0, 0)

                    await post({"jsonrpc": "2.0", "method": "notifications/initialized"})

                    await post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
                    listed = await next_event()
                    if not listed or "result" not in listed:
                        return (0, 0, 0)
                    ssh_ok = 1

                    await post({
                        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                        "params": {"name": PROBE_TOOL, "arguments": PROBE_ARGS},
                    })
                    call_resp = await next_event()
                    if (call_resp and "result" in call_resp
                            and not _is_tcc_failure(call_resp["result"])):
                        tcc_ok = 1
                    # else: ssh_ok=1 ∧ tcc_ok=0 == lost grant (johnw logout).
        except asyncio.TimeoutError:
            return (ssh_ok, tcc_ok, 0)
        except Exception:
            return (ssh_ok, tcc_ok, 0)

        e2e = 1 if (ssh_ok and tcc_ok) else 0
        return (ssh_ok, tcc_ok, e2e)


    METRIC_HELP = {
        "drafts_mcp_bridge_up": "1 if drafts-mcp.service is active",
        "drafts_mcp_sse_open_ok": "1 if drafts-mcp /sse accepted a connection and emitted the endpoint event",
        "drafts_mcp_ssh_hera_ok": "1 if the ssh child + hera drafts-mcp-server answered MCP (init + tools/list)",
        "drafts_mcp_tcc_automation_ok": "1 if a read-only Drafts tools/call returned a non-error result; ssh_ok=1 and this=0 means a lost Automation grant",
        "drafts_mcp_e2e_ok": "1 if the full chain (sse + ssh + Drafts grant) round-tripped a read-only tool within budget",
        "drafts_mcp_check_last_run_timestamp_seconds": "When the drafts-mcp check last ran",
    }


    def write_metrics(metrics: dict) -> None:
        OUT_FINAL.parent.mkdir(parents=True, exist_ok=True)
        lines = []
        for name, value in sorted(metrics.items()):
            # NOTE: the default is "" (double quotes), never two adjacent
            # single quotes — that sequence terminates the surrounding Nix
            # indented string.
            help_text = METRIC_HELP.get(name, "")
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} gauge")
            lines.append(f"{name} {value}")
        OUT_TMP.write_text("\n".join(lines) + "\n")
        os.replace(OUT_TMP, OUT_FINAL)


    async def main_async() -> int:
        bridge_up = unit_is_active(DRAFTS_MCP_UNIT)
        sse_ok = await probe_sse_open()
        if sse_ok:
            ssh_ok, tcc_ok, e2e_ok = await probe_e2e()
        else:
            ssh_ok, tcc_ok, e2e_ok = 0, 0, 0
        write_metrics({
            "drafts_mcp_bridge_up": bridge_up,
            "drafts_mcp_sse_open_ok": sse_ok,
            "drafts_mcp_ssh_hera_ok": ssh_ok,
            "drafts_mcp_tcc_automation_ok": tcc_ok,
            "drafts_mcp_e2e_ok": e2e_ok,
            "drafts_mcp_check_last_run_timestamp_seconds": round(time.time(), 3),
        })
        return 0


    if __name__ == "__main__":
        raise SystemExit(asyncio.run(main_async()))
  '';
in
{
  options.services.draftsMcpCheck = {
    enable = lib.mkEnableOption "Drafts MCP bridge end-to-end health probe";
    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Polling interval in seconds.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.drafts-mcp-check = {
      description = "Drafts MCP bridge end-to-end health probe (SSE, ssh→hera, Drafts AppleEvents grant)";
      after = [
        "drafts-mcp.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        # No secret reads — the bridge owns the ssh key; this probe only
        # speaks MCP over loopback SSE. Confined DynamicUser writing to the
        # 1777 textfile dir is the smallest footprint.
        DynamicUser = true;
        ExecStart = "${healthScript}";
        TimeoutStartSec = "120s";
        ReadWritePaths = [ textfileDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
      };
    };

    systemd.timers.drafts-mcp-check = {
      description = "Timer for drafts-mcp-check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        Unit = "drafts-mcp-check.service";
        AccuracySec = "15s";
      };
    };
  };
}
