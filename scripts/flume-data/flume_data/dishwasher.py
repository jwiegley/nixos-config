"""Miele dishwasher cycle extraction.

Reads `sensor.dishwasher_program_phase` transitions from HA Postgres
and folds them into cycle windows. Captures the program name (Normal,
Eco, etc.) and the per-cycle water_consumption peak so the v3
classifier can attribute water during a cycle to dishwasher with
high confidence.

A cycle = (not_running -> pre_dishwash) ... (anything -> not_running).
The "active water" window is from pre_dishwash through drying-start;
the drying/finished phases use only heat. Cycles shorter than
MIN_CYCLE_MINUTES are dropped as aborts (user opened door, canceled).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable
from zoneinfo import ZoneInfo

import psycopg2

from .sources.ha_postgres import sensor_states_sql

LOCAL_TZ = ZoneInfo("America/Los_Angeles")

PHASE_ENTITY = "sensor.dishwasher_program_phase"
CONSUMPTION_ENTITY = "sensor.dishwasher_water_consumption"
PROGRAM_ENTITY = "sensor.dishwasher_program"

# Phases observed: pre_dishwash, main_dishwash, rinse, final_rinse,
# drying, finished, not_running, unavailable, unknown.
IDLE_PHASES = frozenset({"not_running", "finished", "unavailable", "unknown"})
WATER_PHASES = frozenset({"pre_dishwash", "main_dishwash", "rinse", "final_rinse"})

# Aborted cycles (door opened seconds after start) — observed twice in
# the user's 30-day history. Drop cycles shorter than this.
MIN_CYCLE_MINUTES = 5


@dataclass(frozen=True)
class DishwasherCycle:
    start_ts: datetime  # local naive
    end_ts: datetime    # local naive (end of last water phase)
    program: str | None
    gallons: float | None


def _to_local_naive(ts_utc: datetime) -> datetime:
    if ts_utc.tzinfo is None:
        ts_utc = ts_utc.replace(tzinfo=timezone.utc)
    return ts_utc.astimezone(LOCAL_TZ).replace(tzinfo=None)


def reconstruct_cycles(
    phase_events: list[tuple[datetime, str]],
) -> list[tuple[datetime, datetime]]:
    """Pure: walk phase transitions and emit (start_ts, end_ts) cycle
    windows. start_ts = entry into any water phase from idle;
    end_ts = exit from last water phase.

    Treats unavailable/unknown as continuation of prior phase to absorb
    integration flap.
    """
    cycles: list[tuple[datetime, datetime]] = []
    cur_start: datetime | None = None
    last_water_ts: datetime | None = None
    last_known_phase: str = "not_running"

    for ts, phase in phase_events:
        # Smooth flap: ignore unavailable/unknown
        if phase in {"unavailable", "unknown"}:
            continue

        was_idle = last_known_phase in IDLE_PHASES
        is_water = phase in WATER_PHASES
        is_idle = phase in IDLE_PHASES

        if was_idle and is_water and cur_start is None:
            cur_start = ts
            last_water_ts = ts
        elif is_water and cur_start is not None:
            last_water_ts = ts
        elif (is_idle or phase == "drying") and cur_start is not None:
            # Cycle ends at the start of drying (no water from here)
            # or at any return-to-idle.
            assert last_water_ts is not None
            if ts - cur_start >= timedelta(minutes=MIN_CYCLE_MINUTES):
                cycles.append((cur_start, ts))
            cur_start = None
            last_water_ts = None

        last_known_phase = phase

    return cycles


def annotate_cycles_with_metadata(
    cycle_windows: list[tuple[datetime, datetime]],
    consumption_events: list[tuple[datetime, float]],
    program_events: list[tuple[datetime, str]],
) -> list[DishwasherCycle]:
    """For each cycle window, find peak water_consumption (cumulative,
    resets per cycle in Miele) and the program name in effect at start.
    """
    out: list[DishwasherCycle] = []
    for start, end in cycle_windows:
        # Peak consumption during the cycle window
        in_window = [v for (ts, v) in consumption_events if start <= ts <= end]
        peak = max(in_window) if in_window else None

        # Program in effect at cycle start = most recent program event at-or-before
        prog_before = [p for (ts, p) in program_events if ts <= start]
        program = prog_before[-1] if prog_before else None

        out.append(
            DishwasherCycle(
                start_ts=start,
                end_ts=end,
                program=program,
                gallons=peak,
            )
        )
    return out


def _fetch_sensor_events(
    ha_dsn: str,
    entity_id: str,
    since_local: datetime,
    until_local: datetime,
) -> list[tuple[datetime, str]]:
    since_utc = since_local.replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    until_utc = until_local.replace(tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    sql, params = sensor_states_sql(entity_id, since_utc, until_utc)
    with psycopg2.connect(ha_dsn) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()
    return [(_to_local_naive(datetime.fromtimestamp(float(ts), tz=timezone.utc)), s)
            for (ts, _ent, s) in rows]


def extract_cycles_from_ha(
    ha_dsn: str,
    since_local: datetime,
    until_local: datetime,
) -> list[DishwasherCycle]:
    """Query HA Postgres for the three relevant sensors and produce
    annotated DishwasherCycle list in [since_local, until_local).
    """
    phase_events = _fetch_sensor_events(
        ha_dsn, PHASE_ENTITY, since_local, until_local
    )
    cycle_windows = reconstruct_cycles(phase_events)

    # Parse numeric consumption events
    consumption_raw = _fetch_sensor_events(
        ha_dsn, CONSUMPTION_ENTITY, since_local, until_local
    )
    consumption: list[tuple[datetime, float]] = []
    for ts, s in consumption_raw:
        try:
            consumption.append((ts, float(s)))
        except (TypeError, ValueError):
            continue

    program_events = _fetch_sensor_events(
        ha_dsn, PROGRAM_ENTITY, since_local, until_local
    )
    # Filter out non-program strings (unavailable, unknown)
    programs = [(ts, p) for (ts, p) in program_events if p not in IDLE_PHASES
                and p not in {"unavailable", "unknown"}]

    return annotate_cycles_with_metadata(cycle_windows, consumption, programs)


UPSERT_CYCLE_SQL = """
INSERT INTO dishwasher_cycles (start_ts, end_ts, program, gallons)
VALUES (%s, %s, %s, %s)
ON CONFLICT (start_ts) DO UPDATE SET
    end_ts      = EXCLUDED.end_ts,
    program     = EXCLUDED.program,
    gallons     = EXCLUDED.gallons,
    detected_at = now();
"""


def persist_cycles(conn, cycles: Iterable[DishwasherCycle]) -> int:
    rows = [(c.start_ts, c.end_ts, c.program, c.gallons) for c in cycles]
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(UPSERT_CYCLE_SQL, rows)
    return len(rows)
