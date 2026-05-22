"""Home Assistant Postgres source.

Reads `states` joined to `states_meta` for valve-event detection and
sensor history. Postgres connections happen via psycopg2; the SQL
rendering and row parsing are pure functions so they can be unit-tested
without a live database.
"""
from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timezone

import psycopg2


@dataclass(frozen=True)
class ValveOpenInterval:
    """Closed-interval open→closed window for a single valve entity."""

    entity_id: str
    opened_at: datetime
    closed_at: datetime


def valve_events_sql(
    entity_ids: list[str], since: datetime, until: datetime
) -> tuple[str, list]:
    """Render the SQL+params tuple for fetching valve state transitions."""
    sql = """
        SELECT s.last_updated_ts, m.entity_id, s.state
          FROM states s
          JOIN states_meta m ON s.metadata_id = m.metadata_id
         WHERE m.entity_id = ANY(%s)
           AND s.last_updated_ts >= %s
           AND s.last_updated_ts <  %s
         ORDER BY s.last_updated_ts ASC
    """
    return sql, [entity_ids, since.timestamp(), until.timestamp()]


def sensor_states_sql(
    entity_id: str, since: datetime, until: datetime
) -> tuple[str, list]:
    """Render the SQL+params tuple for fetching a single sensor's history."""
    sql = """
        SELECT s.last_updated_ts, m.entity_id, s.state
          FROM states s
          JOIN states_meta m ON s.metadata_id = m.metadata_id
         WHERE m.entity_id = %s
           AND s.last_updated_ts >= %s
           AND s.last_updated_ts <  %s
         ORDER BY s.last_updated_ts ASC
    """
    return sql, [entity_id, since.timestamp(), until.timestamp()]


def parse_valve_events(
    rows: Iterable[tuple[float, str, str]],
) -> list[ValveOpenInterval]:
    """Fold a chronological event stream into open→closed intervals.

    Unmatched opens (still open at the end of the window) are dropped —
    irrigation cycles always close, so an unclosed open implies the
    window cut mid-zone and that gallons were under-counted; the cross
    check will surface this as drift rather than a fabricated interval.
    """
    intervals: list[ValveOpenInterval] = []
    open_state: dict[str, datetime] = {}
    for ts, entity, state in rows:
        when = datetime.fromtimestamp(float(ts), tz=timezone.utc)
        if state == "open":
            open_state[entity] = when
        elif state == "closed" and entity in open_state:
            intervals.append(
                ValveOpenInterval(
                    entity_id=entity,
                    opened_at=open_state.pop(entity),
                    closed_at=when,
                )
            )
    return intervals


def parse_sensor_states(
    rows: Iterable[tuple[float, str, str]],
) -> list[tuple[datetime, float]]:
    """Convert (ts, entity, state_text) rows into numeric (ts, value) pairs.

    Skips rows where state isn't parseable as float — usually `unknown`
    or `unavailable`. The entity column is ignored; callers filter by
    entity in the SQL layer.
    """
    out: list[tuple[datetime, float]] = []
    for ts, _entity, state in rows:
        try:
            v = float(state)
        except (TypeError, ValueError):
            continue
        out.append((datetime.fromtimestamp(float(ts), tz=timezone.utc), v))
    return out


class HAPostgresSource:
    """Thin wrapper that connects + executes + parses."""

    def __init__(self, dsn: str) -> None:
        self._dsn = dsn

    def fetch_valve_events(
        self, entity_ids: list[str], since: datetime, until: datetime
    ) -> list[ValveOpenInterval]:
        sql, params = valve_events_sql(entity_ids, since, until)
        with psycopg2.connect(self._dsn) as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()
        return parse_valve_events(rows)

    def fetch_sensor_states(
        self, entity_id: str, since: datetime, until: datetime
    ) -> list[tuple[datetime, float]]:
        sql, params = sensor_states_sql(entity_id, since, until)
        with psycopg2.connect(self._dsn) as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()
        return parse_sensor_states(rows)
