"""Tests for the HA Postgres source.

We don't mock psycopg2 directly; instead we test the SQL-rendering helpers
and verify the row-parsing logic against synthetic rows.
"""
from __future__ import annotations

from datetime import datetime, timezone

from flume_data.sources.ha_postgres import (
    parse_sensor_states,
    parse_valve_events,
    valve_events_sql,
)


def test_valve_events_sql_contains_entity_filter():
    sql, params = valve_events_sql(
        entity_ids=["valve.sprinkler_control_front_yard_zone"],
        since=datetime(2026, 5, 20, tzinfo=timezone.utc),
        until=datetime(2026, 5, 21, tzinfo=timezone.utc),
    )
    assert "states_meta" in sql
    assert "metadata_id" in sql
    assert len(params) == 3  # entity list, since, until


def test_parse_valve_events_returns_open_close_intervals():
    # synthetic rows: (last_updated_ts, entity_id, state)
    rows = [
        (1716595200.0, "valve.sprinkler_control_front_yard_zone", "open"),
        (1716595560.0, "valve.sprinkler_control_front_yard_zone", "closed"),
        (1716595800.0, "valve.sprinkler_control_front_yard_zone", "open"),
        (1716596100.0, "valve.sprinkler_control_front_yard_zone", "closed"),
    ]
    events = parse_valve_events(rows)
    assert len(events) == 2
    assert events[0].entity_id == "valve.sprinkler_control_front_yard_zone"
    assert events[0].opened_at.timestamp() == 1716595200.0
    assert events[0].closed_at.timestamp() == 1716595560.0


def test_parse_sensor_states_filters_nonnumeric():
    rows = [
        (1716595200.0, "sensor.x", "4.1"),
        (1716595260.0, "sensor.x", "unavailable"),
        (1716595320.0, "sensor.x", "4.0"),
    ]
    series = parse_sensor_states(rows)
    assert len(series) == 2
    assert [v for _, v in series] == [4.1, 4.0]
