#!/usr/bin/env python3
"""One-shot: populate `irrigation_sessions` for all dates HA retention
covers, then compute `category_v2` for every row in `flume_segments`.

Run as the `flume-data` system user (peer auth to both Postgres
databases).

Idempotent: subsequent runs UPSERT and UPDATE in place, so it's safe to
re-run after tweaking thresholds in flume_data/classify_v2.py.
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from flume_data.classify_v2 import classify_segment  # noqa: E402
from flume_data.irrigation_sessions import (  # noqa: E402
    HA_RECORDER_RETENTION_DAYS,
    extract_sessions_from_ha,
    have_valve_data_for_date,
    persist_sessions,
    sessions_for_date,
)
from flume_db_sync import (  # noqa: E402
    DB_CONNECT_KWARGS,
    HA_POSTGRES_DSN,
    SCHEMA_DDL,
)


def populate_irrigation_sessions(conn) -> int:
    """Pull all valve events HA still has and merge into sessions.
    Returns row count UPSERTed."""
    # HA retention is ~30d on this host; query a generous window so we
    # capture the boundary. extract_sessions_from_ha drops events
    # outside the window naturally.
    until = datetime.now() + timedelta(days=1)
    since = datetime.now() - timedelta(days=HA_RECORDER_RETENTION_DAYS + 5)
    sessions = extract_sessions_from_ha(HA_POSTGRES_DSN, since, until)
    return persist_sessions(conn, sessions)


def fetch_all_segments(conn) -> list[dict]:
    """Read flume_segments + per-minute mean for v2 classification."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT date, start_time, end_time, mean_gpm
              FROM flume_segments
             ORDER BY date, start_time
            """
        )
        rows = cur.fetchall()
    return [
        {
            "date": d,
            "start_time": st,
            "end_time": et,
            "mean_gpm": float(mg),
        }
        for (d, st, et, mg) in rows
    ]


def fetch_minute_samples_for(conn, d: date) -> dict[datetime, float]:
    """Per-minute gpm for the given local date, keyed by ts."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT ts, gpm
              FROM flume_minute_samples
             WHERE ts >= %s AND ts < %s
            """,
            (
                datetime.combine(d, datetime.min.time()),
                datetime.combine(d + timedelta(days=1), datetime.min.time()),
            ),
        )
        return {ts: float(gpm) for (ts, gpm) in cur.fetchall()}


def gpms_for_segment(
    samples_by_ts: dict[datetime, float],
    seg_date: date,
    start_t,
    end_t,
) -> list[float]:
    start_dt = datetime.combine(seg_date, start_t)
    end_dt = datetime.combine(seg_date, end_t)
    out: list[float] = []
    cur = start_dt
    while cur <= end_dt:
        if cur in samples_by_ts:
            out.append(samples_by_ts[cur])
        cur += timedelta(minutes=1)
    return out


def backfill(verbose: bool = False) -> tuple[int, dict[str, int]]:
    """Update category_v2 for every flume_segments row. Returns
    (segments_updated, category_counter)."""
    with psycopg2.connect(**DB_CONNECT_KWARGS) as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_DDL)
        conn.commit()

        sessions_upserted = populate_irrigation_sessions(conn)
        conn.commit()
        print(f"populated {sessions_upserted} irrigation sessions from HA")

        segments = fetch_all_segments(conn)
        print(f"classifying {len(segments):,} segments")

        # Iterate by date so we only pull each day's per-minute samples
        # once. Tens of thousands of dates would be slow, but 800 days
        # is fine — each pull is ~1440 rows.
        by_date: dict[date, list[dict]] = {}
        for seg in segments:
            by_date.setdefault(seg["date"], []).append(seg)

        now_ts = datetime.now()
        updates: list[tuple] = []
        cat_counter: Counter = Counter()
        for d in sorted(by_date):
            samples = fetch_minute_samples_for(conn, d)
            irr = sessions_for_date(conn, d)
            valve_data = have_valve_data_for_date(conn, d)
            for seg in by_date[d]:
                gpms = gpms_for_segment(
                    samples, d, seg["start_time"], seg["end_time"]
                )
                v2 = classify_segment(
                    seg_date=d,
                    seg_start_time=seg["start_time"],
                    seg_end_time=seg["end_time"],
                    mean_gpm=seg["mean_gpm"],
                    per_minute_gpm=gpms,
                    irrigation_sessions=irr,
                    have_valve_data=valve_data,
                )
                cat_counter[v2.category] += 1
                updates.append(
                    (v2.category, v2.reason, now_ts, d, seg["start_time"])
                )
            if verbose:
                print(
                    f"  {d}: {len(by_date[d])} segments "
                    f"(valve_data={valve_data}, sessions={len(irr)})"
                )

        # Batched UPDATE. execute_values + a VALUES join is the fastest
        # pattern for psycopg2; one round trip for the whole table.
        with conn.cursor() as cur:
            execute_values(
                cur,
                """
                UPDATE flume_segments AS f SET
                    category_v2             = v.cat,
                    category_v2_reason      = v.reason,
                    category_v2_computed_at = v.ts
                FROM (VALUES %s) AS v (cat, reason, ts, dt, st)
                WHERE f.date = v.dt AND f.start_time = v.st
                """,
                updates,
                template="(%s, %s, %s, %s, %s)",
                page_size=2000,
            )
        conn.commit()

        return (len(updates), dict(cat_counter))


def print_before_after(conn) -> None:
    """Compare v1 vs v2 distribution side by side."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                category                                  AS v1_cat,
                COALESCE(category_v2, '(unclassified)')   AS v2_cat,
                COUNT(*)                                  AS n,
                ROUND(SUM(gallons)::numeric, 0)           AS gal
              FROM flume_segments
             GROUP BY 1, 2
             ORDER BY 1, 2
            """
        )
        rows = cur.fetchall()
    print("\n=== v1 → v2 transition matrix ===")
    print(f"{'v1':<16} {'v2':<20} {'segments':>10} {'gallons':>10}")
    print("-" * 60)
    for v1, v2, n, g in rows:
        print(f"{v1:<16} {v2:<20} {n:>10,} {g or 0:>10,}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument(
        "--summary-only",
        action="store_true",
        help="Skip backfill, just print before/after matrix",
    )
    args = parser.parse_args()

    if not args.summary_only:
        updated, cats = backfill(verbose=args.verbose)
        print(f"\nbackfill complete: {updated:,} segments updated")
        for cat, n in sorted(cats.items(), key=lambda kv: -kv[1]):
            print(f"  {cat:<20} {n:>10,}")

    with psycopg2.connect(**DB_CONNECT_KWARGS) as conn:
        print_before_after(conn)
    return 0


if __name__ == "__main__":
    sys.exit(main())
