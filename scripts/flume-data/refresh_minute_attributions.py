#!/usr/bin/env python3
"""Materialize flume_minute_attributions from per-segment attributions.

The per-minute table is denormalized for fast dashboard queries — each
minute's total_gpm gets distributed across fixture columns proportional
to the containing segment's flume_segment_attributions probabilities.

Modes:
- `--full`: rebuild for every minute in flume_minute_samples
- `--days N` (default 4): rebuild the last N days

After each run, every minute in the target window satisfies the
invariant: sum(all *_gpm columns) ≈ total_gpm.
"""
from __future__ import annotations

import argparse
import sys
from datetime import date, timedelta
from pathlib import Path

import psycopg2

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from flume_db_sync import DB_CONNECT_KWARGS, SCHEMA_DDL  # noqa: E402


# The CASE list mirrors flume_minute_attributions columns. Centralizing
# it here means adding a new fixture only requires editing this list
# (plus the schema and the fixture library).
FIXTURE_COLUMNS = [
    "irrigation_spray",
    "irrigation_drip",
    "irrigation_bubbler",
    "pool_autofill",
    "dishwasher",
    "shower",
    "sink_hot",
    "clothes_washer_hot",
    "clothes_washer_cold",
    "toilet_flush",
    "sink_cold",
    "fridge_event",
    "leak",
    "unknown",
]


def _refresh_sql(where_clause: str) -> str:
    """Build the INSERT … SELECT for refreshing per-minute attributions.

    Joins flume_minute_samples → flume_segments → flume_segment_attributions
    and pivots fixture probabilities into columns via SUM(CASE …).
    """
    case_cols = ",\n  ".join(
        f"COALESCE(SUM(CASE WHEN a.fixture = '{f}' "
        f"THEN a.probability * m.gpm ELSE 0 END), 0) AS {f}_gpm"
        for f in FIXTURE_COLUMNS
        if f != "unknown"
    )
    # 'unknown' has two sources: (a) the classifier emitted 'unknown' for
    # a segment, and (b) the minute has flow but no segment matched
    # (sub-threshold flow that the segmenter ignored). Both flow into the
    # same column.
    unknown_col = (
        "COALESCE(SUM(CASE WHEN a.fixture = 'unknown' "
        "THEN a.probability * m.gpm ELSE 0 END), 0) "
        # If the segment didn't even exist (m matched no segment), all
        # of m.gpm is unattributed → treat as unknown. The CASE on
        # s.date IS NULL handles this.
        "+ COALESCE(MAX(CASE WHEN s.date IS NULL THEN m.gpm ELSE 0 END), 0) "
        "AS unknown_gpm"
    )

    return f"""
        INSERT INTO flume_minute_attributions (
            ts, total_gpm,
            {", ".join(f + "_gpm" for f in FIXTURE_COLUMNS)},
            computed_at
        )
        SELECT
            m.ts,
            m.gpm AS total_gpm,
            {case_cols},
            {unknown_col},
            now() AS computed_at
        FROM flume_minute_samples m
        LEFT JOIN flume_segments s
          ON s.date = m.ts::date
         AND m.ts >= (s.date::timestamp + s.start_time)
         AND m.ts <= (s.date::timestamp + s.end_time)
        LEFT JOIN flume_segment_attributions a
          ON a.segment_date = s.date
         AND a.segment_start = s.start_time
        WHERE {where_clause}
        GROUP BY m.ts, m.gpm
        ON CONFLICT (ts) DO UPDATE SET
            total_gpm               = EXCLUDED.total_gpm,
            irrigation_spray_gpm    = EXCLUDED.irrigation_spray_gpm,
            irrigation_drip_gpm     = EXCLUDED.irrigation_drip_gpm,
            irrigation_bubbler_gpm  = EXCLUDED.irrigation_bubbler_gpm,
            pool_autofill_gpm       = EXCLUDED.pool_autofill_gpm,
            dishwasher_gpm          = EXCLUDED.dishwasher_gpm,
            shower_gpm              = EXCLUDED.shower_gpm,
            sink_hot_gpm            = EXCLUDED.sink_hot_gpm,
            clothes_washer_hot_gpm  = EXCLUDED.clothes_washer_hot_gpm,
            clothes_washer_cold_gpm = EXCLUDED.clothes_washer_cold_gpm,
            toilet_flush_gpm        = EXCLUDED.toilet_flush_gpm,
            sink_cold_gpm           = EXCLUDED.sink_cold_gpm,
            fridge_event_gpm        = EXCLUDED.fridge_event_gpm,
            leak_gpm                = EXCLUDED.leak_gpm,
            unknown_gpm             = EXCLUDED.unknown_gpm,
            computed_at             = now()
    """


def refresh(start_date: date | None, end_date: date | None) -> int:
    """Refresh attributions for [start_date, end_date]. None bounds = all time."""
    with psycopg2.connect(**DB_CONNECT_KWARGS) as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_DDL)
        conn.commit()

        if start_date and end_date:
            sql = _refresh_sql("m.ts >= %s AND m.ts < %s")
            params = (
                start_date,
                end_date + timedelta(days=1),
            )
        else:
            sql = _refresh_sql("TRUE")
            params = ()

        with conn.cursor() as cur:
            cur.execute(sql, params)
            n = cur.rowcount
        conn.commit()
    return n


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--days",
        type=int,
        default=4,
        help="Refresh the last N days (default 4, used by the timer)",
    )
    group.add_argument(
        "--full",
        action="store_true",
        help="Refresh all minutes (1.2M rows; one-shot bulk)",
    )
    args = parser.parse_args()

    if args.full:
        start, end = None, None
        print("--full: rebuilding flume_minute_attributions across all history")
    else:
        end = date.today()
        start = end - timedelta(days=args.days)
        print(f"--days {args.days}: refreshing {start} .. {end}")

    n = refresh(start, end)
    print(f"  upserted {n} minute attribution rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
