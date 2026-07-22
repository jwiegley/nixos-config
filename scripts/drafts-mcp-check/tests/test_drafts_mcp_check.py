from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
import types
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).parents[1] / "drafts_mcp_check.py"
VALID_INITIALIZE_RESPONSE = {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "serverInfo": {"name": "drafts-mcp", "version": "1"},
    },
}
VALID_TOOLS_LIST_RESPONSE = {
    "jsonrpc": "2.0",
    "id": 2,
    "result": {"tools": []},
}
VALID_TOOL_RESPONSE = {
    "jsonrpc": "2.0",
    "id": 3,
    "result": {"content": [{"type": "text", "text": "Workspace"}]},
}


@pytest.fixture
def probe(monkeypatch: pytest.MonkeyPatch):
    httpx_stub = types.ModuleType("httpx")
    monkeypatch.setitem(sys.modules, "httpx", httpx_stub)

    spec = importlib.util.spec_from_file_location("drafts_mcp_check", MODULE_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_scheduled_request_sequence_never_calls_a_tool(probe):
    requests = probe.build_mcp_requests(app_check=False)

    assert [request["method"] for request in requests] == [
        "initialize",
        "notifications/initialized",
        "tools/list",
    ]
    assert all(request["method"] != "tools/call" for request in requests)


def test_manual_request_sequence_calls_only_read_only_workspace_tool(probe):
    requests = probe.build_mcp_requests(app_check=True)

    calls = [request for request in requests if request["method"] == "tools/call"]
    assert calls == [
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "drafts_list_workspaces",
                "arguments": {},
            },
        }
    ]


@pytest.mark.parametrize(
    "response",
    [
        None,
        {},
        {"jsonrpc": "1.0", "result": VALID_INITIALIZE_RESPONSE["result"]},
        {"jsonrpc": "2.0", "error": {"code": -32603}},
        {"jsonrpc": "2.0", "result": []},
        {"jsonrpc": "2.0", "result": {}},
        {
            "jsonrpc": "2.0",
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
            },
        },
    ],
)
def test_initialize_response_rejects_malformed_envelopes(probe, response):
    assert probe._initialize_result_ok(response) is False


def test_initialize_response_accepts_required_mcp_fields(probe):
    assert probe._initialize_result_ok(VALID_INITIALIZE_RESPONSE) is True


@pytest.mark.parametrize(
    "response",
    [
        None,
        {},
        {"jsonrpc": "1.0", "result": {"tools": []}},
        {"jsonrpc": "2.0", "error": {"code": -32603}},
        {"jsonrpc": "2.0", "result": {}},
        {"jsonrpc": "2.0", "result": {"tools": {}}},
    ],
)
def test_tools_list_response_requires_jsonrpc_tools_array(probe, response):
    assert probe._tools_list_result_ok(response) is False


def test_tools_list_response_accepts_tools_array(probe):
    assert probe._tools_list_result_ok(VALID_TOOLS_LIST_RESPONSE) is True


@pytest.mark.parametrize(
    "response",
    [
        None,
        {},
        {"jsonrpc": "1.0", "result": VALID_TOOL_RESPONSE["result"]},
        {"jsonrpc": "2.0", "error": {"code": -32603}},
        {"jsonrpc": "2.0", "result": {}},
        {"jsonrpc": "2.0", "result": {"content": []}},
        {
            "jsonrpc": "2.0",
            "result": {
                "isError": True,
                "content": [{"type": "text", "text": "denied"}],
            },
        },
        {
            "jsonrpc": "2.0",
            "result": {"content": [{"type": "text", "text": 3}]},
        },
    ],
)
def test_tool_response_requires_successful_nonempty_text_content(probe, response):
    assert probe._tool_result_ok(response) is False


def test_tool_response_accepts_successful_text_content(probe):
    assert probe._tool_result_ok(VALID_TOOL_RESPONSE) is True


@pytest.mark.parametrize(
    ("app_check", "expected_methods", "expected_result"),
    [
        (
            False,
            ["initialize", "notifications/initialized", "tools/list"],
            (1, None),
        ),
        (
            True,
            [
                "initialize",
                "notifications/initialized",
                "tools/list",
                "tools/call",
            ],
            (1, 1),
        ),
    ],
)
def test_probe_mcp_posts_only_the_selected_request_sequence(
    probe,
    monkeypatch: pytest.MonkeyPatch,
    app_check: bool,
    expected_methods: list[str],
    expected_result: tuple[int, int | None],
):
    events = [
        "data: /messages/?session_id=test",
        f"data: {json.dumps(VALID_INITIALIZE_RESPONSE)}",
        f"data: {json.dumps(VALID_TOOLS_LIST_RESPONSE)}",
    ]
    if app_check:
        events.append("data: " + json.dumps(VALID_TOOL_RESPONSE))

    class Lines:
        def __init__(self):
            self._events = iter(events)

        def __aiter__(self):
            return self

        async def __anext__(self):
            try:
                return next(self._events)
            except StopIteration as error:
                raise StopAsyncIteration from error

    class Response:
        status_code = 200

        def __init__(self):
            self._lines = Lines()

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return False

        def aiter_lines(self):
            return self._lines

    class Posted:
        def raise_for_status(self):
            return None

    class Client:
        def __init__(self):
            self.posts: list[dict] = []

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return False

        def stream(self, method, url):
            assert method == "GET"
            assert url == probe.DRAFTS_MCP_SSE_URL
            return Response()

        async def post(self, _url, *, json, headers):
            assert headers == {"Accept": "application/json, text/event-stream"}
            self.posts.append(json)
            return Posted()

    client = Client()
    monkeypatch.setattr(
        probe.httpx,
        "AsyncClient",
        lambda **_kwargs: client,
        raising=False,
    )

    assert asyncio.run(probe.probe_mcp(app_check)) == expected_result
    assert [request["method"] for request in client.posts] == expected_methods


def test_periodic_metrics_are_transport_only(probe):
    metrics = probe.periodic_metrics(
        bridge_up=1,
        sse_open_ok=1,
        ssh_hera_ok=1,
        timestamp=123.5,
    )

    assert set(metrics) == {
        "drafts_mcp_bridge_up",
        "drafts_mcp_sse_open_ok",
        "drafts_mcp_ssh_hera_ok",
        "drafts_mcp_check_last_run_timestamp_seconds",
    }
    assert "drafts_mcp_tcc_automation_ok" not in metrics
    assert "drafts_mcp_e2e_ok" not in metrics


def test_parse_args_defaults_to_noninvasive_mode(probe):
    assert probe.parse_args([]).app_check is False
    assert probe.parse_args(["--app-check"]).app_check is True


def test_scheduled_mode_writes_transport_metrics(
    probe, monkeypatch: pytest.MonkeyPatch
):
    async def fake_sse_open() -> int:
        return 1

    async def fake_probe_mcp(app_check: bool):
        assert app_check is False
        return (1, None)

    written: list[dict[str, int | float]] = []
    monkeypatch.setattr(probe, "unit_is_active", lambda _unit: 1)
    monkeypatch.setattr(probe, "probe_sse_open", fake_sse_open)
    monkeypatch.setattr(probe, "probe_mcp", fake_probe_mcp)
    monkeypatch.setattr(probe, "write_metrics", written.append)
    monkeypatch.setattr(probe.time, "time", lambda: 123.5)

    assert asyncio.run(probe.main_async(app_check=False)) == 0
    assert written == [
        {
            "drafts_mcp_bridge_up": 1,
            "drafts_mcp_sse_open_ok": 1,
            "drafts_mcp_ssh_hera_ok": 1,
            "drafts_mcp_check_last_run_timestamp_seconds": 123.5,
        }
    ]


def test_manual_mode_never_writes_periodic_metrics_and_fails_closed(
    probe,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
):
    async def fake_probe_mcp(app_check: bool):
        assert app_check is True
        return (1, 0)

    def forbidden_write(_metrics):
        pytest.fail("manual app check must not write periodic metrics")

    monkeypatch.setattr(probe, "probe_mcp", fake_probe_mcp)
    monkeypatch.setattr(probe, "write_metrics", forbidden_write)

    assert asyncio.run(probe.main_async(app_check=True)) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == "drafts-mcp app check: read-only tool failed\n"


def test_manual_mode_succeeds_only_after_transport_and_app_succeed(
    probe,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
):
    async def fake_probe_mcp(app_check: bool):
        assert app_check is True
        return (1, 1)

    monkeypatch.setattr(probe, "probe_mcp", fake_probe_mcp)
    monkeypatch.setattr(
        probe,
        "write_metrics",
        lambda _metrics: pytest.fail(
            "manual app check must not write periodic metrics"
        ),
    )

    assert asyncio.run(probe.main_async(app_check=True)) == 0
    captured = capsys.readouterr()
    assert captured.out == "drafts-mcp app check: ok\n"
    assert captured.err == ""
