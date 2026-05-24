"""Tankless water heater (Navien) hot-water-flow reader.

Pulls `sensor.water_heater_ch1_ch1_unit1_hot_water_flow` event-driven
state changes from the HA Postgres `states` table, forward-fills to
per-minute samples, and persists into `tankless_minute_samples`.

Used by the fixture classifier to discriminate hot-water-using fixtures
(shower, dishwasher, washer-hot) from cold-only fixtures (toilet,
irrigation, pool autofill).

Note: HA reports state on every CHANGE, not periodically — so the raw
events are irregularly spaced. We forward-fill: each per-minute slot
inherits the last reported value strictly before or at that minute.
A minute with no events keeps the prior value (which may be 0).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Iterable
from zoneinfo import ZoneInfo

import psycopg2

from .sources.ha_postgres import sensor_states_sql

LOCAL_TZ = ZoneInfo("America/Los_Angeles")

TANKLESS_ENTITY_ID = "sensor.water_heater_ch1_ch1_unit1_hot_water_flow"


@dataclass(frozen=True)
class FlowEvent:
    ts: datetime  # local naive (America/Los_Angeles)
    gpm: float


def parse_flow_events(
    rows: Iterable[tuple[float, str, str]],
) -> list[FlowEvent]:
    """Convert (ts_epoch, entity, state) rows into FlowEvent list.
    Drops `unknown` / `unavailable` / any non-numeric state.
    """
    out: list[FlowEvent] = []
    for ts, _entity, state in rows:
        try:
            v = float(state)
        except (TypeError, ValueError):
            continue
        when_utc = datetime.fromtimestamp(float(ts), tz=timezone.utc)
        when_local = when_utc.astimezone(LOCAL_TZ).replace(tzinfo=None)
        out.append(FlowEvent(ts=when_local, gpm=v))
    return out


def interpolate_to_minutes(
    events: list[FlowEvent],
    start: datetime,
    end: datetime,
    initial_gpm: float = 0.0,
) -> list[tuple[datetime, float]]:
    """Forward-fill irregular events into per-minute samples.

    Returns one tuple per minute in [start, end), with `gpm` = the value
    of the most recent event whose ts <= minute (or `initial_gpm` if no
    prior event exists yet).
    """
    # Round start/end to whole minutes to avoid sub-minute boundary mess.
    minute_start = start.replace(second=0, microsecond=0)
    minute_end = end.replace(second=0, microsecond=0)
    if minute_end < end:
        minute_end += timedelta(minutes=1)

    sorted_events = sorted(events, key=lambda e: e.ts)
    samples: list[tuple[datetime, float]] = []
    current_gpm = initial_gpm
    ev_idx = 0
    cur = minute_start
    while cur < minute_end:
        # Apply every event at or before the *next* minute to bring
        # current_gpm up to date.
        next_minute = cur + timedelta(minutes=1)
        while ev_idx < len(sorted_events) and sorted_events[ev_idx].ts < next_minute:
            current_gpm = sorted_events[ev_idx].gpm
            ev_idx += 1
        samples.append((cur, current_gpm))
        cur = next_minute
    return samples


def fetch_events_from_ha(
    ha_dsn: str,
    since_local: datetime,
    until_local: datetime,
) -> list[FlowEvent]:
    """Pull hot-water-flow state changes from HA Postgres in window."""
    since_utc = since_local.replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    until_utc = until_local.replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    sql, params = sensor_states_sql(TANKLESS_ENTITY_ID, since_utc, until_utc)
    with psycopg2.connect(ha_dsn) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()
    return parse_flow_events(rows)


def fetch_prior_value(
    ha_dsn: str,
    before_local: datetime,
    lookback_days: int = 7,
) -> float:
    """Find the most recent flow value strictly before `before_local`.

    Used as the initial_gpm for interpolation when a sync window starts
    mid-flow (avoids assuming zero flow at the leading edge).
    """
    end_utc = before_local.replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    start_utc = end_utc - timedelta(days=lookback_days)
    sql, params = sensor_states_sql(TANKLESS_ENTITY_ID, start_utc, end_utc)
    with psycopg2.connect(ha_dsn) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()
    events = parse_flow_events(rows)
    return events[-1].gpm if events else 0.0


UPSERT_TANKLESS_SQL = """
INSERT INTO tankless_minute_samples (ts, gpm)
VALUES %s
ON CONFLICT (ts) DO UPDATE SET gpm = EXCLUDED.gpm
"""


def persist_minute_samples(
    conn,
    samples: list[tuple[datetime, float]],
) -> int:
    """UPSERT per-minute samples. Returns count."""
    if not samples:
        return 0
    from psycopg2.extras import execute_values
    with conn.cursor() as cur:
        execute_values(cur, UPSERT_TANKLESS_SQL, samples, page_size=2000)
    return len(samples)


def sync_range_from_ha(
    conn,
    ha_dsn: str,
    since_local: datetime,
    until_local: datetime,
) -> int:
    """Pull events from HA Postgres, interpolate, persist. Returns rows
    written. Used by both the one-shot backfill and the periodic sync.
    """
    events = fetch_events_from_ha(ha_dsn, since_local, until_local)
    initial = fetch_prior_value(ha_dsn, since_local)
    samples = interpolate_to_minutes(events, since_local, until_local, initial)
    return persist_minute_samples(conn, samples)


def have_hot_water_data_for_date(conn, d: date) -> bool:
    """Cheap check: does tankless_minute_samples have ANY row for this date?"""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT 1 FROM tankless_minute_samples
             WHERE ts::date = %s LIMIT 1
            """,
            (d,),
        )
        return cur.fetchone() is not None
