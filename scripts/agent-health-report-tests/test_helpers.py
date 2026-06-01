from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"
m = load_report_module()


def test_redact_bearer_and_keys():
    assert m.redact("Authorization: Bearer abc123def456ghi789") == \
        "Authorization: [REDACTED]"
    assert "sk-ant" not in m.redact("key sk-ant-abcdefghijklmnopqrstuvwx")
    assert m.redact("token=supersecretvalue") == "[REDACTED]"


def test_parse_prom_textfile_keeps_label_keys():
    parsed = m.parse_prom_textfile(FIXTURE_DIR / "hermes_health_healthy.prom")
    assert parsed["hermes_api_server_ok"] == 1.0
    assert parsed["hermes_mcp_ask_hermes_ok"] == 1.0
    assert parsed["hermes_api_key_present"] == 1.0


def test_parse_prom_textfile_degraded():
    parsed = m.parse_prom_textfile(FIXTURE_DIR / "hermes_health_degraded.prom")
    assert parsed["hermes_mcp_sse_open_ok"] == 0.0
    assert parsed["hermes_mcp_ask_hermes_ok"] == 0.0


def test_parse_prom_textfile_missing_returns_empty():
    assert m.parse_prom_textfile(Path("/nonexistent/file.prom")) == {}


def test_parse_prom_textfiles_merges():
    merged = m.parse_prom_textfiles([
        FIXTURE_DIR / "hermes_health_healthy.prom",
        FIXTURE_DIR / "hermes_health_degraded.prom",
    ])
    # degraded listed second → its value wins on any clashing key
    assert merged["hermes_mcp_ask_hermes_ok"] == 0.0


def test_server_ok_map_extracts_labels():
    live = {
        'openclaw_mcporter_server_ok{name="vane"}': 1.0,
        'openclaw_mcporter_server_ok{name="searxng"}': 0.0,
        "unrelated_metric": 5.0,
    }
    got = m._server_ok_map(live, "openclaw_mcporter_server_ok")
    assert got == {"vane": 1, "searxng": 0}


def test_server_ok_map_none_metric():
    assert m._server_ok_map({"x": 1.0}, None) == {}
