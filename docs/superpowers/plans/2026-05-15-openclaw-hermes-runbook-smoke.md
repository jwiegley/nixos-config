# OpenClaw ↔ Hermes Runbook + Smoke Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver (a) a user-facing runbook at `/etc/nixos/docs/openclaw-hermes-integration.md` documenting the OpenClaw ↔ Hermes integration, and (b) a bridge-level synthetic smoke probe that exercises MCP-over-SSE end-to-end and emits Prometheus textfile metrics on a 15-minute cadence.

**Architecture:** A standalone stdlib-only Python 3.12 script speaks raw MCP-SSE to `http://127.0.0.1:9081/sse`, invokes `ask_hermes` with a trivial prompt, and writes 4 textfile metrics. A NixOS module wraps the script as a systemd `oneshot` with an `OnUnitActiveSec=900s` timer (same shape as `hermes-health-check`), running under the existing `hermes-mcp` system user. The runbook documents topology, components, the six MCP tools, paste-and-run verification commands, known failure modes, and the metrics reference.

**Tech Stack:** Python 3.12 (stdlib only), `pytest` for unit tests (run manually), NixOS module (`systemd.services` + `systemd.timers` + `pkgs.writers.writePython3Bin`).

**Spec:** [`/etc/nixos/docs/superpowers/specs/2026-05-15-openclaw-hermes-runbook-smoke-design.md`](../specs/2026-05-15-openclaw-hermes-runbook-smoke-design.md)

**Security invariants (carry across every task):**
- No new credentials introduced. The probe needs zero secrets — the `/sse` endpoint is plain HTTP on host loopback.
- Runbook content is reviewed before commit to ensure no port numbers, host IDs, or paths beyond what's already in `docs/ports.txt` or public docs leak into the file.
- `hermes_health.prom` already exists as a textfile metric file with no secrets in it; the new `openclaw_hermes_smoke.prom` follows the same conventions.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `/etc/nixos/scripts/openclaw-hermes-smoke.py` | **create** | Main script: stdlib MCP-SSE client + metric writer |
| `/etc/nixos/scripts/openclaw-hermes-smoke-tests/conftest.py` | **create** | Pytest path bootstrap so tests can import the script |
| `/etc/nixos/scripts/openclaw-hermes-smoke-tests/test_smoke.py` | **create** | Unit tests with fake SSE server |
| `/etc/nixos/modules/monitoring/services/openclaw-hermes-smoke.nix` | **create** | NixOS module: systemd unit + timer + tmpfiles |
| `/etc/nixos/hosts/vulcan/default.nix` | **modify** | Import the new monitoring module |
| `/etc/nixos/docs/openclaw-hermes-integration.md` | **create** | The runbook (≈350 lines) |
| `/etc/nixos/docs/ports.txt` | **modify** | Note the smoke probe as a second 9081 consumer |

---

## Task 1: Reconnaissance — verify protocol version + capture SSE shape

**Goal:** Pin down the exact MCP `protocolVersion` the hermes-mcp server will return, and observe the SSE event shape so the Python parser is written to the real wire format, not a guess.

**Files:** none modified

- [ ] **Step 1: Probe `/sse` to see the first event live**

```bash
curl -sN --max-time 4 http://127.0.0.1:9081/sse | head -5
```

Expected: an `event: endpoint` line followed by `data: /messages/?session_id=<uuid>` (the `mcp` SDK's standard SSE pattern). The relative URL after `data:` is the POST endpoint for that session. Record the exact format (with or without leading slash, with or without query string) for use in Task 4.

- [ ] **Step 2: Read the SDK's `protocolVersion` constant from the hermes-mcp dependencies**

```bash
nix-shell -p python312 'python312Packages.mcp' --run \
  'python3 -c "from mcp.types import LATEST_PROTOCOL_VERSION; print(LATEST_PROTOCOL_VERSION)"'
```

Expected: a string like `"2025-03-26"` or `"2025-06-18"` depending on the pinned SDK. Note the exact value — this is the constant the smoke script will hardcode.

If the import name has changed in newer SDK versions, fall back to:
```bash
grep -rn 'LATEST_PROTOCOL_VERSION\|protocolVersion' /nix/store/*mcp-*/lib/python*/site-packages/mcp/types.py 2>/dev/null | head -3
```

- [ ] **Step 3: Manual end-to-end handshake to validate the planned flow**

Run this one-liner that performs the full handshake manually and prints the negotiated version:

```bash
python3 <<'PY'
import http.client, json, uuid, urllib.parse
host = "127.0.0.1"; port = 9081
# 1. Open SSE
sse = http.client.HTTPConnection(host, port, timeout=10)
sse.request("GET", "/sse")
resp = sse.getresponse()
print("SSE status:", resp.status)
endpoint = None
buf = b""
while endpoint is None:
    chunk = resp.read1(4096)
    buf += chunk
    text = buf.decode()
    for line in text.splitlines():
        if line.startswith("data: ") and "session_id" in line:
            endpoint = line[6:].strip()
            break
print("POST endpoint:", endpoint)
# 2. POST initialize
post = http.client.HTTPConnection(host, port, timeout=10)
init_body = json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2025-03-26",
        "capabilities": {},
        "clientInfo": {"name": "spec-probe", "version": "0.0.1"}
    }
}).encode()
post.request("POST", endpoint, body=init_body, headers={"Content-Type": "application/json"})
post_resp = post.getresponse()
print("POST status:", post_resp.status, post_resp.read(40))
# 3. Drain SSE for initialize response
import time
time.sleep(1)
while True:
    chunk = resp.read1(8192)
    if not chunk:
        break
    text = chunk.decode(errors="replace")
    if "result" in text:
        print("INIT response chunk:")
        print(text[:800])
        break
sse.close(); post.close()
PY
```

Expected: SSE status 200, POST status 202, then an `event: message` line with a JSON-RPC body containing `"protocolVersion": "<some-version>"`. Record this version — it's what the server speaks, and the script's hardcoded constant should match.

If the server returns a different version than the one from Step 2 (or the SDK constant has moved), update the script's hardcoded constant in Task 4 Step 1.

- [ ] **Step 4: No commit — reconnaissance only**

---

## Task 2: Scaffold the script + test directory

**Files:**
- Create: `/etc/nixos/scripts/openclaw-hermes-smoke.py` (stub only)
- Create: `/etc/nixos/scripts/openclaw-hermes-smoke-tests/conftest.py`
- Create: `/etc/nixos/scripts/openclaw-hermes-smoke-tests/__init__.py` (empty)

- [ ] **Step 1: Create the test directory + conftest**

```bash
mkdir -p /etc/nixos/scripts/openclaw-hermes-smoke-tests
```

Write `/etc/nixos/scripts/openclaw-hermes-smoke-tests/__init__.py` as an empty file.

Write `/etc/nixos/scripts/openclaw-hermes-smoke-tests/conftest.py`:
```python
"""Add scripts/ to sys.path so tests can import openclaw_hermes_smoke."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
```

- [ ] **Step 2: Create script skeleton**

Write `/etc/nixos/scripts/openclaw-hermes-smoke.py`:
```python
#!/usr/bin/env python3
"""
OpenClaw ↔ Hermes end-to-end smoke probe.

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
CLIENT_PROTOCOL_VERSION = "2025-03-26"  # NOTE: confirm via Task 1 Step 2

HOST = "127.0.0.1"
PORT = 9081
BUDGET_SECONDS = 90.0
PROMPT = "Reply with exactly two characters: O then K. No explanation."
METRIC_PATH = "/var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom"
RESPONSE_MAX_LEN = 16


@dataclass
class SmokeResult:
    ok: bool
    duration_seconds: float
    response_bytes: int
    timestamp: float


def main() -> int:
    raise NotImplementedError("Filled in by Task 6")


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Smoke-test the skeleton imports**

```bash
python3 -c "import sys; sys.path.insert(0, '/etc/nixos/scripts'); import openclaw_hermes_smoke as s; print(s.HOST, s.PORT, s.BUDGET_SECONDS)"
```

Expected: `127.0.0.1 9081 90.0`.

- [ ] **Step 4: Commit**

```bash
git add scripts/openclaw-hermes-smoke.py scripts/openclaw-hermes-smoke-tests/
git commit -m "feat(openclaw-hermes-smoke): scaffold script + test directory"
```

---

## Task 3: SSE event parser — TDD

**Files:**
- Test: `/etc/nixos/scripts/openclaw-hermes-smoke-tests/test_smoke.py`
- Modify: `/etc/nixos/scripts/openclaw-hermes-smoke.py`

- [ ] **Step 1: Write the failing test**

Append to `test_smoke.py`:
```python
import openclaw_hermes_smoke as s


def test_sse_parser_endpoint_event_lf():
    """Parser extracts a session POST endpoint from an SSE 'endpoint' event (LF separators)."""
    raw = b"event: endpoint\ndata: /messages/?session_id=abc-123\n\n"
    events = list(s.parse_sse_events(raw))
    assert events == [("endpoint", "/messages/?session_id=abc-123")]


def test_sse_parser_endpoint_event_crlf():
    """Parser extracts an endpoint event with CRLF line endings (sse-starlette default).

    sse-starlette uses \\r\\n as its line separator by default — the parser must
    accept both wire formats or the live probe will fail every run while LF-only
    unit tests pass.
    """
    raw = b"event: endpoint\r\ndata: /messages/?session_id=abc-123\r\n\r\n"
    events = list(s.parse_sse_events(raw))
    assert events == [("endpoint", "/messages/?session_id=abc-123")]


def test_sse_parser_message_event_json_payload():
    """Parser handles JSON payloads in 'message' events."""
    raw = b'event: message\r\ndata: {"jsonrpc":"2.0","id":1,"result":{"x":1}}\r\n\r\n'
    events = list(s.parse_sse_events(raw))
    assert events == [("message", '{"jsonrpc":"2.0","id":1,"result":{"x":1}}')]


def test_sse_parser_multiple_events_in_one_buffer():
    """Multiple events delivered in a single read chunk all yield."""
    raw = (
        b"event: endpoint\r\ndata: /messages/?session_id=x\r\n\r\n"
        b"event: message\r\ndata: hello\r\n\r\n"
    )
    events = list(s.parse_sse_events(raw))
    assert events == [
        ("endpoint", "/messages/?session_id=x"),
        ("message", "hello"),
    ]


def test_sse_parser_handles_partial_buffer():
    """Parser yields nothing when buffer ends mid-event."""
    raw = b"event: message\r\ndata: {\"partial\":"
    events = list(s.parse_sse_events(raw))
    assert events == []
```

- [ ] **Step 2: Run tests — expect AttributeError**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/ -v 2>&1 | tail -15
```

Expected: 5 failures with `AttributeError: module 'openclaw_hermes_smoke' has no attribute 'parse_sse_events'`.

- [ ] **Step 3: Implement `parse_sse_events`**

Add to `openclaw-hermes-smoke.py` after the imports block:
```python
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
```

- [ ] **Step 4: Re-run tests**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/ -v 2>&1 | tail -12
```

Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/openclaw-hermes-smoke.py scripts/openclaw-hermes-smoke-tests/test_smoke.py
git commit -m "feat(openclaw-hermes-smoke): CRLF-aware SSE event parser with TDD"
```

---

## Task 4: MCP request builders + response parser — TDD

**Files:**
- Modify: `/etc/nixos/scripts/openclaw-hermes-smoke.py`
- Modify: `/etc/nixos/scripts/openclaw-hermes-smoke-tests/test_smoke.py`

- [ ] **Step 1: Write the failing tests**

Append to `test_smoke.py`:
```python
def test_build_initialize_request():
    body = s.build_initialize_request(request_id=1)
    decoded = json.loads(body)
    assert decoded["jsonrpc"] == "2.0"
    assert decoded["id"] == 1
    assert decoded["method"] == "initialize"
    assert decoded["params"]["protocolVersion"] == s.CLIENT_PROTOCOL_VERSION
    assert decoded["params"]["clientInfo"]["name"] == "openclaw-hermes-smoke"


def test_build_initialized_notification():
    body = s.build_initialized_notification()
    decoded = json.loads(body)
    assert decoded["jsonrpc"] == "2.0"
    assert decoded["method"] == "notifications/initialized"
    assert "id" not in decoded  # Notification = no id


def test_build_tools_call_with_progress_token():
    body = s.build_tools_call(request_id=42, prompt="Hi")
    decoded = json.loads(body)
    assert decoded["id"] == 42
    assert decoded["method"] == "tools/call"
    assert decoded["params"]["name"] == "ask_hermes"
    assert decoded["params"]["arguments"] == {"prompt": "Hi"}
    assert "_meta" in decoded["params"]
    assert "progressToken" in decoded["params"]["_meta"]


def test_extract_tool_result_text_happy_path():
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 42,
        "result": {"content": [{"type": "text", "text": "OK"}], "isError": False}
    })
    text = s.extract_tool_result_text(payload, request_id=42)
    assert text == "OK"


def test_extract_tool_result_text_wrong_id_returns_none():
    payload = json.dumps({"jsonrpc": "2.0", "id": 999, "result": {"content": []}})
    text = s.extract_tool_result_text(payload, request_id=42)
    assert text is None


def test_extract_tool_result_text_error_returns_none():
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 42,
        "error": {"code": -32000, "message": "boom"}
    })
    text = s.extract_tool_result_text(payload, request_id=42)
    assert text is None
```

Also append (right after imports in `test_smoke.py`):
```python
import json
```

- [ ] **Step 2: Run tests — expect AttributeErrors**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/ -v 2>&1 | tail -20
```

Expected: 6 new failures (build_initialize_request, build_initialized_notification, build_tools_call, extract_tool_result_text × 3).

- [ ] **Step 3: Implement the four functions**

Add to `openclaw-hermes-smoke.py` after `parse_sse_events`:
```python
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
```

- [ ] **Step 4: Re-run tests**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/ -v 2>&1 | tail -15
```

Expected: 11 passed (5 from Task 3 + 6 new).

- [ ] **Step 5: Commit**

```bash
git add scripts/openclaw-hermes-smoke.py scripts/openclaw-hermes-smoke-tests/test_smoke.py
git commit -m "feat(openclaw-hermes-smoke): MCP request builders and response parser"
```

---

## Task 5: Atomic metric writer — TDD

**Files:**
- Modify: `/etc/nixos/scripts/openclaw-hermes-smoke.py`
- Modify: `/etc/nixos/scripts/openclaw-hermes-smoke-tests/test_smoke.py`

- [ ] **Step 1: Write the failing tests**

Append to `test_smoke.py`:
```python
def test_write_metrics_emits_all_four(tmp_path):
    target = tmp_path / "openclaw_hermes_smoke.prom"
    result = s.SmokeResult(ok=True, duration_seconds=1.5, response_bytes=2, timestamp=1234567890.5)
    s.write_metrics(result, target=str(target))
    text = target.read_text()
    assert "openclaw_hermes_smoke_ok 1\n" in text
    assert "openclaw_hermes_smoke_duration_seconds 1.5\n" in text
    assert "openclaw_hermes_smoke_response_bytes 2\n" in text
    assert "openclaw_hermes_smoke_last_run_timestamp_seconds 1234567890.5\n" in text
    # Each metric has a HELP and TYPE
    assert text.count("# HELP ") == 4
    assert text.count("# TYPE ") == 4


def test_write_metrics_is_atomic(tmp_path):
    """Writer uses .tmp + rename so a partial write never appears at the target."""
    target = tmp_path / "openclaw_hermes_smoke.prom"
    result = s.SmokeResult(ok=False, duration_seconds=90.0, response_bytes=0, timestamp=0.0)
    s.write_metrics(result, target=str(target))
    assert target.exists()
    # No leftover .tmp
    assert not (tmp_path / "openclaw_hermes_smoke.prom.tmp").exists()
```

- [ ] **Step 2: Run — expect AttributeError**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/test_smoke.py::test_write_metrics_emits_all_four -v 2>&1 | tail -5
```

Expected: AttributeError (`write_metrics` not defined).

- [ ] **Step 3: Implement `write_metrics`**

Add to `openclaw-hermes-smoke.py` after `extract_tool_result_text`:
```python
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
```

- [ ] **Step 4: Re-run tests**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/ -v 2>&1 | tail -15
```

Expected: 13 passed (5 from Task 3 + 6 from Task 4 + 2 new in Task 5).

- [ ] **Step 5: Commit**

```bash
git add scripts/openclaw-hermes-smoke.py scripts/openclaw-hermes-smoke-tests/test_smoke.py
git commit -m "feat(openclaw-hermes-smoke): atomic Prometheus textfile writer"
```

---

## Task 6: End-to-end main flow with fake-server integration tests

**Files:**
- Modify: `/etc/nixos/scripts/openclaw-hermes-smoke.py`
- Modify: `/etc/nixos/scripts/openclaw-hermes-smoke-tests/test_smoke.py`

- [ ] **Step 1: Write the failing integration tests**

Append to `test_smoke.py`:
```python
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeMcpHandler(BaseHTTPRequestHandler):
    """Minimal MCP-SSE server for smoke-test integration tests.

    Holds the SSE GET open and feeds canned events keyed by what the
    client POSTs.
    """

    server_state = {}  # populated per-test before .serve_forever()

    def log_message(self, *args):
        pass  # silence noise

    def do_GET(self):
        if self.path != "/sse":
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            session_id = "test-session"
            # CRLF separators match the real wire format (sse-starlette default);
            # using \n\n here would let the parser-CRLF-handling bug slip past.
            self.wfile.write(
                f"event: endpoint\r\ndata: /messages/?session_id={session_id}\r\n\r\n".encode()
            )
            self.wfile.flush()
            self.server_state["sse_writer"] = self.wfile
            # Block until test releases us
            self.server_state["release"].wait(timeout=5.0)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode()
        try:
            req = json.loads(body)
        except Exception:
            self.send_error(400); return
        self.send_response(202); self.end_headers()
        # If it's a tools/call we push a result through the SSE stream
        if req.get("method") == "tools/call":
            req_id = req["id"]
            response = json.dumps({
                "jsonrpc": "2.0", "id": req_id,
                "result": {"content": [{"type": "text", "text": "OK"}], "isError": False}
            })
            writer = self.server_state.get("sse_writer")
            if writer:
                writer.write(f"event: message\r\ndata: {response}\r\n\r\n".encode())
                writer.flush()
                self.server_state["release"].set()


def _start_fake_server():
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), FakeMcpHandler)
    FakeMcpHandler.server_state = {"release": threading.Event()}
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd


def test_run_probe_happy_path(tmp_path, monkeypatch):
    httpd = _start_fake_server()
    port = httpd.server_address[1]
    monkeypatch.setattr(s, "PORT", port)
    target = tmp_path / "openclaw_hermes_smoke.prom"
    result = s.run_probe(target=str(target))
    httpd.shutdown()
    assert result.ok is True
    assert result.response_bytes > 0
    assert result.duration_seconds > 0
    assert (tmp_path / "openclaw_hermes_smoke.prom").exists()


def test_run_probe_timeout(tmp_path, monkeypatch):
    """If the bridge never returns a tool result, the probe emits ok=0."""

    class StallHandler(FakeMcpHandler):
        def do_POST(self):
            # Accept the post but never push an SSE response
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            self.send_response(202); self.end_headers()

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), StallHandler)
    StallHandler.server_state = {"release": threading.Event()}
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    port = httpd.server_address[1]
    monkeypatch.setattr(s, "PORT", port)
    monkeypatch.setattr(s, "BUDGET_SECONDS", 1.5)  # keep test fast
    target = tmp_path / "openclaw_hermes_smoke.prom"
    result = s.run_probe(target=str(target))
    httpd.shutdown()
    assert result.ok is False
    assert result.response_bytes == 0
```

- [ ] **Step 2: Run — expect AttributeError on `run_probe`**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/test_smoke.py::test_run_probe_happy_path -v 2>&1 | tail -5
```

Expected: AttributeError (`run_probe` not defined).

- [ ] **Step 3: Implement `run_probe` and `main`**

Add to `openclaw-hermes-smoke.py` after `write_metrics`:
```python
def _read_until(resp, predicate, deadline: float) -> Optional[str]:
    """Read SSE chunks until predicate returns a non-None value, or deadline expires.

    predicate is called with the accumulated bytes; if it returns a non-None
    value, that value is returned. Otherwise we read more.
    """
    buf = b""
    while time.monotonic() < deadline:
        try:
            chunk = resp.read1(8192)
        except (TimeoutError, http.client.HTTPException):
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
        # 1. Open SSE
        sse = http.client.HTTPConnection(HOST, PORT, timeout=BUDGET_SECONDS)
        sse.request("GET", "/sse")
        resp = sse.getresponse()
        if resp.status != 200:
            raise RuntimeError(f"SSE status {resp.status}")

        # 2. Read endpoint event
        def _find_endpoint(buf: bytes) -> Optional[str]:
            for evt_type, data in parse_sse_events(buf):
                if evt_type == "endpoint":
                    return data
            return None

        endpoint = _read_until(resp, _find_endpoint, deadline)
        if endpoint is None:
            raise RuntimeError("no endpoint event received")

        # 3. POST initialize
        post = http.client.HTTPConnection(HOST, PORT, timeout=10)
        post.request(
            "POST", endpoint,
            body=build_initialize_request(request_id=1),
            headers={"Content-Type": "application/json"},
        )
        init_resp = post.getresponse()
        init_resp.read()  # drain
        if init_resp.status not in (200, 202):
            raise RuntimeError(f"initialize POST {init_resp.status}")

        # 4. Send notifications/initialized
        post2 = http.client.HTTPConnection(HOST, PORT, timeout=10)
        post2.request(
            "POST", endpoint,
            body=build_initialized_notification(),
            headers={"Content-Type": "application/json"},
        )
        post2.getresponse().read()

        # 5. POST tools/call
        post3 = http.client.HTTPConnection(HOST, PORT, timeout=10)
        post3.request(
            "POST", endpoint,
            body=build_tools_call(request_id=42, prompt=PROMPT),
            headers={"Content-Type": "application/json"},
        )
        post3.getresponse().read()

        # 6. Read SSE for tools/call result
        def _find_tool_result(buf: bytes) -> Optional[str]:
            for evt_type, data in parse_sse_events(buf):
                if evt_type == "message":
                    text = extract_tool_result_text(data, request_id=42)
                    if text is not None:
                        return text
            return None

        result_text = _read_until(resp, _find_tool_result, deadline)
        if result_text is not None and 0 < len(result_text) <= RESPONSE_MAX_LEN:
            ok = True
            response_text = result_text
    except Exception as e:
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
```

- [ ] **Step 4: Re-run all tests**

```bash
cd /etc/nixos && python3 -m pytest scripts/openclaw-hermes-smoke-tests/ -v 2>&1 | tail -20
```

Expected: 15 passed (5 from Task 3 + 6 from Task 4 + 2 from Task 5 + 2 from Task 6).

- [ ] **Step 5: Run the script live against the real hermes-mcp (sanity check)**

```bash
cd /etc/nixos && python3 scripts/openclaw-hermes-smoke.py
cat /tmp/openclaw_hermes_smoke.prom 2>/dev/null || \
  echo "Note: live run writes to METRIC_PATH which requires root; that's OK — the test path verified the writer"
```

Optional: run as a temp metric file:
```bash
python3 -c "import sys; sys.path.insert(0,'scripts'); import openclaw_hermes_smoke as s; r=s.run_probe(target='/tmp/smoke.prom'); print(r); print(open('/tmp/smoke.prom').read())"
```

Expected: `SmokeResult(ok=True, ...)` and a .prom file with 4 metrics. If `ok=False`, inspect stderr — likely a real protocolVersion mismatch (re-run Task 1 to confirm the negotiated version, update `CLIENT_PROTOCOL_VERSION`).

- [ ] **Step 6: Commit**

```bash
git add scripts/openclaw-hermes-smoke.py scripts/openclaw-hermes-smoke-tests/test_smoke.py
git commit -m "feat(openclaw-hermes-smoke): end-to-end probe with TDD integration tests"
```

---

## Task 7: NixOS module

**Files:**
- Create: `/etc/nixos/modules/monitoring/services/openclaw-hermes-smoke.nix`

- [ ] **Step 1: Create the module**

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openclawHermesSmoke;

  smokeScript = pkgs.writers.writePython3Bin "openclaw-hermes-smoke" {
    flakeIgnore = [
      "E501" # long lines in JSON-RPC payload formatting
      "W503"
    ];
  } (builtins.readFile ../../../scripts/openclaw-hermes-smoke.py);
in
{
  options.services.openclawHermesSmoke = {
    enable = lib.mkEnableOption "OpenClaw ↔ Hermes bridge-level smoke probe";

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = ''
        Probe cadence in seconds. Each invocation costs a Hermes model
        inference; default 900 (15 min) ≈ 8 model-minutes/day of synthetic
        load. Drop to 300 to match hermes-health-check at 3x the load.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.openclaw-hermes-smoke = {
      description = "OpenClaw ↔ Hermes bridge-level smoke probe";
      after = [
        "hermes-mcp.service"
        "microvm@hermes.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "hermes-mcp";
        Group = "hermes-mcp";
        ExecStart = "${smokeScript}/bin/openclaw-hermes-smoke";
        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.openclaw-hermes-smoke = {
      description = "OpenClaw ↔ Hermes smoke probe timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        RandomizedDelaySec = "60s";
        AccuracySec = "15s";
        Unit = "openclaw-hermes-smoke.service";
        Persistent = true;
      };
    };
  };
}
```

- [ ] **Step 2: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/modules/monitoring/services/openclaw-hermes-smoke.nix'
```

- [ ] **Step 3: Commit**

```bash
git add modules/monitoring/services/openclaw-hermes-smoke.nix
git commit -m "feat(monitoring): openclaw-hermes-smoke NixOS module"
```

---

## Task 8: Wire into vulcan host + ports.txt

**Files:**
- Modify: `/etc/nixos/hosts/vulcan/default.nix`
- Modify: `/etc/nixos/docs/ports.txt`

- [ ] **Step 1: Add the import + enable**

In `/etc/nixos/hosts/vulcan/default.nix`, find the line `../../modules/monitoring/services/copyparty-exporter.nix` (or a similar monitoring/services import) and add immediately after it:
```nix
    ../../modules/monitoring/services/openclaw-hermes-smoke.nix
```

Then in the same file, find the `services.openclawSelfHeal.enable = true;` line (around line 184) and add immediately after the openclaw block:
```nix
  services.openclawHermesSmoke.enable = true;
```

- [ ] **Step 2: Update ports.txt**

In `/etc/nixos/docs/ports.txt`, find the existing `9081 127.0.0.1 hermes-mcp (...)` line and append on a continuation line below it:
```
9081 127.0.0.1 openclaw-hermes-smoke (15-min synthetic ask_hermes probe; also reaches hermes-mcp via loopback)
```

- [ ] **Step 3: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/hosts/vulcan/default.nix'
```

- [ ] **Step 4: Eval-check**

```bash
nix flake check --no-build /etc/nixos 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add hosts/vulcan/default.nix docs/ports.txt
git commit -m "chore(vulcan): enable openclaw-hermes-smoke; document second 9081 consumer"
```

---

## Task 9: Build + switch + first-run verification

**Files:** none

- [ ] **Step 1: Acquire build lock**

```bash
if [ -f /etc/nixos/.nixos-build ]; then
  echo "Lock held, waiting..."; sleep 10
else
  touch /etc/nixos/.nixos-build
fi
trap 'rm -f /etc/nixos/.nixos-build' EXIT
```

- [ ] **Step 2: Switch**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -30
```

Expected: switch succeeds; new units appear:
```
starting the following units: openclaw-hermes-smoke.timer
```

- [ ] **Step 3: Verify timer**

```bash
systemctl status openclaw-hermes-smoke.timer --no-pager | head -10
systemctl list-timers openclaw-hermes-smoke.timer --no-pager
```

Expected: timer active, NEXT activation visible.

- [ ] **Step 4: Trigger the first run manually (don't wait 3 min)**

```bash
sudo systemctl start openclaw-hermes-smoke.service
sleep 10  # Hermes typically replies in 2-10s for trivial prompts
systemctl status openclaw-hermes-smoke.service --no-pager | head -15
```

Expected: service exited 0/SUCCESS. If failed, `journalctl -u openclaw-hermes-smoke.service -n 30 --no-pager` will show the stderr message.

- [ ] **Step 5: Inspect the metric file**

```bash
cat /var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom
```

Expected: 4 metrics, `openclaw_hermes_smoke_ok 1`, response_bytes > 0, duration_seconds reasonable.

If `_ok 0`: the probe couldn't complete in 90s. Common causes:
- Stale `CLIENT_PROTOCOL_VERSION` constant — verify against Task 1 Step 2 output.
- microvm@hermes not yet up — `systemctl status microvm@hermes.service`.
- hermes-mcp not running — `systemctl status hermes-mcp.service`.

- [ ] **Step 6: Release lock**

```bash
rm -f /etc/nixos/.nixos-build
```

- [ ] **Step 7: No commit (runtime state only)**

---

## Task 10: Write the runbook

**Files:**
- Create: `/etc/nixos/docs/openclaw-hermes-integration.md`

- [ ] **Step 1: Capture live counts of the existing prom files**

```bash
echo "hermes_health.prom HELP count:"; grep -c '^# HELP' /var/lib/prometheus-node-exporter-textfiles/hermes_health.prom
echo "openclaw_canary.prom HELP count:"; grep -c '^# HELP' /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom
echo "openclaw_mcporter.prom HELP count:"; grep -c '^# HELP' /var/lib/prometheus-node-exporter-textfiles/openclaw_mcporter.prom
echo "openclaw_hermes_smoke.prom HELP count:"; grep -c '^# HELP' /var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom
```

Record the actual counts for use in Section 6 of the runbook.

Style after `docs/HOME_ASSISTANT_ALERTING.md`. Target total length 300–500 lines. Sections are added incrementally so each step is bite-sized (5–10 min each). After every step, view the file to confirm the section looks right.

- [ ] **Step 2a: Create the file with header + Section 1 (Topology)**

Write the doc header (title, one-paragraph overview, date stamp) and Section 1 ("Topology") containing the ASCII diagram from the spec plus a paragraph explaining the two-stage DNAT (microVM guest can't reach host loopback directly; the bridge IP is the only routable address from inside the VM).

- [ ] **Step 2b: Section 2 — Components**

Append a "Components" section with a markdown table: `Unit` | `Path` | `One-line role`. Cover the 9 systemd units listed in spec §A.2 (hermes-mcp.service, microvm@hermes.service, microvm@openclaw.service, openclaw-prepare-secrets.service, hermes-health-check.service+.timer, hermes-self-heal.service+.timer, openclaw-canary.service, openclaw-mcporter-check.service, openclaw-hermes-smoke.service+.timer).

- [ ] **Step 2c: Section 3 — The six MCP tools**

Open `pkgs/hermes-mcp/src/hermes_mcp/server.py` and the matching `tools.py`; for each of `ask_hermes`, `start_session`, `continue_session`, `list_sessions`, `summarize_session`, `delete_session`, write a 1-sentence description + expected latency band (e.g., "1–5 min" for ask_hermes, "<1s" for list_sessions). Bulleted list format.

- [ ] **Step 2d: Section 4 — Verification commands**

Add five labelled paste-and-run blocks (4a–4e) following the exact shape in spec §A.4: bridge SSE, Claw VM-side curl, hermes-health metrics summary, full manual Claw-side test (both variants with the explicit "manual only, exceeds 90s budget" note), and Hermes Discord age. Each block is a fenced bash code block + a short "what passing looks like" sentence.

- [ ] **Step 2e: Section 5 — Failure modes + recovery**

Four numbered items (Claw hallucinations, Hermes Discord zombie, MCP timeout, LiteLLM key rotation). For each: 1-2 line cause + 1-command remediation. Per spec §A.5.

- [ ] **Step 2f: Section 6 — Metrics reference**

Build the metrics table by reading each .prom file's `# HELP` lines. For each metric: name | gauge/counter | range | meaning. Counts to match Step 1's output (`hermes_health.prom`, `openclaw_canary.prom`, `openclaw_mcporter.prom`, `openclaw_hermes_smoke.prom`).

- [ ] **Step 2g: Section 7 — Where to make changes**

Add the 7-row table from spec §A.7: bump MCP timeout, add new MCP tool, change agent model, add/rotate SOPS secret, adjust self-heal thresholds, bump smoke probe schedule, kill switch.

- [ ] **Step 3: Verify length**

```bash
wc -l /etc/nixos/docs/openclaw-hermes-integration.md
```

Expected: between 300 and 500.

- [ ] **Step 4: Commit**

```bash
git add docs/openclaw-hermes-integration.md
git commit -m "$(cat <<'EOF'
docs(integration): OpenClaw ↔ Hermes runbook

Closes acceptance criterion #7 of the 2026-05-12 openclaw-hermes-mcp-bridge
plan. Covers topology, components, the six MCP tools, paste-and-run
verification (including the gold-standard manual full Claw-side test),
common failure modes (Claw hallucinations, Hermes Discord WebSocket
zombie, MCP timeout, LiteLLM key rotation), the full metrics reference,
and a "where to make changes" map for the six common edit paths plus
the kill switch.
EOF
)"
```

---

## Task 11: Memory update + final review

**Files:**
- Modify: `/home/johnw/.claude/projects/-etc-nixos/memory/project_hermes_agent.md` (existing)

- [ ] **Step 1: Append a dated section to the hermes memory**

Append to `/home/johnw/.claude/projects/-etc-nixos/memory/project_hermes_agent.md`:
```markdown

## 2026-05-15 — runbook + smoke probe added

- Runbook lives at `/etc/nixos/docs/openclaw-hermes-integration.md`.
- Bridge-level smoke probe: `openclaw-hermes-smoke.service` + `.timer`, every 15 min, runs as `hermes-mcp` user; metrics at `/var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom`. Stdlib-only Python so it can't be broken by hermes-mcp dep changes.
- No new alert — existing `HermesAskFailing` rule continues to be the pager.
- Kill switch: `sudo systemctl stop --now openclaw-hermes-smoke.timer`.
```

- [ ] **Step 2: Final passes**

```bash
git status --short
systemctl --failed --no-pager
cat /var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom | grep ^openclaw_hermes_smoke_ok
```

Expected: clean working tree (or only memory edit pending), zero failed units, `openclaw_hermes_smoke_ok 1`.

- [ ] **Step 3: No commit on memory** (memory lives outside the repo).

---

## What this plan deliberately does NOT do

- **No new Prometheus alert rule.** Existing `HermesAskFailing` already pages on `hermes_ask_ok == 0` for 15 min; the smoke probe joins the same dashboard from a different vantage point but doesn't add alert noise.
- **No Grafana dashboard updates.** Metrics queryable ad-hoc; dashboard polish is a future follow-up.
- **No Nix-wired test runner.** Tests run manually with `pytest`; building a Nix-wired stdlib-Python test pattern is its own work item, out of scope.
- **No changes to hermes-mcp itself.** The probe speaks the bridge's public MCP-SSE contract.
- **No openclaw guest VM changes.** Probe runs entirely on the host.

## Rollback plan

If the smoke probe causes problems:

1. Disable: `sudo systemctl stop --now openclaw-hermes-smoke.timer`.
2. For a permanent disable, set `services.openclawHermesSmoke.enable = false;` in `hosts/vulcan/default.nix` and `nixos-rebuild switch`.
3. To remove entirely: revert the seven commits from Tasks 2–10.

Nothing else in the system depends on this probe; it's a leaf consumer of the bridge.
