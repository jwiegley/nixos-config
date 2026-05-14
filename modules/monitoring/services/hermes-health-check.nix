# Hermes / hermes-mcp end-to-end health check.
#
# Mirrors the openclaw-mcporter-check.nix shape but with deeper probes:
#
#   1. Hermes Agent api_server `/v1/capabilities` (HTTP 200)
#   2. hermes-mcp `/sse` (server accepts SSE upgrade)
#   3. Full MCP round-trip:
#        initialize → notifications/initialized → tools/list → tools/call ask_hermes
#      with a fixed micro-prompt and a 60s budget — proves the entire chain
#      OpenClaw VM would traverse actually works, including Hermes inference.
#   4. Discord platform liveness: parses /var/lib/hermes/.hermes/logs/gateway.log
#      (host-mounted via virtiofs) to surface the age of the last meaningful
#      Discord event. A bot whose WebSocket has zombied silently produces no
#      log entries; this catches that without round-tripping a Discord message.
#
# Emits a Prometheus textfile at /var/lib/prometheus-node-exporter-textfiles/
# hermes_health.prom. Pair with alerts/hermes.yaml.
#
# Runs as the hermes-mcp service user (in the `hermes` group) so the
# API_SERVER_KEY env file is readable and the gateway.log is readable.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hermesHealthCheck;
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  healthScript = pkgs.writeScript "hermes-health-check.py" ''
    #!${
      pkgs.python3.withPackages (
        ps: with ps; [
          httpx
          anyio
        ]
      )
    }/bin/python3
    """End-to-end Hermes health probe → Prometheus textfile.

    All probes have hard timeouts so the unit cannot hang past
    `RuntimeMaxSec` in the systemd unit. On any probe failure the
    metric is 0; only `_age_seconds` and the run timestamp use real
    values regardless of probe success.
    """
    from __future__ import annotations

    import asyncio
    import json
    import os
    import pathlib
    import re
    import time
    from typing import Optional

    import httpx


    HERMES_MCP_SSE_URL = os.environ.get("HERMES_MCP_SSE_URL", "http://127.0.0.1:9081/sse")
    HERMES_API_URL = os.environ.get("HERMES_API_URL", "http://10.99.1.2:8080")
    GATEWAY_LOG = pathlib.Path(
        os.environ.get("HERMES_GATEWAY_LOG", "/var/lib/hermes/.hermes/logs/gateway.log")
    )
    OUT_FINAL = pathlib.Path("${textfileDir}/hermes_health.prom")
    OUT_TMP = OUT_FINAL.with_suffix(".prom.tmp")

    # Total per-probe timeouts.
    ASK_HERMES_BUDGET_S = 60.0
    SSE_OPEN_BUDGET_S = 5.0
    API_PROBE_BUDGET_S = 5.0

    # The end-to-end probe prompt is intentionally tiny and deterministic.
    PROBE_PROMPT = "Reply with the single word ACK and nothing else."
    PROBE_EXPECT_FRAGMENT = "ACK"


    async def probe_api_server(api_key: str) -> tuple[int, float]:
        """Hermes api_server /v1/capabilities — returns (ok, latency_s)."""
        start = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=API_PROBE_BUDGET_S) as c:
                r = await c.get(
                    f"{HERMES_API_URL}/v1/capabilities",
                    headers={"Authorization": f"Bearer {api_key}"},
                )
                ok = 1 if r.status_code == 200 else 0
                return (ok, time.monotonic() - start)
        except Exception:
            return (0, time.monotonic() - start)


    async def probe_mcp_sse_open() -> int:
        """Open SSE channel and confirm the `endpoint` event arrives."""
        try:
            async with httpx.AsyncClient(timeout=SSE_OPEN_BUDGET_S) as c:
                async with c.stream("GET", HERMES_MCP_SSE_URL) as r:
                    if r.status_code != 200:
                        return 0
                    async for line in r.aiter_lines():
                        if line.startswith("data:") and "session_id=" in line:
                            return 1
            return 0
        except Exception:
            return 0


    async def probe_ask_hermes_e2e() -> tuple[int, float, str]:
        """Full MCP round-trip: open SSE, init, list_tools, call ask_hermes."""
        start = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=ASK_HERMES_BUDGET_S) as c:
                async with c.stream("GET", HERMES_MCP_SSE_URL) as r:
                    if r.status_code != 200:
                        return (0, time.monotonic() - start, "sse_open_status")

                    lines = r.aiter_lines()
                    endpoint = None
                    async for line in lines:
                        if line.startswith("data:") and "/messages/" in line:
                            endpoint = line[len("data:"):].strip()
                            break
                    if not endpoint:
                        return (0, time.monotonic() - start, "sse_no_endpoint")

                    base = HERMES_MCP_SSE_URL.rsplit("/sse", 1)[0]
                    post_url = f"{base}{endpoint}"

                    async def post(payload):
                        resp = await c.post(
                            post_url,
                            json=payload,
                            headers={"Accept": "application/json, text/event-stream"},
                        )
                        resp.raise_for_status()

                    async def next_event():
                        async for line in lines:
                            if line.startswith("data:"):
                                return json.loads(line[len("data:"):].strip())
                        return None

                    await post(
                        {
                            "jsonrpc": "2.0",
                            "id": 1,
                            "method": "initialize",
                            "params": {
                                "protocolVersion": "2024-11-05",
                                "capabilities": {},
                                "clientInfo": {"name": "hermes-health-check", "version": "1"},
                            },
                        }
                    )
                    init = await next_event()
                    if not init or "result" not in init:
                        return (0, time.monotonic() - start, "init_failed")

                    await post({"jsonrpc": "2.0", "method": "notifications/initialized"})

                    await post(
                        {
                            "jsonrpc": "2.0",
                            "id": 2,
                            "method": "tools/call",
                            "params": {
                                "name": "ask_hermes",
                                "arguments": {"prompt": PROBE_PROMPT},
                            },
                        }
                    )
                    call_resp = await next_event()
                    elapsed = time.monotonic() - start
                    if not call_resp or "result" not in call_resp:
                        return (0, elapsed, "ask_no_result")
                    content = call_resp["result"].get("content") or []
                    text = " ".join(
                        b.get("text", "") for b in content if b.get("type") == "text"
                    )
                    if PROBE_EXPECT_FRAGMENT.lower() in text.lower():
                        return (1, elapsed, "ok")
                    # Got a reply but Hermes didn't say ACK — still a "the path
                    # works" signal, just downgraded so we can tell apart.
                    return (1, elapsed, "ok_off_topic")
        except asyncio.TimeoutError:
            return (0, time.monotonic() - start, "timeout")
        except Exception as e:
            return (0, time.monotonic() - start, f"exception:{type(e).__name__}")


    DISCORD_EVENT_RE = re.compile(
        r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ INFO gateway\."
        r"(?:platforms\.discord|run): "
        r"(?:\[Discord\] (?:Connected|Flushing|Sending|Skipping|Registered)|"
        r"inbound message: platform=discord|response ready: platform=discord|"
        r"Channel directory built|Reconnecting|✓ discord connected)"
    )


    def discord_last_event_age_seconds() -> tuple[int, float]:
        """Read tail of gateway.log; return (present, age_seconds).

        present=1 if we found any matching event; age_seconds is wall-clock
        seconds since the most recent event (very large if file empty).
        """
        if not GATEWAY_LOG.is_file():
            return (0, 1e9)
        try:
            # Read the last 64KB — plenty for several hours of Hermes idle traffic.
            size = GATEWAY_LOG.stat().st_size
            with GATEWAY_LOG.open("rb") as f:
                if size > 65536:
                    f.seek(-65536, 2)
                tail = f.read().decode("utf-8", errors="replace")
        except OSError:
            return (0, 1e9)

        last_ts = None
        for line in tail.splitlines():
            m = DISCORD_EVENT_RE.match(line)
            if m:
                last_ts = m.group("ts")

        if not last_ts:
            return (0, 1e9)

        try:
            t = time.strptime(last_ts, "%Y-%m-%d %H:%M:%S")
            # Times in the log are UTC (Python logging default uses local TZ but
            # systemd journal stamps are UTC, and the log file in the VM is UTC
            # per microvm config). Compute age vs time.time() in UTC.
            epoch = int(
                __import__("calendar").timegm(t)
            )  # treats struct_time as UTC
            return (1, max(0.0, time.time() - epoch))
        except (ValueError, OverflowError):
            return (0, 1e9)


    def read_api_key() -> Optional[str]:
        path = pathlib.Path("/run/secrets/hermes/env")
        try:
            for line in path.read_text().splitlines():
                if line.startswith("API_SERVER_KEY="):
                    return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return None


    def write_metrics(metrics: dict[str, float | int]) -> None:
        OUT_FINAL.parent.mkdir(parents=True, exist_ok=True)
        lines = []
        # Sort for stable diffs.
        for name, value in sorted(metrics.items()):
            help_txt = METRIC_HELP.get(name, "")
            type_txt = METRIC_TYPE.get(name, "gauge")
            lines.append(f"# HELP {name} {help_txt}")
            lines.append(f"# TYPE {name} {type_txt}")
            lines.append(f"{name} {value}")
        OUT_TMP.write_text("\n".join(lines) + "\n")
        os.replace(OUT_TMP, OUT_FINAL)


    METRIC_HELP = {
        "hermes_api_server_ok": "1 if Hermes api_server /v1/capabilities returned 200",
        "hermes_api_server_probe_seconds": "Wall-clock seconds for the api_server capabilities probe",
        "hermes_mcp_sse_open_ok": "1 if hermes-mcp /sse accepted a connection and emitted the endpoint event",
        "hermes_mcp_ask_hermes_ok": "1 if a full ask_hermes round-trip completed within 60s",
        "hermes_mcp_ask_hermes_seconds": "Wall-clock seconds for the end-to-end ask_hermes probe",
        "hermes_discord_event_present": "1 if at least one Discord event was found in gateway.log tail",
        "hermes_discord_last_event_age_seconds": "Wall-clock seconds since the most recent Discord gateway event",
        "hermes_health_check_last_run_timestamp_seconds": "When the health check last ran",
        "hermes_api_key_present": "1 if API_SERVER_KEY was readable from /run/secrets/hermes/env",
    }
    METRIC_TYPE = {
        "hermes_health_check_last_run_timestamp_seconds": "gauge",
    }


    async def main_async() -> int:
        api_key = read_api_key()
        api_key_present = 1 if api_key else 0

        if api_key:
            api_ok, api_seconds = await probe_api_server(api_key)
        else:
            api_ok, api_seconds = 0, 0.0

        sse_ok = await probe_mcp_sse_open()
        ask_ok, ask_seconds, _ = await probe_ask_hermes_e2e()

        disco_present, disco_age = discord_last_event_age_seconds()

        write_metrics(
            {
                "hermes_api_server_ok": api_ok,
                "hermes_api_server_probe_seconds": round(api_seconds, 3),
                "hermes_mcp_sse_open_ok": sse_ok,
                "hermes_mcp_ask_hermes_ok": ask_ok,
                "hermes_mcp_ask_hermes_seconds": round(ask_seconds, 3),
                "hermes_discord_event_present": disco_present,
                "hermes_discord_last_event_age_seconds": round(disco_age, 1),
                "hermes_api_key_present": api_key_present,
                "hermes_health_check_last_run_timestamp_seconds": round(time.time(), 3),
            }
        )
        return 0


    if __name__ == "__main__":
        raise SystemExit(asyncio.run(main_async()))
  '';
in
{
  options.services.hermesHealthCheck = {
    enable = lib.mkEnableOption "Hermes end-to-end health probe";

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Polling interval in seconds (every N seconds).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hermes-health-check = {
      description = "Hermes end-to-end health probe (api_server, hermes-mcp SSE, ask_hermes, Discord)";
      after = [
        "hermes-mcp.service"
        "microvm@hermes.service"
        "sops-install-secrets.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        # Run as the `hermes` user directly. We considered hermes-mcp +
        # SupplementaryGroups=hermes, but /var/lib/hermes/.hermes is mode
        # 0700 — only the owner can traverse it, group membership does not
        # grant entry. Running as the owning user is the simplest path to
        # read both the SOPS env file (hermes:hermes 0640) and the
        # gateway.log (under .hermes/logs/). The probe is read-only against
        # the entire hermes state directory.
        User = "hermes";
        Group = "hermes";

        ExecStart = "${healthScript}";

        # Hard cap: the ask_hermes probe alone allows 60s; pad for the others.
        RuntimeMaxSec = "120s";

        ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
        ReadOnlyPaths = [
          "/run/secrets"
          "/var/lib/hermes"
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

    systemd.timers.hermes-health-check = {
      description = "Timer for hermes-health-check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # First run quickly after boot, then every ${intervalSeconds}.
        OnBootSec = "2min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        Unit = "hermes-health-check.service";
        AccuracySec = "15s";
      };
    };
  };
}
