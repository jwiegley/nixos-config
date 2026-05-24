#!/usr/bin/env python3
"""One-shot: compute flume_segment_attributions for every row in
flume_segments using the v3 probabilistic classifier.

Uses ground-truth context where available:
- B-Hyve irrigation sessions (post-2026-04-23)
- Dishwasher cycles (post-2026-04-23)
- Tankless hot-water flow (post-2026-05-20)
- User labels (whenever present — override classifier entirely)

For older dates lacking ground truth, the classifier degrades to
shape-only matching and many segments will land in `unknown`.
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

from flume_data.classify_v3 import SegmentContext, classify  # noqa: E402
from flume_db_sync import DB_CONNECT_KWARGS, SCHEMA_DDL  # noqa: E402


# Zone slug → type mapping (kept in sync with zones.json via the NixOS
# module). Could be loaded from zones.json instead.
ZONE_TYPE: dict[str, str | None] = {
    "front_yard": "spray",
    "side_yard_right": "spray",
    "back_wall": "spray",
    "around_dining_set": "spray",
    "along_driveway": "spray",
    "back_of_house_and_side_yard_left": "spray",
    "drip_front_left": "drip",
    "drip_front_right": "drip",
    "planter_box": "drip",
    "zone_5": None,  # unknown
}


def fetch_all_segments(conn) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT date, start_time, end_time, duration_min, mean_gpm,
                   peak_gpm, gallons, category_v2
            FROM flume_segments
            ORDER BY date, start_time
            """
        )
        rows = cur.fetchall()
    return [
        {
            "date": d, "start_time": st, "end_time": et,
            "duration_min": int(dm), "mean_gpm": float(mg),
            "peak_gpm": float(pg), "gallons": float(gal),
            "category_v2": cat,
        }
        for (d, st, et, dm, mg, pg, gal, cat) in rows
    ]


def fetch_user_labels(conn) -> dict[tuple[date, object], str]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT segment_date, segment_start, user_fixture FROM flume_user_labels"
        )
        return {(d, st): f for (d, st, f) in cur.fetchall()}


def fetch_irrigation_for_date(conn, d: date) -> list[tuple[datetime, datetime, str]]:
    """Return (start_ts, end_ts, zones_csv) for sessions touching `d`."""
    day_start = datetime.combine(d, datetime.min.time())
    day_end = day_start + timedelta(days=1)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT start_ts, end_ts, zones FROM irrigation_sessions
             WHERE start_ts < %s AND end_ts > %s
            """,
            (day_end, day_start),
        )
        return list(cur.fetchall())


def fetch_dishwasher_for_date(conn, d: date) -> list[tuple[datetime, datetime]]:
    day_start = datetime.combine(d, datetime.min.time())
    day_end = day_start + timedelta(days=1)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT start_ts, end_ts FROM dishwasher_cycles
             WHERE start_ts < %s AND end_ts > %s
            """,
            (day_end, day_start),
        )
        return list(cur.fetchall())


def fetch_hot_for_date(conn, d: date) -> dict[datetime, float]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT ts, gpm FROM tankless_minute_samples
             WHERE ts >= %s AND ts < %s
            """,
            (
                datetime.combine(d, datetime.min.time()),
                datetime.combine(d + timedelta(days=1), datetime.min.time()),
            ),
        )
        return {ts: float(gpm) for (ts, gpm) in cur.fetchall()}


def build_context(
    seg: dict,
    irrigation: list[tuple[datetime, datetime, str]],
    dishwasher: list[tuple[datetime, datetime]],
    hot_samples: dict[datetime, float],
) -> SegmentContext:
    seg_start = datetime.combine(seg["date"], seg["start_time"])
    seg_end = datetime.combine(seg["date"], seg["end_time"]) + timedelta(minutes=1)

    # B-Hyve overlap + zone type
    bhyve_overlaps = False
    bhyve_zone_type: str | None = None
    for s, e, zones in irrigation:
        if seg_start < e and seg_end > s:
            bhyve_overlaps = True
            # Pick the first zone's type (often single-zone segments)
            first_zone = zones.split(",")[0].strip()
            bhyve_zone_type = ZONE_TYPE.get(first_zone)
            break

    # Dishwasher overlap
    dishwasher_overlaps = any(
        seg_start < e and seg_end > s for (s, e) in dishwasher
    )

    # Sum hot gpm over segment minutes (each is gal/min for 1 min = gallons)
    hot_gal = 0.0
    cur = seg_start
    while cur < seg_end:
        if cur in hot_samples:
            hot_gal += hot_samples[cur]
        cur += timedelta(minutes=1)

    return SegmentContext(
        mean_gpm=seg["mean_gpm"],
        duration_min=float(seg["duration_min"]),
        gallons=seg["gallons"],
        peak_gpm=seg["peak_gpm"],
        hot_gallons=hot_gal,
        bhyve_overlaps=bhyve_overlaps,
        bhyve_zone_type=bhyve_zone_type,
        dishwasher_overlaps=dishwasher_overlaps,
        v2_category=seg.get("category_v2"),
    )


def backfill(
    verbose: bool = False,
    days: int | None = None,
) -> dict[str, int]:
    """Re-attribute segments. days=None means all history; days=N means
    only segments whose date is within the last N days (incremental sync)."""
    with psycopg2.connect(**DB_CONNECT_KWARGS) as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_DDL)
        conn.commit()

        segments = fetch_all_segments(conn)
        if days is not None:
            cutoff = date.today() - timedelta(days=days)
            segments = [s for s in segments if s["date"] >= cutoff]
        labels = fetch_user_labels(conn)
        print(f"classifying {len(segments):,} segments "
              f"(of which {len(labels)} have user labels)")

        # Bucket by date so we fetch context once per day.
        by_date: dict[date, list[dict]] = {}
        for seg in segments:
            by_date.setdefault(seg["date"], []).append(seg)

        all_rows: list[tuple] = []
        fixture_counter: Counter = Counter()
        now_ts = datetime.now()

        for d in sorted(by_date):
            irrigation = fetch_irrigation_for_date(conn, d)
            dishwasher = fetch_dishwasher_for_date(conn, d)
            hot_samples = fetch_hot_for_date(conn, d)
            for seg in by_date[d]:
                key = (seg["date"], seg["start_time"])
                if key in labels:
                    # User override: single attribution at 100%
                    all_rows.append((
                        seg["date"], seg["start_time"], labels[key],
                        1.000, round(seg["gallons"], 3), "user", now_ts,
                    ))
                    fixture_counter[labels[key]] += 1
                    continue
                ctx = build_context(seg, irrigation, dishwasher, hot_samples)
                attrs = classify(ctx)
                for a in attrs:
                    all_rows.append((
                        seg["date"], seg["start_time"], a.fixture,
                        a.probability, a.gallons, "v3", now_ts,
                    ))
                # Track the top fixture per segment for the summary
                fixture_counter[attrs[0].fixture] += 1
            if verbose:
                print(f"  {d}: {len(by_date[d])} segments")

        # Targeted replacement: delete attributions for the affected
        # segments only, then re-insert. Avoids TRUNCATE on incremental
        # runs which would drop the rest of the history.
        affected_keys = sorted({(s["date"], s["start_time"]) for s in segments})
        with conn.cursor() as cur:
            if days is None:
                cur.execute("TRUNCATE flume_segment_attributions")
            else:
                execute_values(
                    cur,
                    "DELETE FROM flume_segment_attributions WHERE "
                    "(segment_date, segment_start) IN (VALUES %s)",
                    affected_keys,
                    page_size=5000,
                )
            execute_values(
                cur,
                """
                INSERT INTO flume_segment_attributions
                  (segment_date, segment_start, fixture, probability,
                   gallons, classifier, computed_at)
                VALUES %s
                """,
                all_rows,
                page_size=5000,
            )
        conn.commit()
        return dict(fixture_counter)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument(
        "--days",
        type=int,
        default=None,
        help="Re-attribute only segments in the last N days (default: all)",
    )
    args = parser.parse_args()
    counter = backfill(verbose=args.verbose, days=args.days)
    print("\nTop-fixture distribution (segments classified, not gallons):")
    for fix, n in sorted(counter.items(), key=lambda kv: -kv[1]):
        print(f"  {fix:<22} {n:>10,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
