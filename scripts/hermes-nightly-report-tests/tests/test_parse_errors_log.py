from pathlib import Path
import datetime as dt

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent.parent / "fixtures"


def test_errors_log_top_patterns():
    mod = load_report_module()
    result = mod.parse_errors_log(
        FIXTURE_DIR / "errors_log_sample.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    # Top pattern should be LiteLLM 401: bearer (3x); the bearer is redacted.
    top = result["patterns"][0]
    assert top["count"] == 3
    assert "[REDACTED]" in top["pattern"]
    assert "eyJabc" not in top["pattern"]


def test_errors_log_total_count():
    mod = load_report_module()
    result = mod.parse_errors_log(
        FIXTURE_DIR / "errors_log_sample.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert result["total"] >= 8


def test_errors_log_missing_returns_zero():
    mod = load_report_module()
    result = mod.parse_errors_log(Path("/nonexistent.log"), 24)
    assert result == {"total": 0, "patterns": []}
