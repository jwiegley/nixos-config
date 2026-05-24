#!/usr/bin/env python3
"""Materialize flume_minute_attributions (long format) from
flume_segment_attributions × flume_minute_samples.

For each minute in the target window:
- If the minute's gpm is 0, emit zero attribution rows.
- If the minute falls inside a segment with N attributions, emit one
  row per attribution: (ts, fixture, gpm × probability).
- If the minute has flow but no enclosing segment, emit one row:
  (ts, 'unknown', gpm).

INVARIANT: SUM(attributions.gpm) == minute.gpm (within 0.05). The
script verifies this after each rebuild and fails loudly on violations.

Modes:
- `--full`: rebuild for every minute in flume_minute_samples
- `--days N` (default 4): rebuild the last N days
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


# Segments with classifier attributions: emit one row per (minute,
# fixture). The probability is constant across a segment, so per-minute
# gpm × probability = the share for that minute.
# Aggregate via SUM in case a minute is briefly inside an overlapping
# segment (shouldn't happen in practice; primary-key conflict if it does).
REFRESH_FROM_SEGMENTS = """
INSERT INTO flume_minute_attributions (ts, fixture, gpm, source, computed_at)
SELECT
    m.ts,
    a.fixture,
    SUM(a.probability * m.gpm) AS gpm,
    'v3' AS source,
    now()
FROM flume_minute_samples m
JOIN flume_segments s
  ON s.date = m.ts::date
 AND m.ts >= (s.date::timestamp + s.start_time)
 AND m.ts <= (s.date::timestamp + s.end_time)
JOIN flume_segment_attributions a
  ON a.segment_date = s.date
 AND a.segment_start = s.start_time
WHERE m.gpm > 0
  {date_filter}
GROUP BY m.ts, a.fixture
ON CONFLICT (ts, fixture) DO UPDATE SET
    gpm         = EXCLUDED.gpm,
    source      = EXCLUDED.source,
    computed_at = now()
"""

# Minutes with flow but no enclosing segment (sub-threshold flow that
# the segmenter skipped over). All of that minute's gpm → 'unknown'.
REFRESH_UNKNOWN_FOR_UNSEGMENTED = """
INSERT INTO flume_minute_attributions (ts, fixture, gpm, source, computed_at)
SELECT
    m.ts, 'unknown' AS fixture, m.gpm, 'v3' AS source, now()
FROM flume_minute_samples m
WHERE m.gpm > 0
  {date_filter}
  AND NOT EXISTS (
    SELECT 1 FROM flume_segments s
    WHERE s.date = m.ts::date
      AND m.ts >= (s.date::timestamp + s.start_time)
      AND m.ts <= (s.date::timestamp + s.end_time)
  )
ON CONFLICT (ts, fixture) DO UPDATE SET
    gpm         = EXCLUDED.gpm,
    source      = EXCLUDED.source,
    computed_at = now()
"""

# Verify the invariant: per-minute sum of attributions equals raw gpm.
# Returns rows where the difference exceeds the tolerance.
INVARIANT_CHECK = """
SELECT m.ts, m.gpm AS raw_gpm,
       COALESCE(SUM(a.gpm), 0) AS attr_sum,
       abs(m.gpm - COALESCE(SUM(a.gpm), 0)) AS diff
FROM flume_minute_samples m
LEFT JOIN flume_minute_attributions a ON a.ts = m.ts
WHERE m.gpm > 0
  {date_filter}
GROUP BY m.ts, m.gpm
HAVING abs(m.gpm - COALESCE(SUM(a.gpm), 0)) > 0.05
"""


def refresh(start_date: date | None, end_date: date | None) -> tuple[int, int]:
    """Refresh attributions for [start_date, end_date]. None bounds = all.
    Returns (rows_written, invariant_violations)."""
    if start_date and end_date:
        date_filter = "AND m.ts >= %s AND m.ts < %s"
        params = (start_date, end_date + timedelta(days=1))
    else:
        date_filter = ""
        params = ()

    with psycopg2.connect(**DB_CONNECT_KWARGS) as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_DDL)
        conn.commit()

        with conn.cursor() as cur:
            # First, delete existing rows in the target window so the
            # rebuild is a true replacement (otherwise stale rows from
            # an old classifier run linger and break the invariant).
            if start_date and end_date:
                cur.execute(
                    "DELETE FROM flume_minute_attributions "
                    "WHERE ts >= %s AND ts < %s",
                    (start_date, end_date + timedelta(days=1)),
                )
            else:
                cur.execute("TRUNCATE flume_minute_attributions")

            cur.execute(REFRESH_FROM_SEGMENTS.format(date_filter=date_filter), params)
            n_from_segs = cur.rowcount
            cur.execute(REFRESH_UNKNOWN_FOR_UNSEGMENTED.format(date_filter=date_filter), params)
            n_unknown = cur.rowcount

        conn.commit()

        # Invariant check
        with conn.cursor() as cur:
            cur.execute(INVARIANT_CHECK.format(date_filter=date_filter), params)
            violations = cur.fetchall()

    return (n_from_segs + n_unknown, len(violations))


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
        help="Rebuild for every minute in flume_minute_samples",
    )
    args = parser.parse_args()

    if args.full:
        start, end = None, None
        print("--full: rebuilding flume_minute_attributions across all history")
    else:
        end = date.today()
        start = end - timedelta(days=args.days)
        print(f"--days {args.days}: refreshing {start} .. {end}")

    rows, violations = refresh(start, end)
    print(f"  wrote {rows} attribution rows")
    if violations:
        print(f"  INVARIANT VIOLATIONS: {violations} minutes where sum != raw")
        print("  (see scripts/flume-data/INVARIANT_CHECK SQL for details)")
        return 1
    print("  invariant check: OK (all per-minute sums match raw within 0.05 GPM)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
