import datetime as dt
from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"
m = load_report_module()

TEST_NOW = dt.datetime(2026, 5, 21, 0, 0)


def test_incidents_counts_by_status():
    result = m.parse_incidents(FIXTURE_DIR / "incidents_sample.json", now=TEST_NOW)
    assert result["active"] == 1
    assert result["resolved_24h"] >= 1


def test_incidents_lists_stuck_alerts():
    result = m.parse_incidents(FIXTURE_DIR / "incidents_sample.json", now=TEST_NOW)
    assert result["stuck_alerts"] == []


def test_incidents_missing_returns_empty():
    result = m.parse_incidents(Path("/nonexistent.json"))
    assert result == {"active": 0, "resolved_24h": 0, "stuck_alerts": []}
