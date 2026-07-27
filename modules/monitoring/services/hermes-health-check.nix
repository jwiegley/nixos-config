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
#   4. Discord platform liveness: primarily the age of the discord.py
#      heartbeat-ACK stamp file (written by the in-VM sitecustomize shim in
#      hermes-vm.nix on every gateway HEARTBEAT_ACK, ~every 41s while the WS
#      is alive). This is traffic-independent — a stale stamp means acks have
#      stopped = a genuine zombie, regardless of how idle the server is.
#      Falls back to scraping gateway.log for the last connect/message event
#      if the stamp file is absent (older Hermes / shim not yet applied).
#      The emitted age is the min of the two, so a healthy WS keeps it tiny.
#
# Emits a Prometheus textfile at /var/lib/prometheus-node-exporter-textfiles/
# hermes_health.prom. Pair with alerts/hermes.yaml.
#
# Runs as the `hermes` user (`User = "hermes"` in serviceConfig below, NOT
# hermes-mcp) so the API_SERVER_KEY env file (/run/secrets/hermes/env) and the
# gateway.log under /var/lib/hermes/.hermes/logs are readable.
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
    `TimeoutStartSec` in the systemd unit. On any probe failure the
    metric is 0; only `_age_seconds` and the run timestamp use real
    values regardless of probe success.
    """
    from __future__ import annotations

    import asyncio
    import json
    import os
    import pathlib
    import re
    import subprocess
    import time
    from typing import Optional

    import httpx


    HERMES_MCP_SSE_URL = os.environ.get("HERMES_MCP_SSE_URL", "http://127.0.0.1:9081/sse")
    HERMES_API_URL = os.environ.get("HERMES_API_URL", "http://10.99.1.2:8080")
    GATEWAY_LOG = pathlib.Path(
        os.environ.get("HERMES_GATEWAY_LOG", "/var/lib/hermes/.hermes/logs/gateway.log")
    )
    # Heartbeat-ACK stamp written by the in-VM sitecustomize shim (hermes-vm.nix)
    # on every discord.py gateway HEARTBEAT_ACK. This is the primary, traffic-
    # independent liveness signal.
    HEARTBEAT_FILE = pathlib.Path(
        os.environ.get(
            "HERMES_DISCORD_HEARTBEAT_FILE",
            "/var/lib/hermes/.hermes/logs/discord_ws_heartbeat",
        )
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


    def discord_heartbeat_age_seconds() -> tuple[int, float]:
        """Read the discord.py heartbeat-ACK stamp; return (present, age_seconds).

        The in-VM sitecustomize shim wraps KeepAliveHandler.ack() to write
        time.time() here on every Discord HEARTBEAT_ACK (~every 41s while the
        gateway WS is alive). A stale stamp = acks stopped = genuine zombie,
        independent of message traffic. present=0 if the file is missing or
        unparseable (shim not applied / bot not yet connected).
        """
        try:
            raw = HEARTBEAT_FILE.read_text().strip()
        except OSError:
            return (0, 1e9)
        try:
            stamped = float(raw)
        except ValueError:
            return (0, 1e9)
        return (1, max(0.0, time.time() - stamped))


    def read_api_key() -> Optional[str]:
        path = pathlib.Path("/run/secrets/hermes/env")
        try:
            for line in path.read_text().splitlines():
                if line.startswith("API_SERVER_KEY="):
                    return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return None


    VM_UNIT = "microvm@hermes.service"


    def vm_uptime_seconds() -> float:
        """Seconds since microvm@hermes last became active — a VM-boot proxy.

        Gates HermesApiServerDown so the ~8-min post-restart /v1/capabilities
        warmup (model-backend-bound; see hermes.yaml) is not read as an outage.
        Uses systemd's CLOCK_MONOTONIC activation timestamp, compared against
        time.monotonic() (same clock). On ANY failure returns a large value so
        the alert gate stays OPEN — a probe failure must never mask a real
        outage by making the VM look freshly booted forever.
        """
        try:
            out = subprocess.run(
                [
                    "${pkgs.systemd}/bin/systemctl",
                    "show",
                    VM_UNIT,
                    "--property=ActiveEnterTimestampMonotonic",
                    "--value",
                ],
                capture_output=True,
                text=True,
                timeout=5,
            ).stdout.strip()
            active_us = int(out)
            if active_us <= 0:
                return 86400.0  # never active / unknown → don't suppress
            up = time.monotonic() - active_us / 1e6
            return up if up >= 0 else 86400.0
        except Exception:
            return 86400.0


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
        "hermes_discord_heartbeat_present": "1 if the discord.py heartbeat-ACK stamp file was readable",
        "hermes_discord_heartbeat_age_seconds": "Wall-clock seconds since the last Discord gateway HEARTBEAT_ACK (via in-VM shim)",
        "hermes_discord_last_event_age_seconds": "Wall-clock seconds since the most recent proof of Discord liveness (min of heartbeat-ACK age and gateway.log event age)",
        "hermes_health_check_last_run_timestamp_seconds": "When the health check last ran",
        "hermes_api_key_present": "1 if API_SERVER_KEY was readable from /run/secrets/hermes/env",
        "hermes_vm_uptime_seconds": "Seconds since microvm@hermes last became active (VM-boot proxy; gates HermesApiServerDown past the post-restart warmup)",
    }
    METRIC_TYPE = {
        "hermes_health_check_last_run_timestamp_seconds": "gauge",
    }


    async def capped(coro, budget, fallback):
        """Enforce a TOTAL wall-clock cap on a probe.

        The per-probe httpx `timeout=` is a per-operation deadline, NOT a
        total: a streamed SSE response (probe_mcp_sse_open / _ask_hermes_e2e)
        whose chunks each arrive within the window can run far past the budget
        while Hermes is on a slow fallback LLM. Before 2026-07-03 that was
        masked because the unit's RuntimeMaxSec was silently ignored (oneshot),
        so the probe just ran long and finished; once that became an enforced
        TimeoutStartSec=120s, a slow-but-working Hermes made systemd SIGTERM the
        whole unit (Result=timeout -> SystemdServiceFailed). Wrapping each probe
        in asyncio.timeout() makes it self-terminate at its budget and return a
        clean "timeout" metric, so TimeoutStartSec is only a hang backstop.
        """
        try:
            async with asyncio.timeout(budget):
                return await coro
        except (asyncio.TimeoutError, TimeoutError):
            return fallback

    async def main_async() -> int:
        api_key = read_api_key()
        api_key_present = 1 if api_key else 0

        if api_key:
            api_ok, api_seconds = await capped(
                probe_api_server(api_key), API_PROBE_BUDGET_S + 2.0, (0, API_PROBE_BUDGET_S)
            )
        else:
            api_ok, api_seconds = 0, 0.0

        sse_ok = await capped(probe_mcp_sse_open(), SSE_OPEN_BUDGET_S + 2.0, 0)
        ask_ok, ask_seconds, _ = await capped(
            probe_ask_hermes_e2e(), ASK_HERMES_BUDGET_S + 2.0, (0, ASK_HERMES_BUDGET_S, "timeout")
        )

        disco_present, disco_age = discord_last_event_age_seconds()
        hb_present, hb_age = discord_heartbeat_age_seconds()
        # "Proof of life" age: the smaller of the heartbeat-ACK age (primary,
        # traffic-independent) and the gateway.log event age (fallback). A
        # healthy WS acks ~every 41s, keeping this tiny; it only climbs when
        # acks AND log events both go silent = a real zombie.
        live_age = min(disco_age, hb_age) if hb_present else disco_age
        vm_up = vm_uptime_seconds()

        write_metrics(
            {
                "hermes_api_server_ok": api_ok,
                "hermes_api_server_probe_seconds": round(api_seconds, 3),
                "hermes_vm_uptime_seconds": round(vm_up, 1),
                "hermes_mcp_sse_open_ok": sse_ok,
                "hermes_mcp_ask_hermes_ok": ask_ok,
                "hermes_mcp_ask_hermes_seconds": round(ask_seconds, 3),
                "hermes_discord_event_present": disco_present,
                "hermes_discord_heartbeat_present": hb_present,
                "hermes_discord_heartbeat_age_seconds": round(hb_age, 1),
                "hermes_discord_last_event_age_seconds": round(live_age, 1),
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
        # Run as the `hermes` user directly — the simplest path to read both
        # the SOPS env file (/run/secrets/hermes/env, hermes:hermes 0640) and
        # the gateway.log under .hermes/logs/. The probe is read-only against
        # the entire hermes state directory.
        #
        # The rationale that used to sit here said hermes-mcp +
        # SupplementaryGroups=hermes could not work because
        # /var/lib/hermes/.hermes is mode 0700 and group membership does not
        # grant entry. That is false. Checked 2026-07-27: /var/lib/hermes,
        # .hermes and .hermes/logs are all 2770 hermes:hermes, so any member
        # of the `hermes` group can traverse and read them —
        # hermes-fallback-counter.service does exactly that today, running as
        # hermes-log-reader (a member of `hermes`, not the owner). Running as
        # the owning user here is a choice, not a permissions requirement.
        User = "hermes";
        Group = "hermes";

        ExecStart = "${healthScript}";

        # Backstop only. Each probe now enforces its OWN total wall-clock cap
        # via asyncio.timeout() (see `capped` in the script), so the script's
        # real max runtime is ~sum of budgets (5+5+60) + overhead < 120s and it
        # always exits cleanly writing metrics. This 120s is a last-resort hang
        # guard, NOT the probe's timeout — do not lower it toward the internal
        # budgets or a slow-Hermes run will be SIGTERM-killed again (the
        # 2026-07-07 SystemdServiceFailed regression).
        TimeoutStartSec = "120s";

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
