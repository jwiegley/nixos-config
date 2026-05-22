"""Tests for the VictoriaMetrics source."""
from __future__ import annotations

from datetime import datetime, timezone

import responses

from flume_autofill.sources.victoriametrics import VMSource


@responses.activate
def test_query_range_returns_time_series():
    responses.get(
        "http://vm:8428/api/v1/query_range",
        json={
            "status": "success",
            "data": {
                "resultType": "matrix",
                "result": [
                    {
                        "metric": {"entity_id": "sensor.flume_x_current"},
                        "values": [
                            [1716595200, "4.1"],
                            [1716595260, "4.0"],
                        ],
                    }
                ],
            },
        },
    )
    vm = VMSource("http://vm:8428")
    series = vm.query_range(
        metric='last_over_time({entity_id="sensor.flume_x_current"}[1m])',
        start=datetime(2026, 5, 24, 23, 20, tzinfo=timezone.utc),
        end=datetime(2026, 5, 24, 23, 22, tzinfo=timezone.utc),
        step="60s",
    )
    assert len(series) == 2
    assert series[0][1] == 4.1
    assert series[1][1] == 4.0


@responses.activate
def test_query_returns_empty_when_no_data():
    responses.get(
        "http://vm:8428/api/v1/query_range",
        json={"status": "success", "data": {"result": []}},
    )
    vm = VMSource("http://vm:8428")
    series = vm.query_range(
        metric="up",
        start=datetime(2026, 5, 24, tzinfo=timezone.utc),
        end=datetime(2026, 5, 25, tzinfo=timezone.utc),
        step="60s",
    )
    assert series == []
