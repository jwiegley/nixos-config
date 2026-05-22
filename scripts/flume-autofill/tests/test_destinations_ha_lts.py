"""Tests for the HA Long-Term Statistics writer."""
from __future__ import annotations

from datetime import datetime, timezone

from flume_autofill.destinations.ha_lts import (
    StatisticsPoint,
    build_import_payload,
)


def test_build_import_payload_shapes_message_correctly():
    """Two hourly points are wrapped into the recorder/import_statistics
    payload with has_sum=True (we always write cumulative totals)."""
    points = [
        StatisticsPoint(
            start=datetime(2026, 5, 15, 0, 0, tzinfo=timezone.utc),
            sum_=100.0,
            state=100.0,
        ),
        StatisticsPoint(
            start=datetime(2026, 5, 15, 1, 0, tzinfo=timezone.utc),
            sum_=125.0,
            state=125.0,
        ),
    ]
    payload = build_import_payload(
        statistic_id="flume_autofill:water_pool_autofill_total",
        name="Water Pool Autofill Total (backfilled)",
        unit_of_measurement="gal",
        points=points,
    )
    assert payload["type"] == "recorder/import_statistics"
    assert payload["statistic_id"] == "flume_autofill:water_pool_autofill_total"
    assert payload["has_sum"] is True
    assert payload["has_mean"] is False
    assert payload["unit_of_measurement"] == "gal"
    assert payload["source"] == "recorder"
    assert len(payload["stats"]) == 2
    assert payload["stats"][0]["sum"] == 100.0
    assert payload["stats"][1]["sum"] == 125.0
    # Hour-aligned ISO timestamps round-trip without loss.
    assert payload["stats"][0]["start"].startswith("2026-05-15T00:00:00")
