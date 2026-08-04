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


