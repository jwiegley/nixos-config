import datetime as dt

from conftest import load_report_module

m = load_report_module()

SECTION_HEADERS = [
    "Headline",
    "Live metrics",
    "MCP servers",
    "Gateway + plugins",
    "microVM + sidecars uptime",
    "24h probe summary (Prometheus)",
    "Discord activity (last 24h)",
    "Home Assistant MCP",
    "Errors digest",
    "Self-heal incidents (last 24h)",
    "In-VM corroboration",
]

NOW = dt.datetime(2026, 6, 1, 6, 0, 0)


def _base(profile):
    """A minimal all-green data dict for the given profile."""
    return {
        "host": "vulcan",
        "now": NOW,
        "live": {},
        "live_selfheal": {},
        "servers": {},
        "mcp_log": {},
        "uptime": {u: {"active": "active", "since": "Sat 2026-05-31", "n_restarts": 0}
                   for u in profile["units"]},
        "probes": [{**f, "success_ratio": 1.0, "p50_seconds": 6.0,
                    "p95_seconds": 12.0, "available": True}
                   for f in profile["probe_families"]],
        "discord": {"counts": {t: 0 for t in m.EVENT_KEYWORDS}, "latest": {}},
        "errors": {"available": True, "total": 0, "errors_total": 0,
                   "warnings_total": 0, "patterns": [], "warnings": []},
        "incidents": {"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        "invm": {"skipped": False, "reason": None,
                 "results": {"trader /api/schwab/status": "200",
                             "trader requests-TLS": "OK"}},
    }


def _assert_headers_in_order(body):
    idxs = []
    for h in SECTION_HEADERS:
        assert h in body, f"missing section header: {h}"
        idxs.append(body.index(h))
    assert idxs == sorted(idxs), "section headers out of order"


def test_render_openclaw_all_headers_in_order():
    p = m.PROFILES["openclaw"]
    data = _base(p)
    data["live"]["openclaw_mcporter_ha_auth_ok"] = 1.0
    subject, body = m.render(p, data)
    _assert_headers_in_order(body)
    assert subject.startswith("[openclaw-nightly] vulcan 2026-06-01")
    assert "PASS" in body


def test_render_hermes_all_headers_in_order():
    p = m.PROFILES["hermes"]
    data = _base(p)
    data["live"].update({"hermes_api_server_ok": 1.0, "hermes_mcp_sse_open_ok": 1.0,
                         "hermes_mcp_ask_hermes_ok": 1.0})
    subject, body = m.render(p, data)
    _assert_headers_in_order(body)
    assert subject.startswith("[hermes-nightly] vulcan 2026-06-01")
    assert "PASS" in body


def test_render_hermes_gateway_real_analog():
    # §3 is now a REAL platform/MCP-readiness analog (not n/a): platform
    # liveness + loaded-server/tool totals + reconnect health.
    p = m.PROFILES["hermes"]
    data = _base(p)
    data["mcp_log"] = {"servers": {"vane": 5}, "total_tools": 67,
                       "total_servers": 6, "reconnects_24h": 1,
                       "reconnect_servers": ["vane"]}
    data["live"].update({"hermes_discord_heartbeat_age_seconds": 20.0,
                         "hermes_discord_heartbeat_present": 1.0})
    joined = "\n".join(m.render_gateway(p, data))
    assert "platform:" in joined and "discord" in joined
    assert "MCP servers loaded:   6 (67 tools" in joined
    assert "MCP reconnects (24h): 1" in joined
    assert "web_search backend:" in joined and "SearXNG (native)" in joined
    assert "n/a" not in joined


def test_render_gateway_none_is_na():
    # Defensive: a profile that declares no gateway analog still renders cleanly.
    p = {**m.PROFILES["hermes"], "gateway": None}
    data = _base(p)
    assert "n/a" in "\n".join(m.render_gateway(p, data))


def test_render_hermes_ha_mcp_derived_real():
    # §7 is now REAL for Hermes: HA tool registration proves token+endpoint+auth.
    p = m.PROFILES["hermes"]
    data = _base(p)
    data["mcp_log"] = {"servers": {"home-assistant": 28}}
    _, body = m.render(p, data)
    ha_idx = body.index("Home Assistant MCP")
    after = body[ha_idx:ha_idx + 300]
    assert "connected (28 tools registered)" in after
    assert "bearer token accepted:  OK" in after
    assert "n/a" not in after


def test_render_headline_fail_lists_issue():
    p = m.PROFILES["hermes"]
    data = _base(p)
    data["live"].update({"hermes_api_server_ok": 0, "hermes_mcp_sse_open_ok": 1.0,
                         "hermes_mcp_ask_hermes_ok": 1.0})
    subject, body = m.render(p, data)
    assert "FAIL" in body
    assert "api_server down" in body
    assert "api_server down" in subject


def test_render_active_incident_in_summary_not_fail():
    # An active (in-progress, not stuck) incident → still PASS, but surfaced.
    p = m.PROFILES["openclaw"]
    data = _base(p)
    data["live"]["openclaw_mcporter_ha_auth_ok"] = 1.0
    data["incidents"]["active"] = 1
    subject, body = m.render(p, data)
    assert "PASS" in body
    assert "1 active self-heal incident" in subject


def test_render_flags_stuck_incidents():
    p = m.PROFILES["hermes"]
    data = _base(p)
    data["live"].update({"hermes_api_server_ok": 1.0, "hermes_mcp_sse_open_ok": 1.0,
                         "hermes_mcp_ask_hermes_ok": 1.0})
    data["incidents"]["stuck_alerts"] = ["HermesAskFailing"]
    _, body = m.render(p, data)
    assert "STUCK" in body
    assert "HermesAskFailing" in body
    assert "FAIL" in body  # stuck → issue → FAIL


def test_render_openclaw_mcp_table_and_blind():
    p = m.PROFILES["openclaw"]
    data = _base(p)
    data["live"].update({
        "openclaw_mcporter_ha_auth_ok": 1.0,
        'openclaw_mcporter_server_ok{name="vane"}': 1.0,
        'openclaw_mcporter_server_ok{name="home-assistant"}': 1.0,
    })
    data["servers"] = {"vane": {"tool_count": 1, "status": "1 tool, 0.6s", "raw": "-"}}
    # home-assistant is host-blind and absent from servers → "skipped from host context"
    lines = m.render_mcp_servers(p, data)
    joined = "\n".join(lines)
    assert "vane" in joined and "1" in joined
    assert "skipped from host context" in joined


def test_render_hermes_mcp_real_per_server_counts():
    # Parity with OpenClaw: real per-server tool counts (from agent.log).
    p = m.PROFILES["hermes"]
    data = _base(p)
    data["mcp_log"] = {
        "servers": {"vane": 5, "home-assistant": 28, "stock-trader": 12,
                    "email-contacts": 11, "perplexity": 5, "org-db": 6},
        "total_tools": 67, "total_servers": 6,
        "reconnects_24h": 0, "reconnect_servers": [],
    }
    data["live"].update({"hermes_mcp_sse_open_ok": 1.0,
                         "hermes_mcp_ask_hermes_ok": 1.0,
                         "hermes_mcp_ask_hermes_seconds": 0.53})
    joined = "\n".join(m.render_mcp_servers(p, data))
    assert "home-assistant" in joined and "28" in joined
    assert "stock-trader" in joined and "12" in joined
    assert "tools registered" in joined
    assert "OK" in joined  # struct column now shows OK like OpenClaw
    assert "total: 67 tools from 6 servers" in joined
    assert "MCP layer: sse_open=OK  ask_hermes=OK" in joined


def test_render_gateway_survives_multilabel_channel_key():
    # H1 regression: a channel series with an extra label must not crash render.
    p = m.PROFILES["openclaw"]
    data = _base(p)
    data["live"]['openclaw_channel_plugin_loaded{instance="i",channel="discord"}'] = 1.0
    lines = m.render_gateway(p, data)
    assert "discord" in "\n".join(lines)


def test_render_selfheal_survives_multilabel_action_key():
    # H1 regression: an attempts series with an extra label must not crash.
    p = m.PROFILES["openclaw"]
    data = _base(p)
    data["live_selfheal"]['openclaw_self_heal_attempts_total{instance="i",action="restart_microvm"}'] = 3.0
    lines = m.render_selfheal(p, data)
    assert "restart_microvm=3" in "\n".join(lines)


def test_render_invm_skipped_is_na():
    p = m.PROFILES["hermes"]
    data = _base(p)
    data["live"].update({"hermes_api_server_ok": 1.0, "hermes_mcp_sse_open_ok": 1.0,
                         "hermes_mcp_ask_hermes_ok": 1.0})
    data["invm"] = {"skipped": True, "reason": "no SSH key available", "results": {}}
    _, body = m.render(p, data)
    inv_idx = body.index("In-VM corroboration")
    assert "n/a" in body[inv_idx:inv_idx + 120]
