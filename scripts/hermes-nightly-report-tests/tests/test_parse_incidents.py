from pathlib import Path
import datetime as dt

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent.parent / "fixtures"

# Fixture timestamps (1779346740 active, 1779303600 resolved) are within
# 24h of this anchor — see incidents_sample.json.
TEST_NOW = dt.datetime(2026, 5, 21, 0, 0)


def test_incidents_counts_by_status():
    mod = load_report_module()
    result = mod.parse_incidents(
        FIXTURE_DIR / "incidents_sample.json", now=TEST_NOW
    )
    assert result["active"] == 1
    assert result["resolved_24h"] >= 1


def test_incidents_lists_stuck_alerts():
    mod = load_report_module()
    result = mod.parse_incidents(
        FIXTURE_DIR / "incidents_sample.json", now=TEST_NOW
    )
    # No stuck in the fixture (status="in_progress" not "stuck")
    assert result["stuck_alerts"] == []


def test_incidents_missing_returns_empty():
    mod = load_report_module()
    result = mod.parse_incidents(Path("/nonexistent.json"))
    assert result == {"active": 0, "resolved_24h": 0, "stuck_alerts": []}
