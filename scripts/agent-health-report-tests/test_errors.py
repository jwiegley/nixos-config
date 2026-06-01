import datetime as dt
from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"
m = load_report_module()


def test_hermes_errors_top_pattern_redacted():
    result = m.parse_errors_log(
        FIXTURE_DIR / "errors_log_sample.txt",
        grammar="hermes",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    top = result["patterns"][0]
    assert top["count"] == 3
    assert "[REDACTED]" in top["pattern"]
    assert "eyJabc" not in top["pattern"]


def test_hermes_errors_total_count():
    result = m.parse_errors_log(
        FIXTURE_DIR / "errors_log_sample.txt",
        grammar="hermes",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert result["total"] >= 8


def test_errors_missing_returns_minimal():
    # Backward-compatible minimal contract for a missing log.
    result = m.parse_errors_log(Path("/nonexistent.log"), grammar="hermes")
    assert result == {"total": 0, "patterns": []}


def test_openclaw_errors_redacted_and_benign_filtered(tmp_path):
    """OpenClaw grammar now redacts (new) and still benign-filters (kept)."""
    now = dt.datetime(2026, 6, 1, 12, 0, 0, tzinfo=dt.timezone.utc)
    log = tmp_path / "gateway-vm.err.log"
    log.write_text(
        "2026-06-01T11:59:00Z [auth] failed Authorization: Bearer secrettokenABCDEF123\n"
        "2026-06-01T11:59:01Z [auth] failed Authorization: Bearer othertokenXYZ987654\n"
        "2026-06-01T11:59:02Z [whatsapp] watchdog timeout (app-silent) - restarting\n"
        "2026-05-01T00:00:00Z [auth] ancient line outside the 24h window\n"
    )
    result = m.parse_errors_log(log, grammar="openclaw", window_hours=24, now=now)
    # 3 in-window lines (the May 1 one is dropped); 1 benign whatsapp warning.
    assert result["total"] == 3
    assert result["warnings_total"] == 1
    assert result["errors_total"] == 2
    # Both bearer tokens are redacted, so they bucket into ONE pattern.
    assert len(result["patterns"]) == 1
    assert result["patterns"][0]["count"] == 2
    assert "[REDACTED]" in result["patterns"][0]["pattern"]
    assert "secrettoken" not in result["patterns"][0]["pattern"]
    assert "othertoken" not in result["patterns"][0]["pattern"]
