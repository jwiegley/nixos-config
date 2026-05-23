"""B-Hyve irrigation session extraction.

Reads `valve.sprinkler_control_*_zone` open/closed transitions from the
HA Postgres `states` table and folds them into irrigation sessions
(overlapping/adjacent zone runs merged with a gap threshold).

The output is a list of (start_ts, end_ts) intervals in LOCAL naive time
(America/Los_Angeles) so the result aligns directly with the timestamps
in `flume_segments` and `flume_minute_samples`.

Used by `classify_v2.py` to suppress false-positive pool_autofill
detections during scheduled watering windows.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Iterable
from zoneinfo import ZoneInfo

import psycopg2

from .sources.ha_postgres import (
    parse_valve_events,
    valve_events_sql,
)

LOCAL_TZ = ZoneInfo("America/Los_Angeles")

# Merge per-zone intervals into one session when the gap between the
# previous close and the next open is at most this much. Observed in
# B-Hyve evening runs: inter-zone gaps are typically 0-30s; 10 min is
# enough slack to absorb soak cycles without bridging two separate
# scheduled runs (which are usually hours apart).
SESSION_GAP_MERGE = timedelta(minutes=10)

# Discovered empirically: HA recorder only carries `valve.*` history back
# to about 30 days. Older flume_segments rows can't be cross-checked
# against B-Hyve ground truth and get classified with `(no B-Hyve data)`
# noted in the reason string.
HA_RECORDER_RETENTION_DAYS = 30


@dataclass(frozen=True)
class IrrigationSession:
    start_ts: datetime  # local naive (America/Los_Angeles)
    end_ts: datetime    # local naive (America/Los_Angeles)
    zone_count: int
    zones: str          # comma-separated zone slugs (sorted, unique)


def _zone_from_entity(entity_id: str) -> str:
    # "valve.sprinkler_control_front_yard_zone" -> "front_yard"
    return entity_id.removeprefix("valve.sprinkler_control_").removesuffix("_zone")


def _to_local_naive(ts_utc: datetime) -> datetime:
    if ts_utc.tzinfo is None:
        ts_utc = ts_utc.replace(tzinfo=timezone.utc)
    return ts_utc.astimezone(LOCAL_TZ).replace(tzinfo=None)


def merge_intervals_to_sessions(
    intervals: Iterable[tuple[datetime, datetime, str]],
    gap_merge: timedelta = SESSION_GAP_MERGE,
) -> list[IrrigationSession]:
    """Fold sorted (open, close, zone) intervals into merged sessions.

    Pure function: takes any iterable of UTC-or-local timestamps and
    returns sessions in the same time domain. The caller decides whether
    to convert to local time before or after merging.
    """
    sorted_intervals = sorted(intervals, key=lambda t: t[0])
    sessions: list[IrrigationSession] = []
    if not sorted_intervals:
        return sessions

    cur_start, cur_end, _ = sorted_intervals[0]
    cur_zones: set[str] = {sorted_intervals[0][2]}

    for start, end, zone in sorted_intervals[1:]:
        if start - cur_end <= gap_merge:
            if end > cur_end:
                cur_end = end
            cur_zones.add(zone)
        else:
            sessions.append(
                IrrigationSession(
                    start_ts=cur_start,
                    end_ts=cur_end,
                    zone_count=len(cur_zones),
                    zones=",".join(sorted(cur_zones)),
                )
            )
            cur_start, cur_end, cur_zones = start, end, {zone}

    sessions.append(
        IrrigationSession(
            start_ts=cur_start,
            end_ts=cur_end,
            zone_count=len(cur_zones),
            zones=",".join(sorted(cur_zones)),
        )
    )
    return sessions


VALVE_ENTITY_IDS = [
    "valve.sprinkler_control_along_driveway_zone",
    "valve.sprinkler_control_around_dining_set_zone",
    "valve.sprinkler_control_back_of_house_and_side_yard_left_zone",
    "valve.sprinkler_control_back_wall_zone",
    "valve.sprinkler_control_drip_front_left_zone",
    "valve.sprinkler_control_drip_front_right_zone",
    "valve.sprinkler_control_front_yard_zone",
    "valve.sprinkler_control_planter_box_zone",
    "valve.sprinkler_control_side_yard_right_zone",
    "valve.sprinkler_control_zone_5_zone",
]


def extract_sessions_from_ha(
    ha_dsn: str,
    since_local: datetime,
    until_local: datetime,
) -> list[IrrigationSession]:
    """Query HA Postgres for valve events in [since_local, until_local)
    and return merged irrigation sessions in local naive time.

    `since_local` / `until_local` are naive datetimes interpreted as
    America/Los_Angeles wall clock time.
    """
    since_utc = since_local.replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    until_utc = until_local.replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)

    sql, params = valve_events_sql(VALVE_ENTITY_IDS, since_utc, until_utc)
    with psycopg2.connect(ha_dsn) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()

    valve_intervals = parse_valve_events(rows)
    local_intervals = [
        (
            _to_local_naive(iv.opened_at),
            _to_local_naive(iv.closed_at),
            _zone_from_entity(iv.entity_id),
        )
        for iv in valve_intervals
    ]
    return merge_intervals_to_sessions(local_intervals)


# DDL is colocated with flume_segments DDL in flume_db_sync.py SCHEMA_DDL;
# UPSERT pattern lives here so callers don't have to re-derive it.
UPSERT_SESSION_SQL = """
INSERT INTO irrigation_sessions (start_ts, end_ts, zone_count, zones, source)
VALUES (%s, %s, %s, %s, %s)
ON CONFLICT (start_ts) DO UPDATE SET
    end_ts      = EXCLUDED.end_ts,
    zone_count  = EXCLUDED.zone_count,
    zones       = EXCLUDED.zones,
    source      = EXCLUDED.source,
    detected_at = now();
"""


def persist_sessions(
    conn,
    sessions: Iterable[IrrigationSession],
    source: str = "bhyve_valve",
) -> int:
    """UPSERT sessions into the irrigation_sessions table. Returns count."""
    rows = [
        (s.start_ts, s.end_ts, s.zone_count, s.zones, source)
        for s in sessions
    ]
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(UPSERT_SESSION_SQL, rows)
    return len(rows)


def sessions_for_date(conn, d: date) -> list[tuple[datetime, datetime]]:
    """Read existing sessions touching date `d` (any overlap).

    Returns (start_ts, end_ts) tuples in local naive time. Used by the
    classifier to test segment overlap.
    """
    day_start = datetime(d.year, d.month, d.day)
    day_end = day_start + timedelta(days=1)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT start_ts, end_ts
              FROM irrigation_sessions
             WHERE start_ts < %s AND end_ts > %s
             ORDER BY start_ts
            """,
            (day_end, day_start),
        )
        return list(cur.fetchall())


def have_valve_data_for_date(conn, d: date) -> bool:
    """Cheap check: does irrigation_sessions have ANY row whose source is
    'bhyve_valve' on or near date `d`? Used to decide whether v2
    classification can apply the irrigation rule for that day, or has
    to fall back to the 2-rule (no irrigation context) variant.

    Returns True if EITHER:
      * a session overlaps `d`, OR
      * there are sessions in the surrounding ±2 days
        (proves HA recorder retention covers this date even if no
        watering happened on `d` itself).
    """
    window_start = datetime(d.year, d.month, d.day) - timedelta(days=2)
    window_end = datetime(d.year, d.month, d.day) + timedelta(days=3)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT 1
              FROM irrigation_sessions
             WHERE source = 'bhyve_valve'
               AND start_ts < %s AND end_ts > %s
             LIMIT 1
            """,
            (window_end, window_start),
        )
        return cur.fetchone() is not None
