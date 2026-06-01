from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"
m = load_report_module()


def test_redact_bearer_and_keys():
    assert m.redact("Authorization: Bearer abc123def456ghi789") == \
        "Authorization: [REDACTED]"
    assert "sk-ant" not in m.redact("key sk-ant-abcdefghijklmnopqrstuvwx")
    assert m.redact("token=supersecretvalue") == "[REDACTED]"


def test_redact_extended_secret_shapes():
    # New shapes (CLAUDE.md OUTPUT CHECK / spec §6,§11 promise).
    assert m.redact("psk=hunter2supersecret") == "[REDACTED]"
    assert m.redact("client_secret=abcdef123456") == "[REDACTED]"
    assert "hunter2" not in m.redact("passwd=hunter2value")
    assert "abc" not in m.redact("refresh_token=abcDEF123")
    # E.164 phone number (PII).
    assert m.redact("call +14155552671 now") == "call [REDACTED] now"
    # Pairing / registration code.
    assert "12345678" not in m.redact("HomeKit pairing code: 12345678")


def test_label_tolerates_extra_labels():
    assert m._label('x{instance="i",name="vane"}', "name") == "vane"
    assert m._label('x{name="vane"}', "name") == "vane"
    assert m._label('x{other="y"}', "name") is None


def test_server_ok_map_tolerates_extra_labels():
    live = {'openclaw_mcporter_server_ok{instance="i",name="vane"}': 1.0}
    assert m._server_ok_map(live, "openclaw_mcporter_server_ok") == {"vane": 1}


def test_parse_prom_textfile_rejects_non_finite(tmp_path):
    f = tmp_path / "x.prom"
    f.write_text("good_metric 1.5\nbad_metric NaN\ninf_metric +Inf\n")
    parsed = m.parse_prom_textfile(f)
    assert parsed == {"good_metric": 1.5}


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
