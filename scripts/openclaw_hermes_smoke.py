#!/usr/bin/env python3
"""
OpenClaw <-> Hermes end-to-end smoke probe.

Speaks raw MCP-over-SSE to the hermes-mcp bridge at 127.0.0.1:9081,
invokes the ask_hermes tool with a trivial prompt, and writes four
Prometheus textfile metrics to /var/lib/prometheus-node-exporter-textfiles/
openclaw_hermes_smoke.prom.

Stdlib-only by design (no httpx, no mcp SDK import) so packaging
changes in hermes-mcp can't break this probe.
"""
from __future__ import annotations
import http.client
import json
import os
import sys
import time
from dataclasses import dataclass
from typing import Optional

# Hardcoded at packaging time; the server's initialize response
# determines the authoritative negotiated version going forward.
# Update this string when the mcp SDK pinned in hermes-mcp bumps.
CLIENT_PROTOCOL_VERSION = "2025-06-18"

HOST = "127.0.0.1"
PORT = 9081
BUDGET_SECONDS = 90.0
PROMPT = "Reply with exactly two characters: O then K. No explanation."
METRIC_PATH = (
    "/var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom"
)
# hermes-mcp wraps replies in a JSON envelope
# {session_id, reply, message_count}. We try to parse and apply the
# 16-char bound from the spec to the *reply* field only; if parsing
# fails (a future hermes-mcp emits raw text), we fall back to bounding
# the whole text content at REPLY_FALLBACK_MAX_LEN.
REPLY_MAX_LEN = 16
REPLY_FALLBACK_MAX_LEN = 1024


@dataclass
class SmokeResult:
    ok: bool
    duration_seconds: float
    response_bytes: int
    timestamp: float


def parse_sse_events(buf: bytes):
    """Yield (event_type, data) tuples from a complete-event buffer.

    Handles both LF (\\n\\n) and CRLF (\\r\\n\\r\\n) event terminators —
    the hermes-mcp bridge uses sse-starlette which defaults to CRLF, so
    the live wire format may have \\r\\n endings even though SSE allows
    either. We normalise to LF before splitting.

    Only complete events (terminated by a blank line) yield. Trailing
    partial events are silently dropped; caller buffers and retries.
    """
    text = buf.decode("utf-8", errors="replace").replace("\r\n", "\n")
    blocks = text.split("\n\n")
    for block in blocks[:-1]:
        event_type = "message"
        data_lines = []
        for line in block.split("\n"):
            if line.startswith("event: "):
                event_type = line[len("event: "):].strip()
            elif line.startswith("data: "):
                data_lines.append(line[len("data: "):])
        if data_lines:
            yield event_type, "\n".join(data_lines)


def build_initialize_request(request_id: int) -> bytes:
    return json.dumps({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "initialize",
        "params": {
            "protocolVersion": CLIENT_PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {
                "name": "openclaw-hermes-smoke",
                "version": "0.1.0",
            },
        },
    }).encode()


def build_initialized_notification() -> bytes:
    return json.dumps({
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": {},
    }).encode()


def build_tools_call(request_id: int, prompt: str) -> bytes:
    return json.dumps({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {
            "name": "ask_hermes",
            "arguments": {"prompt": prompt},
            "_meta": {"progressToken": f"smoke-{request_id}"},
        },
    }).encode()


def _extract_reply_from_envelope(text: str) -> Optional[str]:
    """If text is a hermes-mcp envelope, return the `reply` field; else None.

    hermes-mcp wraps tool responses in JSON like
    `{"session_id": "...", "reply": "OK", "message_count": 1}`.
    Returns None on parse failure or missing/non-string `reply`.
    """
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    reply = obj.get("reply")
    if isinstance(reply, str):
        return reply
    return None


def extract_tool_result_text(payload: str, request_id: int) -> Optional[str]:
    """Return the first text content of a tools/call result for request_id.

    Returns None if the payload is not a result for our id, is an error,
    or contains no text content.
    """
    try:
        msg = json.loads(payload)
    except json.JSONDecodeError:
        return None
    if msg.get("id") != request_id:
        return None
    if "error" in msg:
        return None
    result = msg.get("result")
    if not isinstance(result, dict):
        return None
    content = result.get("content")
    if not isinstance(content, list):
        return None
    for item in content:
        if isinstance(item, dict) and item.get("type") == "text":
            text = item.get("text")
            if isinstance(text, str):
                return text
    return None


def write_metrics(result: SmokeResult, target: str = METRIC_PATH) -> None:
    """Atomically write the four smoke metrics to target."""
    lines = [
        "# HELP openclaw_hermes_smoke_ok 1 if the round-trip ask_hermes probe succeeded",
        "# TYPE openclaw_hermes_smoke_ok gauge",
        f"openclaw_hermes_smoke_ok {1 if result.ok else 0}",
        "# HELP openclaw_hermes_smoke_duration_seconds Wall-clock seconds for the round-trip",
        "# TYPE openclaw_hermes_smoke_duration_seconds gauge",
        f"openclaw_hermes_smoke_duration_seconds {result.duration_seconds}",
        "# HELP openclaw_hermes_smoke_response_bytes Length of the response text in bytes (0 on failure)",
        "# TYPE openclaw_hermes_smoke_response_bytes gauge",
        f"openclaw_hermes_smoke_response_bytes {result.response_bytes}",
        "# HELP openclaw_hermes_smoke_last_run_timestamp_seconds When the probe last ran",
        "# TYPE openclaw_hermes_smoke_last_run_timestamp_seconds gauge",
        f"openclaw_hermes_smoke_last_run_timestamp_seconds {result.timestamp}",
        "",
    ]
    tmp = target + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.rename(tmp, target)


def _read_until(resp, predicate, deadline: float) -> Optional[str]:
    """Read SSE chunks until predicate returns a non-None value, or deadline expires."""
    buf = b""
    while time.monotonic() < deadline:
        try:
            chunk = resp.read1(8192)
        except (TimeoutError, http.client.HTTPException, OSError):
            return None
        if not chunk:
            return None
        buf += chunk
        match = predicate(buf)
        if match is not None:
            return match
    return None


def run_probe(target: str = METRIC_PATH) -> SmokeResult:
    start = time.monotonic()
    deadline = start + BUDGET_SECONDS
    ok = False
    response_text = ""

    try:
        sse = http.client.HTTPConnection(HOST, PORT, timeout=BUDGET_SECONDS)
        sse.request("GET", "/sse")
        resp = sse.getresponse()
        if resp.status != 200:
            raise RuntimeError(f"SSE status {resp.status}")

        def _find_endpoint(buf: bytes) -> Optional[str]:
            for evt_type, data in parse_sse_events(buf):
                if evt_type == "endpoint":
                    return data
            return None

        endpoint = _read_until(resp, _find_endpoint, deadline)
        if endpoint is None:
            raise RuntimeError("no endpoint event received")

        post = http.client.HTTPConnection(HOST, PORT, timeout=10)
        post.request(
            "POST", endpoint,
            body=build_initialize_request(request_id=1),
            headers={"Content-Type": "application/json"},
        )
        init_resp = post.getresponse()
        init_resp.read()
        if init_resp.status not in (200, 202):
            raise RuntimeError(f"initialize POST {init_resp.status}")

        post2 = http.client.HTTPConnection(HOST, PORT, timeout=10)
        post2.request(
            "POST", endpoint,
            body=build_initialized_notification(),
            headers={"Content-Type": "application/json"},
        )
        post2.getresponse().read()

        post3 = http.client.HTTPConnection(HOST, PORT, timeout=10)
        post3.request(
            "POST", endpoint,
            body=build_tools_call(request_id=42, prompt=PROMPT),
            headers={"Content-Type": "application/json"},
        )
        post3.getresponse().read()

        def _find_tool_result(buf: bytes) -> Optional[str]:
            for evt_type, data in parse_sse_events(buf):
                if evt_type == "message":
                    text = extract_tool_result_text(data, request_id=42)
                    if text is not None:
                        return text
            return None

        result_text = _read_until(resp, _find_tool_result, deadline)
        if result_text is not None:
            reply = _extract_reply_from_envelope(result_text)
            if reply is not None and 0 < len(reply) <= REPLY_MAX_LEN:
                ok = True
                response_text = result_text
            elif (
                reply is None
                and 0 < len(result_text) <= REPLY_FALLBACK_MAX_LEN
            ):
                # Envelope didn't parse — accept the raw text if short.
                ok = True
                response_text = result_text
    except (
        OSError,
        http.client.HTTPException,
        RuntimeError,
        TimeoutError,
        json.JSONDecodeError,
    ) as e:
        # Only catch transient/IO-level failures. Programming errors
        # (TypeError, AttributeError, etc.) propagate so they fail the
        # systemd unit and surface in the journal as stack traces.
        print(f"smoke probe error: {e}", file=sys.stderr)

    duration = time.monotonic() - start
    result = SmokeResult(
        ok=ok,
        duration_seconds=round(duration, 3),
        response_bytes=len(response_text),
        timestamp=time.time(),
    )
    write_metrics(result, target=target)
    return result


def main() -> int:
    run_probe()
    return 0


if __name__ == "__main__":
    sys.exit(main())
