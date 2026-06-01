from conftest import load_report_module

import pytest

m = load_report_module()

REQUIRED = {
    "agent", "display_name", "env_prefix", "report_header", "default_from",
    "live_textfiles", "expected_servers", "mcp_servers_mode", "units",
    "probe_families", "discord", "ha_mcp", "errors_log", "errors_grammar",
    "incidents_json", "selfheal_textfile", "selfheal_metric_prefix",
    "invm_checks", "verdict_fail_if_zero", "errors_fail_threshold",
}


def test_both_profiles_present():
    assert set(m.PROFILES) == {"openclaw", "hermes"}


def test_profiles_have_required_keys():
    for name, p in m.PROFILES.items():
        assert REQUIRED <= set(p), f"{name} missing {REQUIRED - set(p)}"


def test_get_profile_rejects_unknown():
    with pytest.raises(SystemExit):
        m.get_profile("nope")


def test_get_profile_returns_dict():
    assert m.get_profile("openclaw")["agent"] == "openclaw"
    assert m.get_profile("hermes")["agent"] == "hermes"


def test_hermes_inventory_excludes_searxng():
    # SearXNG is the native web backend, not an MCP server.
    assert "searxng" not in m.PROFILES["hermes"]["expected_servers"]
    assert "vane" in m.PROFILES["hermes"]["expected_servers"]
