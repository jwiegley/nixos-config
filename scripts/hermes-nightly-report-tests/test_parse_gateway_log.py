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
    assert result["connect"] == 1
    assert result["inbound"] == 2
    assert result["outbound"] == 2
    assert result["reconnect"] == 1
    assert result["error"] == 1


def test_gateway_log_returns_zero_when_missing():
    mod = load_report_module()
    result = mod.parse_gateway_log(Path("/nonexistent.log"), 24)
    assert result == {
        "connect": 0,
        "inbound": 0,
        "outbound": 0,
        "reconnect": 0,
        "error": 0,
    }


def test_gateway_log_returns_most_recent_per_type():
    mod = load_report_module()
    most_recent = mod.most_recent_per_type(
        FIXTURE_DIR / "gateway_log_sample.txt",
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    # outbound's latest line is at 15:18:04 on the 20th
    assert most_recent["outbound"] == dt.datetime(2026, 5, 20, 15, 18, 4)
