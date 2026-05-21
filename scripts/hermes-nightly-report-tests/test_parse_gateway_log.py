from pathlib import Path
import datetime as dt

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_gateway_log_counts_events_by_type():
    mod = load_report_module()
    result = mod.parse_gateway_log(
        FIXTURE_DIR / "gateway_log_sample.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert result["connected"] == 1
    assert result["registered"] == 2
    assert result["skipping"] == 1
    assert result["flushing"] == 2
    assert result["disconnected"] == 1


def test_gateway_log_returns_zero_when_missing():
    mod = load_report_module()
    result = mod.parse_gateway_log(Path("/nonexistent.log"), 24)
    assert result == {
        "connected": 0,
        "registered": 0,
        "skipping": 0,
        "flushing": 0,
        "disconnected": 0,
    }


def test_gateway_log_returns_most_recent_per_type():
    mod = load_report_module()
    most_recent = mod.most_recent_per_type(
        FIXTURE_DIR / "gateway_log_sample.txt",
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    # flushing's latest line is at 15:18:04 on the 20th
    assert most_recent["flushing"] == dt.datetime(2026, 5, 20, 15, 18, 4)


def test_gateway_log_parses_real_production_format():
    """Production Hermes log uses '<ts>,ms LEVEL gateway.platforms.discord: msg'
    (space-separator, Python-logging colon form). The synthetic fixture uses
    'T'-separated + bracketed form. Both must parse, and BOTH should yield
    the same event-type vocabulary since EVENT_KEYWORDS is the same."""
    mod = load_report_module()
    result = mod.parse_gateway_log(
        FIXTURE_DIR / "gateway_log_real_format.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert result["connected"] == 1
    assert result["registered"] == 2
    assert result["skipping"] == 1
    assert result["flushing"] == 2
    assert result["disconnected"] == 1
