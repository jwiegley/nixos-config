import datetime as dt
from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"
m = load_report_module()

# After the 18:28 registrations; both reconnect events (05:53, 06:59) are <24h.
NOW = dt.datetime(2026, 6, 1, 19, 0)


def test_per_server_tool_counts():
    r = m.parse_hermes_mcp_log(FIXTURE_DIR / "agent_log_sample.txt", now=NOW)
    assert r["servers"]["home-assistant"] == 28
    assert r["servers"]["stock-trader"] == 12
    assert r["servers"]["vane"] == 5
    assert r["servers"]["org-db"] == 6
    assert r["servers"]["email-contacts"] == 11
    assert r["servers"]["perplexity"] == 5


def test_aggregate_totals():
    r = m.parse_hermes_mcp_log(FIXTURE_DIR / "agent_log_sample.txt", now=NOW)
    assert r["total_tools"] == 67
    assert r["total_servers"] == 6


def test_reconnects_in_window():
    r = m.parse_hermes_mcp_log(FIXTURE_DIR / "agent_log_sample.txt", now=NOW)
    assert r["reconnects_24h"] == 2
    assert set(r["reconnect_servers"]) == {"home-assistant", "vane"}


def test_reconnects_outside_window_excluded():
    # A `now` far past the reconnect events drops them from the 24h count,
    # but the registration counts (current state) are still returned.
    r = m.parse_hermes_mcp_log(FIXTURE_DIR / "agent_log_sample.txt",
                               now=dt.datetime(2026, 6, 5, 0, 0))
    assert r["reconnects_24h"] == 0
    assert r["servers"]["home-assistant"] == 28


def test_missing_log_empty():
    r = m.parse_hermes_mcp_log(Path("/nonexistent.log"))
    assert r["servers"] == {}
    assert r["total_tools"] == 0
    assert r["total_servers"] == 0
    assert r["reconnects_24h"] == 0
