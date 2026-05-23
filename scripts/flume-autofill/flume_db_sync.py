#!/usr/bin/env python3
"""Sync Flume per-segment data into PostgreSQL `flume_history.flume_segments`.

Two modes:

* `--days N` (default 3) — sync the last N days. The default 3 handles
  late-arriving data + intraday corrections without re-fetching the
  whole history. Wired to the 6-hourly systemd timer.

* `--from-cache` — replay every cached day in
  /var/lib/flume-autofill/cache/per-minute-by-day into Postgres. Used
  once after the initial historical pull completes.

Both modes are idempotent: INSERT … ON CONFLICT (date, start_time) DO
UPDATE keeps the table in sync with the latest cache contents.

Schema is created in-place on first run (CREATE TABLE IF NOT EXISTS),
so deployment doesn't need a separate migration step.

Run as the `flume-autofill` system user (peer-auth to Postgres).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import psycopg2

# Re-use the canonical detection from emit_segments_csv.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from emit_segments_csv import (  # noqa: E402
    CACHE_DIR,
    chunked_pull,
    detect_segments,
    is_pool_autofill_segment,
    list_devices,
    load_credentials,
    mint_token,
    RateLimiter,
    segment_to_local,
)

# The db, postgres role, and OS user are all named `flume-autofill` so
# the ensureDBOwnership assertion + peer-auth ident mapping align on a
# single string. psycopg2 needs explicit user= (it can't reliably derive
# from the OS identity inside the systemd sandbox) AND kwargs rather than
# a DSN string (the hyphen confuses libpq's DSN-string quote handling —
# embedded "..." gets treated as part of the value).
DB_CONNECT_KWARGS: dict[str, str] = {
    "dbname": "flume-autofill",
    "user": "flume-autofill",
}

SCHEMA_DDL = """
-- Raw per-minute Flume samples — the authoritative ground truth. Every
-- sample Flume's API returned, including zero-GPM idle minutes.
-- Naive timestamps in device-local TZ (America/Los_Angeles) to match
-- what Flume returns from its query API.
CREATE TABLE IF NOT EXISTS flume_minute_samples (
    ts   TIMESTAMP    NOT NULL,
    gpm  NUMERIC(8,3) NOT NULL,
    PRIMARY KEY (ts)
);
CREATE INDEX IF NOT EXISTS flume_minute_samples_date
    ON flume_minute_samples ((ts::date));

-- Pre-computed segments — derived from flume_minute_samples but cached
-- here for fast Grafana/dashboard queries. You can compute alternative
-- aggregations from flume_minute_samples directly without touching this
-- table. Detection rule lives in flume_autofill/detection.py.
CREATE TABLE IF NOT EXISTS flume_segments (
    date                  DATE          NOT NULL,
    start_time            TIME          NOT NULL,
    end_time              TIME          NOT NULL,
    duration_min          INT           NOT NULL,
    gallons               NUMERIC(10,3) NOT NULL,
    mean_gpm              NUMERIC(8,3)  NOT NULL,
    peak_gpm              NUMERIC(8,3)  NOT NULL,
    category              TEXT          NOT NULL
        CHECK (category IN ('pool_autofill','other')),
    autofill_session_id   INT,
    source                TEXT          NOT NULL DEFAULT 'flume_api',
    detected_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (date, start_time)
);
CREATE INDEX IF NOT EXISTS flume_segments_category_date
    ON flume_segments(category, date);
CREATE INDEX IF NOT EXISTS flume_segments_autofill
    ON flume_segments(date)
    WHERE category = 'pool_autofill';

-- Convenience view: per-day rollups from the derived segments table.
-- (For per-day rollups computed directly from flume_minute_samples, see
-- the README — single SQL query.)
CREATE OR REPLACE VIEW flume_day_totals AS
SELECT date,
       SUM(gallons)                                        AS total_gallons,
       SUM(gallons) FILTER (WHERE category='pool_autofill') AS pool_autofill_gallons,
       SUM(gallons) FILTER (WHERE category='other')         AS other_gallons,
       COUNT(*)     FILTER (WHERE category='pool_autofill') AS pool_autofill_sessions
FROM flume_segments
GROUP BY date;
"""

UPSERT_SAMPLE_SQL = """
INSERT INTO flume_minute_samples (ts, gpm)
VALUES (%s, %s)
ON CONFLICT (ts) DO UPDATE SET gpm = EXCLUDED.gpm;
"""

UPSERT_SQL = """
INSERT INTO flume_segments
       (date, start_time, end_time, duration_min, gallons, mean_gpm,
        peak_gpm, category, autofill_session_id)
VALUES (%s,   %s,         %s,       %s,           %s,      %s,
        %s,       %s,       %s)
ON CONFLICT (date, start_time) DO UPDATE SET
    end_time            = EXCLUDED.end_time,
    duration_min        = EXCLUDED.duration_min,
    gallons             = EXCLUDED.gallons,
    mean_gpm            = EXCLUDED.mean_gpm,
    peak_gpm            = EXCLUDED.peak_gpm,
    category            = EXCLUDED.category,
    autofill_session_id = EXCLUDED.autofill_session_id,
    detected_at         = now();
"""


def load_cached_samples(target_dates: list[date]) -> list[tuple[datetime, float]]:
    """Read cache files for the given dates and return concatenated samples."""
    out: list[tuple[datetime, float]] = []
    for d in sorted(target_dates):
        path = CACHE_DIR / f"{d.isoformat()}.json"
        if not path.exists():
            continue
        for entry in json.loads(path.read_text()):
            out.append((datetime.fromisoformat(entry[0]), float(entry[1])))
    return out


def ensure_cache_for(
    start_date: date,
    end_date: date,
    token: str,
    user_id: int,
    device_id: str,
) -> None:
    """Pull missing days into the cache via Flume API (rate-limited)."""
    rate = RateLimiter()
    start_dt = datetime(start_date.year, start_date.month, start_date.day)
    end_dt = datetime(end_date.year, end_date.month, end_date.day) + timedelta(days=1)
    # chunked_pull yields samples; we don't need them here (the cache file is
    # written as a side effect), but iterating is required.
    for _ in chunked_pull(token, user_id, device_id, start_dt, end_dt, rate):
        pass


def sync_dates_to_db(target_dates: list[date]) -> tuple[int, int]:
    """UPSERT BOTH raw per-minute samples AND derived segments for the
    given local dates. Returns (samples_written, segments_written).
    """
    if not target_dates:
        return (0, 0)

    samples = load_cached_samples(target_dates)
    if not samples:
        print(f"no cached samples for {target_dates[0]}..{target_dates[-1]} — skipping")
        return (0, 0)

    target_set = set(target_dates)

    # 1) Raw per-minute samples — every cached point whose local date is
    # in the target set. This is the authoritative ground truth for any
    # downstream re-aggregation the user wants to do in SQL.
    sample_rows = [(ts, gpm) for ts, gpm in samples if ts.date() in target_set]

    # 2) Derived segments — precomputed for fast dashboard queries.
    segments = detect_segments(samples)
    segment_rows: list[tuple] = []
    autofill_session_by_date: dict[date, int] = defaultdict(int)
    for start_i, end_i in segments:
        span = samples[start_i : end_i + 1]
        gpms = [g for _, g in span]
        gallons = round(sum(gpms), 3)
        mean_gpm = round(gallons / len(span), 3)
        peak_gpm = round(max(gpms), 3)
        duration = len(span)
        start_local = segment_to_local(span[0][0])
        end_local = segment_to_local(span[-1][0])
        d = start_local.date()
        if d not in target_set:
            continue
        is_autofill = is_pool_autofill_segment(samples, start_i, end_i)
        session_id: int | None = None
        category = "other"
        if is_autofill:
            autofill_session_by_date[d] += 1
            session_id = autofill_session_by_date[d]
            category = "pool_autofill"
        segment_rows.append(
            (d, start_local.time(), end_local.time(), duration, gallons,
             mean_gpm, peak_gpm, category, session_id)
        )

    with psycopg2.connect(**DB_CONNECT_KWARGS) as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_DDL)
            if sample_rows:
                # executemany on 1.2M rows scales fine but takes a few
                # seconds; large batches are fine for psycopg2's prepared
                # path. Use mogrify-based bulk insert for the bulk-load
                # case (--from-cache) — 100x faster than executemany.
                if len(sample_rows) > 10_000:
                    from psycopg2.extras import execute_values
                    execute_values(
                        cur,
                        "INSERT INTO flume_minute_samples (ts, gpm) VALUES %s "
                        "ON CONFLICT (ts) DO UPDATE SET gpm = EXCLUDED.gpm",
                        sample_rows,
                        page_size=5000,
                    )
                else:
                    cur.executemany(UPSERT_SAMPLE_SQL, sample_rows)
            if segment_rows:
                cur.executemany(UPSERT_SQL, segment_rows)
        conn.commit()
    return (len(sample_rows), len(segment_rows))


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--days",
        type=int,
        default=3,
        help="Sync the last N days (default 3, used by the timer)",
    )
    group.add_argument(
        "--from-cache",
        action="store_true",
        help="Replay every cached day into Postgres (one-shot bulk load)",
    )
    args = parser.parse_args()

    target: list[date] = []
    if args.from_cache:
        cache_files = sorted(CACHE_DIR.glob("*.json"))
        target = [date.fromisoformat(p.stem) for p in cache_files]
        print(f"--from-cache: {len(target)} cached days available")
    else:
        # Last N days, but pull missing data from the API first.
        today = date.today()
        target = [today - timedelta(days=i) for i in range(args.days, 0, -1)]
        print(f"--days {args.days}: syncing {target[0]} .. {target[-1]}")

        # Ensure all target days are in cache (no-ops for cache hits)
        missing = [d for d in target if not (CACHE_DIR / f"{d.isoformat()}.json").exists()]
        if missing:
            print(f"  {len(missing)} missing days; pulling from API")
            creds = load_credentials()
            token, user_id = mint_token(creds)
            devices = list_devices(token, user_id)
            sensor = next((d for d in devices if d.get("type") == 2), devices[0])
            ensure_cache_for(missing[0], missing[-1], token, user_id, sensor["id"])

    samples_written, segments_written = sync_dates_to_db(target)
    print(f"  UPSERTed {samples_written} minute samples + {segments_written} segment rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
