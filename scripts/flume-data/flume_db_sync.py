#!/usr/bin/env python3
"""Sync Flume per-segment data into PostgreSQL `flume_history.flume_segments`.

Two modes:

* `--days N` (default 3) — sync the last N days. The default 3 handles
  late-arriving data + intraday corrections without re-fetching the
  whole history. Wired to the 6-hourly systemd timer.

* `--from-cache` — replay every cached day in
  /var/lib/flume-data/cache/per-minute-by-day into Postgres. Used
  once after the initial historical pull completes.

Both modes are idempotent: INSERT … ON CONFLICT (date, start_time) DO
UPDATE keeps the table in sync with the latest cache contents.

Schema is created in-place on first run (CREATE TABLE IF NOT EXISTS),
so deployment doesn't need a separate migration step.

Run as the `flume-data` system user (peer-auth to Postgres).
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
from flume_data.classify_v2 import classify_segment  # noqa: E402
from flume_data.irrigation_sessions import (  # noqa: E402
    HA_RECORDER_RETENTION_DAYS,
    extract_sessions_from_ha,
    persist_sessions,
)
from flume_data.tankless import sync_range_from_ha as tankless_sync  # noqa: E402
from flume_data.dishwasher import (  # noqa: E402
    extract_cycles_from_ha as dishwasher_extract,
    persist_cycles as dishwasher_persist,
)

# The db, postgres role, and OS user are all named `flume-data` so
# the ensureDBOwnership assertion + peer-auth ident mapping align on a
# single string. psycopg2 needs explicit user= (it can't reliably derive
# from the OS identity inside the systemd sandbox) AND kwargs rather than
# a DSN string (the hyphen confuses libpq's DSN-string quote handling —
# embedded "..." gets treated as part of the value).
DB_CONNECT_KWARGS: dict[str, str] = {
    "dbname": "flume-data",
    "user": "flume-data",
}

# HA Postgres DSN — peer auth via Unix socket, no password. Granted in
# modules/services/databases.nix (pg_hba `local hass flume-data peer`
# + SELECT on states / states_meta).
HA_POSTGRES_DSN = "postgresql:///hass"

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
-- table. Detection rule lives in flume_data/detection.py.
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

-- v2 classification (B-Hyve-aware). category stays untouched as the v1
-- historical label; category_v2 is the corrected label that incorporates
-- HA's valve.sprinkler_control_*_zone events. NULL category_v2 means
-- "not yet classified" — backfill_v2.py populates it for all rows.
ALTER TABLE flume_segments
    ADD COLUMN IF NOT EXISTS category_v2             TEXT;
ALTER TABLE flume_segments
    ADD COLUMN IF NOT EXISTS category_v2_reason      TEXT;
ALTER TABLE flume_segments
    ADD COLUMN IF NOT EXISTS category_v2_computed_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS flume_segments_category_v2_date
    ON flume_segments(category_v2, date);

-- Per-minute hot-water flow from the tankless heater (Navien NaviLink).
-- Source data is event-driven (HA reports on each state change), but
-- this table is per-minute interpolated (forward-fill the last known
-- value) so it can be joined directly with flume_minute_samples on ts.
-- Used by the v3 fixture classifier to discriminate shower / dishwasher
-- / washer-hot from cold-only fixtures (toilet / irrigation / pool).
CREATE TABLE IF NOT EXISTS tankless_minute_samples (
    ts   TIMESTAMP    NOT NULL,  -- naive local (America/Los_Angeles)
    gpm  NUMERIC(8,3) NOT NULL,
    PRIMARY KEY (ts)
);
CREATE INDEX IF NOT EXISTS tankless_minute_samples_date
    ON tankless_minute_samples ((ts::date));

-- Miele dishwasher cycle windows. Source = HA `sensor.dishwasher_program_phase`
-- state transitions; gallons = peak `sensor.dishwasher_water_consumption`
-- during the cycle. Used by the v3 classifier to attribute flow during
-- a dishwasher cycle with high confidence (third ground-truth source
-- alongside B-Hyve and the tankless heater).
CREATE TABLE IF NOT EXISTS dishwasher_cycles (
    cycle_id    SERIAL    PRIMARY KEY,
    start_ts    TIMESTAMP NOT NULL UNIQUE,  -- local naive
    end_ts      TIMESTAMP NOT NULL,
    program     TEXT,
    gallons     NUMERIC(6,3),
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dishwasher_cycles_range
    ON dishwasher_cycles (start_ts, end_ts);

-- v3 per-segment fixture attributions: probabilistic, one row per
-- (fixture, segment). Probabilities sum to 1.0 across all rows for a
-- given segment; gallons sums to flume_segments.gallons (within
-- rounding). User overrides via flume_user_labels collapse to one row
-- with probability=1.0.
CREATE TABLE IF NOT EXISTS flume_segment_attributions (
    segment_date  DATE          NOT NULL,
    segment_start TIME          NOT NULL,
    fixture       TEXT          NOT NULL,
    probability   NUMERIC(4,3)  NOT NULL CHECK (probability BETWEEN 0 AND 1),
    gallons       NUMERIC(10,3) NOT NULL,
    classifier    TEXT          NOT NULL DEFAULT 'v3',
    computed_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (segment_date, segment_start, fixture)
);
CREATE INDEX IF NOT EXISTS flume_segment_attributions_fixture_date
    ON flume_segment_attributions (fixture, segment_date);

-- User-provided ground-truth labels. When a row exists, the classifier
-- replaces its computed attributions with a single (user_fixture, 1.0).
CREATE TABLE IF NOT EXISTS flume_user_labels (
    label_id      SERIAL      PRIMARY KEY,
    segment_date  DATE        NOT NULL,
    segment_start TIME        NOT NULL,
    user_fixture  TEXT        NOT NULL,
    confidence    TEXT        NOT NULL DEFAULT 'certain'
        CHECK (confidence IN ('certain','likely','guess')),
    notes         TEXT,
    labeled_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (segment_date, segment_start)
);

-- Per-minute wide attribution: one row per minute, one column per
-- fixture, gpm allocated proportionally from each segment's
-- attribution probabilities. Materialized for fast dashboard queries;
-- refreshed by backfill_minute_attributions.py (one-shot) and by the
-- 6-hourly sync (last 4 days incremental).
--
-- Invariant: the sum of all *_gpm columns equals total_gpm (within
-- 0.05 rounding tolerance).
CREATE TABLE IF NOT EXISTS flume_minute_attributions (
    ts                       TIMESTAMP    NOT NULL PRIMARY KEY,
    total_gpm                NUMERIC(8,3) NOT NULL,
    irrigation_spray_gpm     NUMERIC(8,3) NOT NULL DEFAULT 0,
    irrigation_drip_gpm      NUMERIC(8,3) NOT NULL DEFAULT 0,
    irrigation_bubbler_gpm   NUMERIC(8,3) NOT NULL DEFAULT 0,
    pool_autofill_gpm        NUMERIC(8,3) NOT NULL DEFAULT 0,
    dishwasher_gpm           NUMERIC(8,3) NOT NULL DEFAULT 0,
    shower_gpm               NUMERIC(8,3) NOT NULL DEFAULT 0,
    sink_hot_gpm             NUMERIC(8,3) NOT NULL DEFAULT 0,
    clothes_washer_hot_gpm   NUMERIC(8,3) NOT NULL DEFAULT 0,
    clothes_washer_cold_gpm  NUMERIC(8,3) NOT NULL DEFAULT 0,
    toilet_flush_gpm         NUMERIC(8,3) NOT NULL DEFAULT 0,
    sink_cold_gpm            NUMERIC(8,3) NOT NULL DEFAULT 0,
    fridge_event_gpm         NUMERIC(8,3) NOT NULL DEFAULT 0,
    leak_gpm                 NUMERIC(8,3) NOT NULL DEFAULT 0,
    unknown_gpm              NUMERIC(8,3) NOT NULL DEFAULT 0,
    computed_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS flume_minute_attributions_date
    ON flume_minute_attributions ((ts::date));

-- Surface ambiguous and unknown segments for user review. Ordered by
-- gallons descending so the biggest unidentified events are at the top.
CREATE OR REPLACE VIEW flume_questionnaire AS
SELECT
    f.date, f.start_time, f.duration_min, f.mean_gpm, f.peak_gpm, f.gallons,
    f.category_v2,
    (SELECT string_agg(fixture || ':' || ROUND(probability*100) || '%',
                       ', ' ORDER BY probability DESC)
     FROM flume_segment_attributions a
     WHERE a.segment_date=f.date AND a.segment_start=f.start_time
       AND a.probability >= 0.05) AS top_candidates,
    (SELECT MAX(probability)
     FROM flume_segment_attributions a
     WHERE a.segment_date=f.date AND a.segment_start=f.start_time) AS top_prob
FROM flume_segments f
WHERE NOT EXISTS (
    SELECT 1 FROM flume_user_labels l
    WHERE l.segment_date=f.date AND l.segment_start=f.start_time
  )
  AND f.gallons >= 1.0
  AND (
    (SELECT MAX(probability) FROM flume_segment_attributions a
     WHERE a.segment_date=f.date AND a.segment_start=f.start_time) < 0.7
    OR
    EXISTS (SELECT 1 FROM flume_segment_attributions a
            WHERE a.segment_date=f.date AND a.segment_start=f.start_time
              AND a.fixture='unknown')
  )
ORDER BY f.gallons DESC;

-- B-Hyve irrigation sessions, merged from per-zone valve open/close
-- intervals. Source = 'bhyve_valve' for HA-derived sessions; the
-- column allows future heuristics-based fillers without schema churn.
CREATE TABLE IF NOT EXISTS irrigation_sessions (
    session_id   SERIAL       PRIMARY KEY,
    start_ts     TIMESTAMP    NOT NULL UNIQUE,
    end_ts       TIMESTAMP    NOT NULL,
    zone_count   INT          NOT NULL,
    zones        TEXT         NOT NULL,
    source       TEXT         NOT NULL DEFAULT 'bhyve_valve',
    detected_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS irrigation_sessions_range
    ON irrigation_sessions (start_ts, end_ts);

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
        peak_gpm, category, autofill_session_id,
        category_v2, category_v2_reason, category_v2_computed_at)
VALUES (%s,   %s,         %s,       %s,           %s,      %s,
        %s,       %s,       %s,
        %s,       %s,       %s)
ON CONFLICT (date, start_time) DO UPDATE SET
    end_time                = EXCLUDED.end_time,
    duration_min            = EXCLUDED.duration_min,
    gallons                 = EXCLUDED.gallons,
    mean_gpm                = EXCLUDED.mean_gpm,
    peak_gpm                = EXCLUDED.peak_gpm,
    category                = EXCLUDED.category,
    autofill_session_id     = EXCLUDED.autofill_session_id,
    category_v2             = EXCLUDED.category_v2,
    category_v2_reason      = EXCLUDED.category_v2_reason,
    category_v2_computed_at = EXCLUDED.category_v2_computed_at,
    detected_at             = now();
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
    #
    # Dedup by ts: VM pre-populate's query_range end-time is inclusive,
    # so the midnight sample of day N appears in BOTH cache files
    # (day N-1.json and day N.json). Postgres rejects duplicate rows
    # in a single ON CONFLICT DO UPDATE batch — collapse them here.
    # Later sample wins (consistent with UPSERT semantics).
    sample_dict: dict = {}
    for ts, gpm in samples:
        if ts.date() in target_set:
            sample_dict[ts] = gpm
    sample_rows = list(sample_dict.items())

    # 2) Refresh B-Hyve irrigation sessions for the date range from HA
    # Postgres. Only the dates we're syncing — anything older than HA's
    # ~30-day recorder retention won't return rows and the v2 classifier
    # falls back to its no-valve-data branch. Errors here are non-fatal:
    # we degrade to v1-equivalent (rules 1+2 only) rather than blocking
    # the sync.
    range_start = datetime.combine(target_dates[0], datetime.min.time())
    range_end = datetime.combine(
        target_dates[-1] + timedelta(days=1), datetime.min.time()
    )
    try:
        sessions = extract_sessions_from_ha(
            HA_POSTGRES_DSN, range_start, range_end
        )
    except Exception as exc:
        print(f"warning: HA Postgres unreachable, v2 classifier degraded: {exc}")
        sessions = []

    # 2a) Tankless hot-water flow — persists per-minute interpolated
    # values into tankless_minute_samples. Same failure mode handling:
    # non-fatal, classifier just won't have hot-water context.
    try:
        with psycopg2.connect(**DB_CONNECT_KWARGS) as tk_conn:
            with tk_conn.cursor() as cur:
                cur.execute(SCHEMA_DDL)
            tk_conn.commit()
            tk_rows = tankless_sync(
                tk_conn, HA_POSTGRES_DSN, range_start, range_end
            )
            tk_conn.commit()
            if tk_rows:
                print(f"  upserted {tk_rows} tankless minute samples")
    except Exception as exc:
        print(f"warning: tankless sync failed: {exc}")

    # 2b) Miele dishwasher cycles — third ground-truth source.
    try:
        with psycopg2.connect(**DB_CONNECT_KWARGS) as dw_conn:
            cycles = dishwasher_extract(HA_POSTGRES_DSN, range_start, range_end)
            n = dishwasher_persist(dw_conn, cycles)
            dw_conn.commit()
            if n:
                print(f"  upserted {n} dishwasher cycles")
    except Exception as exc:
        print(f"warning: dishwasher sync failed: {exc}")

    # 3) Derived segments — precomputed for fast dashboard queries.
    # Also compute v2 classification using the refreshed irrigation
    # sessions. Per-segment slice of `samples` is reused for both the
    # v1 detector (already computed by detect_segments) and the v2
    # classifier (needs per-minute gpm for stddev / in-band frac).
    segments = detect_segments(samples)
    segment_rows: list[tuple] = []
    autofill_session_by_date: dict[date, int] = defaultdict(int)
    now_ts = datetime.now()
    sessions_by_date_cache: dict[date, list[tuple[datetime, datetime]]] = {}
    valve_data_by_date: dict[date, bool] = {}

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

        # v2 classification — restrict the irrigation_sessions list to
        # those overlapping this date and decide if we have any B-Hyve
        # context to apply rule 3.
        if d not in sessions_by_date_cache:
            day_start = datetime.combine(d, datetime.min.time())
            day_end = day_start + timedelta(days=1)
            sessions_by_date_cache[d] = [
                (s.start_ts, s.end_ts)
                for s in sessions
                if s.start_ts < day_end and s.end_ts > day_start
            ]
            # Have-valve-data heuristic for the sync path: yes if we
            # got ANY sessions back in the range (means HA recorder
            # retention covers it).
            valve_data_by_date[d] = bool(sessions) and (
                d >= (date.today() - timedelta(days=HA_RECORDER_RETENTION_DAYS))
            )
        v2 = classify_segment(
            seg_date=d,
            seg_start_time=start_local.time(),
            seg_end_time=end_local.time(),
            mean_gpm=float(mean_gpm),
            per_minute_gpm=gpms,
            irrigation_sessions=sessions_by_date_cache[d],
            have_valve_data=valve_data_by_date[d],
        )

        segment_rows.append(
            (d, start_local.time(), end_local.time(), duration, gallons,
             mean_gpm, peak_gpm, category, session_id,
             v2.category, v2.reason, now_ts)
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
            persisted = persist_sessions(conn, sessions)
            if persisted:
                print(f"  upserted {persisted} irrigation sessions")
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
        # Last N days INCLUDING today. range(N, -1, -1) → [N, N-1, ..., 1, 0]
        # so we capture today's partial data; tomorrow's run UPSERTs the
        # complete day over it.
        today = date.today()
        target = [today - timedelta(days=i) for i in range(args.days, -1, -1)]
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

    # v3 attributions + per-minute materialization. Failures are
    # non-fatal — the upstream segment data is still up to date and
    # the user can re-run these manually.
    try:
        from backfill_v3 import backfill as backfill_v3
        from refresh_minute_attributions import refresh as refresh_minutes

        days = max(args.days, 1) if not args.from_cache else 7
        counter = backfill_v3(days=days)
        n_attrs = sum(counter.values())
        print(f"  v3 attributions: classified {n_attrs} segments")
        n_min = refresh_minutes(
            start_date=date.today() - timedelta(days=days),
            end_date=date.today(),
        )
        print(f"  refreshed {n_min} per-minute attribution rows")
    except Exception as exc:
        print(f"warning: v3 attribution refresh failed: {exc}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
