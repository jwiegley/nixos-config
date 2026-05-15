"""Unit + integration tests for openclaw_hermes_smoke."""
from __future__ import annotations
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import openclaw_hermes_smoke as s


# ---------------- Task 3: SSE parser ----------------


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


# ---------------- Task 4: MCP request builders + response parser ----------------


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


# ---------------- Task 5: Atomic metric writer ----------------


def test_write_metrics_emits_all_four(tmp_path):
    target = tmp_path / "openclaw_hermes_smoke.prom"
    result = s.SmokeResult(
        ok=True, duration_seconds=1.5, response_bytes=2, timestamp=1234567890.5
    )
    s.write_metrics(result, target=str(target))
    text = target.read_text()
    assert "openclaw_hermes_smoke_ok 1\n" in text
    assert "openclaw_hermes_smoke_duration_seconds 1.5\n" in text
    assert "openclaw_hermes_smoke_response_bytes 2\n" in text
    assert "openclaw_hermes_smoke_last_run_timestamp_seconds 1234567890.5\n" in text
    assert text.count("# HELP ") == 4
    assert text.count("# TYPE ") == 4


def test_write_metrics_is_atomic(tmp_path):
    """Writer uses .tmp + rename so a partial write never appears at the target."""
    target = tmp_path / "openclaw_hermes_smoke.prom"
    result = s.SmokeResult(
        ok=False, duration_seconds=90.0, response_bytes=0, timestamp=0.0
    )
    s.write_metrics(result, target=str(target))
    assert target.exists()
    assert not (tmp_path / "openclaw_hermes_smoke.prom.tmp").exists()


# ---------------- Task 6: End-to-end with fake server ----------------


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
            self.send_error(404)
            return
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
            self.send_error(400)
            return
        self.send_response(202)
        self.end_headers()
        # If it's a tools/call we push a result through the SSE stream
        if req.get("method") == "tools/call":
            req_id = req["id"]
            response = json.dumps({
                "jsonrpc": "2.0", "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": "OK"}],
                    "isError": False,
                },
            })
            writer = self.server_state.get("sse_writer")
            if writer:
                writer.write(f"event: message\r\ndata: {response}\r\n\r\n".encode())
                writer.flush()
                self.server_state["release"].set()


def _start_fake_server(handler_cls=FakeMcpHandler):
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
    handler_cls.server_state = {"release": threading.Event()}
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
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            self.send_response(202)
            self.end_headers()

    httpd = _start_fake_server(StallHandler)
    port = httpd.server_address[1]
    monkeypatch.setattr(s, "PORT", port)
    monkeypatch.setattr(s, "BUDGET_SECONDS", 1.5)  # keep test fast
    target = tmp_path / "openclaw_hermes_smoke.prom"
    result = s.run_probe(target=str(target))
    httpd.shutdown()
    assert result.ok is False
    assert result.response_bytes == 0
