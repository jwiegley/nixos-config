"""Non-invasive transport and explicit app probes for the Drafts MCP bridge."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import subprocess
import sys
import time
from collections.abc import Sequence
from typing import Any

import httpx


DRAFTS_MCP_SSE_URL = os.environ.get("DRAFTS_MCP_SSE_URL", "http://127.0.0.1:9082/sse")
DRAFTS_MCP_UNIT = os.environ.get("DRAFTS_MCP_UNIT", "drafts-mcp.service")
SYSTEMCTL = os.environ.get(
    "DRAFTS_MCP_SYSTEMCTL", "/run/current-system/sw/bin/systemctl"
)
OUT_FINAL = pathlib.Path(
    os.environ.get(
        "DRAFTS_MCP_METRICS_PATH",
        "/var/lib/prometheus-node-exporter-textfiles/drafts_mcp.prom",
    )
)
OUT_TMP = OUT_FINAL.with_suffix(".prom.tmp")

SSE_OPEN_BUDGET_S = 5.0
MCP_BUDGET_S = 45.0
PROBE_TOOL = "drafts_list_workspaces"

METRIC_HELP = {
    "drafts_mcp_bridge_up": "1 if drafts-mcp.service is active",
    "drafts_mcp_sse_open_ok": (
        "1 if drafts-mcp /sse accepted a connection and emitted an endpoint"
    ),
    "drafts_mcp_ssh_hera_ok": (
        "1 if the ssh child and hera drafts-mcp-server answered init and tools/list"
    ),
    "drafts_mcp_check_last_run_timestamp_seconds": (
        "When the drafts-mcp transport check last ran"
    ),
}


def build_mcp_requests(app_check: bool) -> list[dict[str, Any]]:
    """Return the complete request sequence for the selected probe mode."""
    requests: list[dict[str, Any]] = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "drafts-mcp-check", "version": "2"},
            },
        },
        {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        },
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        },
    ]
    if app_check:
        requests.append(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": PROBE_TOOL,
                    "arguments": {},
                },
            }
        )
    return requests


def periodic_metrics(
    bridge_up: int,
    sse_open_ok: int,
    ssh_hera_ok: int,
    timestamp: float,
) -> dict[str, int | float]:
    """Build the transport-only metric set written by scheduled mode."""
    return {
        "drafts_mcp_bridge_up": bridge_up,
        "drafts_mcp_sse_open_ok": sse_open_ok,
        "drafts_mcp_ssh_hera_ok": ssh_hera_ok,
        "drafts_mcp_check_last_run_timestamp_seconds": timestamp,
    }


def unit_is_active(unit: str) -> int:
    try:
        result = subprocess.run(
            [SYSTEMCTL, "is-active", unit],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except Exception:
        return 0
    return int(result.stdout.strip() == "active")


async def probe_sse_open() -> int:
    try:
        async with asyncio.timeout(SSE_OPEN_BUDGET_S):
            async with httpx.AsyncClient(timeout=SSE_OPEN_BUDGET_S) as client:
                async with client.stream("GET", DRAFTS_MCP_SSE_URL) as response:
                    if response.status_code != 200:
                        return 0
                    async for line in response.aiter_lines():
                        if line.startswith("data:") and "session_id=" in line:
                            return 1
    except Exception:
        return 0
    return 0


async def _next_response(lines: Any, expected_id: int) -> dict[str, Any] | None:
    async for line in lines:
        if not line.startswith("data:"):
            continue
        raw = line[len("data:") :].strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            return None
        if isinstance(event, dict):
            response_id = event.get("id")
            if type(response_id) is int and response_id == expected_id:
                return event
    return None


def _result_dict(response: dict[str, Any] | None) -> dict[str, Any] | None:
    if (
        not isinstance(response, dict)
        or response.get("jsonrpc") != "2.0"
        or "error" in response
    ):
        return None
    result = response.get("result")
    return result if isinstance(result, dict) else None


def _initialize_result_ok(response: dict[str, Any] | None) -> bool:
    result = _result_dict(response)
    if result is None:
        return False
    server_info = result.get("serverInfo")
    return bool(
        isinstance(result.get("protocolVersion"), str)
        and result["protocolVersion"]
        and isinstance(result.get("capabilities"), dict)
        and isinstance(server_info, dict)
        and isinstance(server_info.get("name"), str)
        and server_info["name"]
        and isinstance(server_info.get("version"), str)
        and server_info["version"]
    )


def _tools_list_result_ok(response: dict[str, Any] | None) -> bool:
    result = _result_dict(response)
    return bool(result is not None and isinstance(result.get("tools"), list))


def _tool_result_ok(response: dict[str, Any] | None) -> bool:
    result = _result_dict(response)
    if result is None:
        return False
    is_error = result.get("isError", False)
    if not isinstance(is_error, bool) or is_error:
        return False
    content = result.get("content")
    if not isinstance(content, list):
        return False
    texts = [
        block.get("text", "")
        for block in content
        if (
            isinstance(block, dict)
            and block.get("type") == "text"
            and isinstance(block.get("text"), str)
        )
    ]
    if not texts:
        return False
    text = " ".join(texts).strip().lower()
    if not text:
        return False
    return "-1743" not in text and "not authorized" not in text


async def probe_mcp(app_check: bool) -> tuple[int, int | None]:
    """Probe MCP transport, optionally adding one explicit read-only app call."""
    ssh_ok = 0
    app_ok: int | None = 0 if app_check else None
    requests = build_mcp_requests(app_check)

    try:
        async with asyncio.timeout(MCP_BUDGET_S):
            async with httpx.AsyncClient(timeout=MCP_BUDGET_S) as client:
                async with client.stream("GET", DRAFTS_MCP_SSE_URL) as response:
                    if response.status_code != 200:
                        return (ssh_ok, app_ok)

                    lines = response.aiter_lines()
                    endpoint: str | None = None
                    async for line in lines:
                        if line.startswith("data:") and "/messages/" in line:
                            endpoint = line[len("data:") :].strip()
                            break
                    if not endpoint:
                        return (ssh_ok, app_ok)

                    base = DRAFTS_MCP_SSE_URL.rsplit("/sse", 1)[0]
                    post_url = f"{base}{endpoint}"

                    async def post(payload: dict[str, Any]) -> None:
                        posted = await client.post(
                            post_url,
                            json=payload,
                            headers={"Accept": "application/json, text/event-stream"},
                        )
                        posted.raise_for_status()

                    await post(requests[0])
                    if not _initialize_result_ok(await _next_response(lines, 1)):
                        return (ssh_ok, app_ok)

                    await post(requests[1])
                    await post(requests[2])
                    if not _tools_list_result_ok(await _next_response(lines, 2)):
                        return (ssh_ok, app_ok)
                    ssh_ok = 1

                    if app_check:
                        await post(requests[3])
                        app_ok = int(_tool_result_ok(await _next_response(lines, 3)))
    except Exception:
        return (ssh_ok, app_ok)

    return (ssh_ok, app_ok)


def write_metrics(metrics: dict[str, int | float]) -> None:
    OUT_FINAL.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    for name, value in sorted(metrics.items()):
        lines.append(f"# HELP {name} {METRIC_HELP[name]}")
        lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name} {value}")
    OUT_TMP.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(OUT_TMP, OUT_FINAL)


async def main_async(app_check: bool) -> int:
    if app_check:
        ssh_ok, app_ok = await probe_mcp(True)
        if not ssh_ok:
            print("drafts-mcp app check: transport failed", file=sys.stderr)
            return 1
        if not app_ok:
            print("drafts-mcp app check: read-only tool failed", file=sys.stderr)
            return 1
        print("drafts-mcp app check: ok")
        return 0

    bridge_up = unit_is_active(DRAFTS_MCP_UNIT)
    sse_ok = await probe_sse_open()
    ssh_ok, _ = await probe_mcp(False) if sse_ok else (0, None)
    write_metrics(
        periodic_metrics(
            bridge_up=bridge_up,
            sse_open_ok=sse_ok,
            ssh_hera_ok=ssh_ok,
            timestamp=round(time.time(), 3),
        )
    )
    return 0


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--app-check",
        action="store_true",
        help=(
            "contact Drafts.app with one read-only workspace call; "
            "this may reveal the application"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    return asyncio.run(main_async(parse_args(argv).app_check))


if __name__ == "__main__":
    raise SystemExit(main())
