"""Tests for the VictoriaMetrics line-protocol writer."""
from __future__ import annotations

from datetime import datetime, timezone

import responses

from flume_autofill.destinations.vm_writer import (
    DataPoint,
    format_line_protocol,
    write_points,
)


def test_format_line_protocol():
    p = DataPoint(
        measurement="gal",
        tags={
            "entity_id": "sensor.water_pool_autofill_total",
            "water_category": "autofill",
        },
        fields={"value": 42.5},
        timestamp=datetime(2026, 5, 21, 22, 0, 0, tzinfo=timezone.utc),
    )
    line = format_line_protocol(p)
    # Measurement + first (alphabetised) tag come first.
    assert line.startswith("gal,entity_id=sensor.water_pool_autofill_total")
    assert "water_category=autofill" in line
    assert "value=42.5" in line
    # Trailing nanosecond timestamp must match the supplied datetime.
    expected_ns = int(
        datetime(2026, 5, 21, 22, 0, 0, tzinfo=timezone.utc).timestamp()
        * 1_000_000_000
    )
    assert line.endswith(str(expected_ns))


@responses.activate
def test_write_points_batches_and_posts():
    """5 points with batch_size=2 should produce 3 POSTs (2+2+1)."""
    responses.post("http://vm:8428/write")
    points = [
        DataPoint(
            measurement="gal",
            tags={"entity_id": f"sensor.x{i}"},
            fields={"value": float(i)},
            timestamp=datetime(2026, 5, 21, 22, 0, 0, tzinfo=timezone.utc),
        )
        for i in range(5)
    ]
    write_points(points, "http://vm:8428", batch_size=2)
    assert len(responses.calls) == 3
