import datetime as dt
from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"
m = load_report_module()


def test_gateway_log_counts_events_by_type():
    result = m.parse_gateway_log(
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
    result = m.parse_gateway_log(Path("/nonexistent.log"), 24)
    assert result == {
        "connected": 0, "registered": 0, "skipping": 0,
        "flushing": 0, "disconnected": 0,
    }


def test_gateway_log_most_recent_per_type():
    most_recent = m.most_recent_per_type(
        FIXTURE_DIR / "gateway_log_sample.txt",
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert most_recent["flushing"] == dt.datetime(2026, 5, 20, 15, 18, 4)


def test_gateway_log_parses_real_production_format():
    result = m.parse_gateway_log(
        FIXTURE_DIR / "gateway_log_real_format.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert result["connected"] == 1
    assert result["registered"] == 2
    assert result["skipping"] == 1
    assert result["flushing"] == 2
    assert result["disconnected"] == 1
