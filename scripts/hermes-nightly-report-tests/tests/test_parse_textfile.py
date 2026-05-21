from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent.parent / "fixtures"


def test_parse_textfile_healthy():
    mod = load_report_module()
    parsed = mod.parse_textfile(FIXTURE_DIR / "hermes_health_healthy.prom")
    assert parsed["hermes_api_server_ok"] == 1.0
    assert parsed["hermes_mcp_ask_hermes_ok"] == 1.0
    assert parsed["hermes_discord_last_event_age_seconds"] == 312.5
    assert parsed["hermes_api_key_present"] == 1.0


def test_parse_textfile_degraded():
    mod = load_report_module()
    parsed = mod.parse_textfile(FIXTURE_DIR / "hermes_health_degraded.prom")
    assert parsed["hermes_mcp_sse_open_ok"] == 0.0
    assert parsed["hermes_mcp_ask_hermes_ok"] == 0.0
    assert parsed["hermes_discord_last_event_age_seconds"] == 18234.7


def test_parse_textfile_missing_returns_empty():
    mod = load_report_module()
    parsed = mod.parse_textfile(Path("/nonexistent/file.prom"))
    assert parsed == {}
