import datetime as dt

from conftest import load_report_module


def test_render_headline_pass_when_all_metrics_one():
    mod = load_report_module()
    subject, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={"hermes_api_server_ok": 1, "hermes_mcp_sse_open_ok": 1,
                 "hermes_mcp_ask_hermes_ok": 1},
        smoke={"available": True, "success_ratio": 0.99, "p50_seconds": 1.2, "p95_seconds": 3.4},
        microvm_uptime={"active": "active", "since": "Mon 2026-05-20 12:00", "n_restarts": 0},
        mcp_uptime={"active": "active", "since": "Mon 2026-05-20 12:00", "n_restarts": 0},
        gateway_counts={"connect": 1, "inbound": 5, "outbound": 5, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        ssh_probe={"skipped": False, "reason": None, "http_code": "200"},
    )
    assert "PASS" in body
    assert "all healthy" in subject


def test_render_headline_fail_when_ask_ok_zero():
    mod = load_report_module()
    subject, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={"hermes_api_server_ok": 1, "hermes_mcp_sse_open_ok": 1,
                 "hermes_mcp_ask_hermes_ok": 0},
        smoke={"available": True, "success_ratio": 0.5, "p50_seconds": 60, "p95_seconds": 60},
        microvm_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        mcp_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        gateway_counts={"connect": 0, "inbound": 0, "outbound": 0, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        ssh_probe={"skipped": True, "reason": "no key", "http_code": None},
    )
    assert "FAIL" in body


def test_render_flags_stuck_incidents():
    mod = load_report_module()
    _, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={},
        smoke={"available": False, "success_ratio": None, "p50_seconds": None, "p95_seconds": None},
        microvm_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        mcp_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        gateway_counts={"connect": 0, "inbound": 0, "outbound": 0, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": ["HermesAskFailing"]},
        ssh_probe={"skipped": True, "reason": "no key", "http_code": None},
    )
    assert "STUCK" in body
    assert "HermesAskFailing" in body


def test_render_contains_all_8_section_headers():
    """Acceptance criterion §14.6: 8 section headers."""
    mod = load_report_module()
    _, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={}, smoke={"available": False, "success_ratio": None, "p50_seconds": None, "p95_seconds": None},
        microvm_uptime={"active": "?", "since": None, "n_restarts": 0},
        mcp_uptime={"active": "?", "since": None, "n_restarts": 0},
        gateway_counts={"connect": 0, "inbound": 0, "outbound": 0, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        ssh_probe={"skipped": True, "reason": "test", "http_code": None},
    )
    for header in [
        "Headline",
        "Live metrics",
        "microVM + hermes-mcp uptime",
        "24h smoke probe summary",
        "Discord activity",
        "Errors digest",
        "Self-heal incidents",
        "In-VM corroboration",
    ]:
        assert header in body, f"missing section: {header}"
