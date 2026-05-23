# Flume Historical Data — Reference Guide

How the historical Flume water-use data is collected, where it lives, and
how to query / re-process it for your own analyses.

Companion to `docs/WATER_ATTRIBUTION.md` (which covers the live Phase 1/2/3
attribution stack inside Home Assistant). This document is specifically
about the **per-minute historical Flume data** persisted in PostgreSQL and
on disk under `/var/lib/flume-autofill/`.

---

## Where the data lives

There are four physical locations for the same underlying Flume per-minute
stream, each serving a different need:

| Location | Format | Content | Purpose |
|---|---|---|---|
| `/var/lib/flume-autofill/cache/per-minute-by-day/YYYY-MM-DD.json` | JSON | One file per local date, `[[iso_naive_local_ts, gpm], ...]` | Source of truth on disk; cheap re-processing |
| `/var/lib/flume-autofill/backfill/flume-segments.csv` | CSV | One row per continuous-usage segment + autofill classification | Excel-friendly export |
| `/var/lib/flume-autofill/backfill/flume-day-totals.csv` | CSV | One row per day with sum/count rollups | Excel-friendly day-level view |
| PostgreSQL `flume-autofill` database | SQL | Two tables + one view (see schema below) | Ad-hoc SQL queries, Grafana, joins |

**The PostgreSQL tables are the recommended primary source for analysis.**
The CSVs are convenience exports; the cache files are intermediate. All
three are derived from the same Flume API responses.

---

## PostgreSQL schema

### `flume_minute_samples` — raw per-minute samples (authoritative)

```sql
CREATE TABLE flume_minute_samples (
    ts   TIMESTAMP    NOT NULL,   -- naive device-local (America/Los_Angeles)
    gpm  NUMERIC(8,3) NOT NULL,   -- gallons that minute (also = average GPM)
    PRIMARY KEY (ts)
);
CREATE INDEX flume_minute_samples_date ON flume_minute_samples ((ts::date));
```

Every per-minute sample Flume's API returned, including zero-GPM idle
minutes. **This is the authoritative ground truth.** Compute any
aggregation you want from this table — `flume_segments` and
`flume_day_totals` are derived conveniences.

Expected scale: ~1440 samples/day × days-of-history = ~430k rows/year =
~22 MB/year. Trivial for Postgres.

**Timestamp semantics:** stored naive in device-local time
(America/Los_Angeles). Flume's API contract is "device-local timestamps,
no offset" — we preserve that to avoid round-trip conversion errors.
When joining with TIMESTAMPTZ data from elsewhere (e.g., HA Postgres),
explicitly cast: `ts AT TIME ZONE 'America/Los_Angeles'`.

### `flume_segments` — derived per-segment with classification

```sql
CREATE TABLE flume_segments (
    date                  DATE          NOT NULL,
    start_time            TIME          NOT NULL,        -- local PT
    end_time              TIME          NOT NULL,
    duration_min          INT           NOT NULL,
    gallons               NUMERIC(10,3) NOT NULL,
    mean_gpm              NUMERIC(8,3)  NOT NULL,
    peak_gpm              NUMERIC(8,3)  NOT NULL,
    category              TEXT          NOT NULL
        CHECK (category IN ('pool_autofill','other')),
    autofill_session_id   INT,                           -- nullable for 'other'
    source                TEXT          NOT NULL DEFAULT 'flume_api',
    detected_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (date, start_time)
);
```

A "segment" is a contiguous run of consecutive minutes with
`gpm > 0.05`. Single-minute zero gaps are absorbed (the segmenter sees
9 in-range + 1 zero + 4 in-range as one 14-minute segment).

`category = 'pool_autofill'` when the segment satisfies the canonical
autofill detection rule (10+ min, with a rolling 10-minute window where
≥9 minutes are in [3.0, 5.0] GPM AND rolling mean is in [3.0, 5.0]).
Otherwise `'other'`. `autofill_session_id` is a per-day sequence number
(1 = first autofill of that day) — useful for grouping multiple
soak-cycles of a single irrigation/fill event in a future v2.

### `flume_day_totals` — view

```sql
CREATE OR REPLACE VIEW flume_day_totals AS
SELECT date,
       SUM(gallons)                                         AS total_gallons,
       SUM(gallons) FILTER (WHERE category='pool_autofill') AS pool_autofill_gallons,
       SUM(gallons) FILTER (WHERE category='other')         AS other_gallons,
       COUNT(*)     FILTER (WHERE category='pool_autofill') AS pool_autofill_sessions
FROM flume_segments
GROUP BY date;
```

Auto-updates when `flume_segments` changes; no separate sync needed.

---

## How to connect

The database is owned by the OS user `flume-autofill` via Postgres peer
authentication. The Grafana service user also has peer access (read).
For interactive queries:

```bash
sudo -u flume-autofill psql -d flume-autofill
```

For Python from outside the systemd sandbox (e.g., a notebook):

```python
import psycopg2
# kwargs form — DSN string mangles the hyphenated dbname
conn = psycopg2.connect(dbname="flume-autofill", user="flume-autofill")
```

For Grafana, add a PostgreSQL data source pointing at
`/run/postgresql/.s.PGSQL.5432` with user `grafana`. No password — peer
auth.

---

## Query recipes

### Quick daily totals (precomputed, fast)

```sql
SELECT * FROM flume_day_totals ORDER BY date DESC LIMIT 30;
```

### Custom daily total computed from raw samples

```sql
SELECT (ts::date) AS d,
       ROUND(SUM(gpm)::numeric, 2) AS daily_gallons
FROM flume_minute_samples
GROUP BY (ts::date)
ORDER BY d DESC;
```

### Your own custom autofill rule

The default detector uses **10 min, 3.0-5.0 GPM, 9-of-10 in-range with
mean in range**. To experiment with alternative parameters straight from
the raw samples, without re-running the Python detector:

```sql
-- Minutes per day in a custom GPM range
SELECT (ts::date) AS d,
       COUNT(*) FILTER (WHERE gpm BETWEEN 3.5 AND 4.5) AS minutes_in_range,
       ROUND(SUM(gpm) FILTER (WHERE gpm BETWEEN 3.5 AND 4.5)::numeric, 2) AS gal_in_range
FROM flume_minute_samples
GROUP BY (ts::date)
ORDER BY d DESC;
```

### Find continuous-usage runs (window-function flavor)

```sql
-- Identify contiguous "usage" runs (gap > 1 min = run boundary)
WITH active AS (
    SELECT ts, gpm,
           LAG(ts)  OVER (ORDER BY ts) AS prev_ts,
           LAG(gpm) OVER (ORDER BY ts) AS prev_gpm
    FROM flume_minute_samples
    WHERE gpm > 0.05
),
boundaries AS (
    SELECT ts, gpm,
           CASE WHEN ts - prev_ts > INTERVAL '1 minute'
                  OR prev_ts IS NULL
                THEN 1 ELSE 0 END AS new_run
    FROM active
),
runs AS (
    SELECT ts, gpm,
           SUM(new_run) OVER (ORDER BY ts) AS run_id
    FROM boundaries
)
SELECT run_id,
       MIN(ts) AS start_ts,
       MAX(ts) AS end_ts,
       COUNT(*) AS duration_min,
       ROUND(SUM(gpm)::numeric, 2) AS gallons,
       ROUND(AVG(gpm)::numeric, 2) AS mean_gpm,
       ROUND(MAX(gpm)::numeric, 2) AS peak_gpm
FROM runs
GROUP BY run_id
HAVING COUNT(*) >= 5
ORDER BY start_ts DESC
LIMIT 50;
```

### Compare derived segments vs raw — sanity check

```sql
-- Should be ≈ equal (small rounding differences OK)
SELECT 'segments_total' AS source,
       ROUND(SUM(gallons)::numeric, 2) AS gal
FROM flume_segments
UNION ALL
SELECT 'raw_total' AS source,
       ROUND(SUM(gpm)::numeric, 2) AS gal
FROM flume_minute_samples;
```

### Anomaly hunting

```sql
-- Days with the most "other" water (potential leaks / hose use / etc.)
SELECT date,
       other_gallons,
       total_gallons,
       ROUND((other_gallons / NULLIF(total_gallons, 0) * 100)::numeric, 1) AS pct_other
FROM flume_day_totals
ORDER BY other_gallons DESC NULLS LAST
LIMIT 20;

-- Longest autofill sessions ever
SELECT date, start_time, duration_min, gallons, mean_gpm
FROM flume_segments
WHERE category = 'pool_autofill'
ORDER BY duration_min DESC
LIMIT 20;
```

### Cross-source consistency (vs VictoriaMetrics)

VictoriaMetrics has data from approximately 2025-12-08 onwards (whenever
HA's InfluxDB integration was enabled). Comparing the Flume API source
vs VM for the same window catches drift / gaps:

```sql
-- Sum total gallons per day from the Postgres copy
SELECT (ts::date) AS d, ROUND(SUM(gpm)::numeric, 2) AS pg_gallons
FROM flume_minute_samples
WHERE ts >= '2025-12-08'
GROUP BY (ts::date)
ORDER BY d;
```

Compare with VM via Grafana or PromQL:

```promql
sum_over_time(
  last_over_time({entity_id="flume_sensor_sierra_oaks_current"}[1m])[1d:1m]
)
```

A delta of more than a few gallons per day across most days suggests an
ingestion issue worth investigating.

---

## How data gets into the tables

The pipeline:

```
   Flume Personal API  (api.flumewater.com)
            │
            │  ≤ 120 req/hr (Flume hard limit)
            │  MIN bucket, 24h chunks (Flume hard limit)
            ▼
   /var/lib/flume-autofill/cache/per-minute-by-day/YYYY-MM-DD.json
            │
            ├──→ flume-autofill-daily-sync.service (oneshot, every 6h)
            │       loads last 3 days from cache, computes segments,
            │       UPSERTs into BOTH tables.
            │
            └──→ emit_segments_csv.py (manual)
                    one-shot reads cache, writes the two CSVs.
```

### The 6-hourly sync timer

`flume-autofill-daily-sync.timer` fires at **00:30, 06:30, 12:30, 18:30**
local time. It triggers `flume-autofill-daily-sync.service`, which runs
`python -m flume_db_sync --days 3`.

The 3-day rolling window absorbs late-arriving data without re-fetching
the full history. Cache hits are free (no API call); only genuinely
missing days trigger Flume API calls. The window itself is ≈ 4 API calls
on a typical run — well under the per-hour budget.

```bash
# Check next firing time
systemctl list-timers flume-autofill-daily-sync.timer

# Trigger a sync immediately
sudo systemctl start flume-autofill-daily-sync.service

# See what happened (with credential redaction)
sudo journalctl -u flume-autofill-daily-sync.service --since '10 min ago' \
    --no-pager 2>&1 | \
  sed -E '
    s/(password|client_secret|username|access_token)[[:space:]]*[:=][[:space:]]*[^[:space:]"]+/\1=[REDACTED]/gi
    s/[Bb]earer[=[:space:]]+[A-Za-z0-9._\-]+/Bearer [REDACTED]/g
    s/(eyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+)/[REDACTED_JWT]/g
  '
```

### Bulk-loading the full cache into Postgres

After a fresh historical pull (or any time the cache and DB diverge):

```bash
sudo systemd-run --uid=$(id -u flume-autofill) --gid=$(id -g flume-autofill) \
    --setenv=PYTHONPATH=$(systemctl show flume-autofill-daily-sync.service \
        --property=Environment --value | tr ' ' '\n' | \
        grep ^PYTHONPATH= | cut -d= -f2) \
    --pipe --wait \
    /run/current-system/sw/bin/python -m flume_db_sync --from-cache
```

This reads every JSON file under `cache/per-minute-by-day/` and UPSERTs
the entire history. Uses `execute_values` with 5000-row pages — ~1.2M
rows complete in seconds rather than minutes. Idempotent; re-running
just re-overwrites the same rows.

### Initial historical pull

`emit_segments_csv.py` is the script that talks to the Flume API at
length. It's NOT wired to a systemd unit; you launch it explicitly when
you want to do a bulk historical fetch:

```bash
# Pull the entire device history (~7-8 hours wall time at 30s/call)
sudo CREDENTIALS_DIRECTORY=/run/secrets/flume \
    /run/current-system/sw/bin/python \
    /etc/nixos/scripts/flume-autofill/emit_segments_csv.py

# Or a specific date range
sudo CREDENTIALS_DIRECTORY=/run/secrets/flume \
    /run/current-system/sw/bin/python \
    /etc/nixos/scripts/flume-autofill/emit_segments_csv.py \
    --from 2024-02-01 --to 2024-12-31
```

The cache directory under `/var/lib/flume-autofill/cache/` persists
across runs — if the script is interrupted, just re-run; cached days
are skipped.

After the pull completes, run the bulk-load command above to copy
everything into Postgres.

---

## Operational notes

### Re-classification

If you decide your autofill detection rule has changed (e.g., your pool
float now opens at 4 GPM instead of 3.5), the segments table needs to be
rebuilt:

1. Edit the detection constants in
   `/etc/nixos/scripts/flume-autofill/flume_autofill/detection.py` (or
   the duplicate in `emit_segments_csv.py` — long-term, deduplicate).
2. `nixos-rebuild switch` to deploy.
3. `TRUNCATE flume_segments` to drop the old classification.
4. Run `--from-cache` to repopulate from the (unchanged) raw samples
   with the new rule. **`flume_minute_samples` is unaffected** — that's
   the point of separating raw from derived.

### Backups

The whole `flume-autofill` database is included in the daily
`postgresql-backup.timer` snapshot at 2 AM (writes to
`/tank/Backups/PostgreSQL/`). No additional backup step needed.

The `cache/per-minute-by-day/` JSON files are NOT backed up — they're
recreatable from the API at any time. (If you ever do a clean restore,
the next sync will re-populate the cache from the API as needed.)

### Filling gaps

If the timer service has been down for a while and missed several days,
the next 3-day rolling sync won't catch days older than 3 days ago.
Run a targeted re-sync:

```bash
# Day-by-day re-fetch + re-sync from API
sudo CREDENTIALS_DIRECTORY=/run/secrets/flume \
    /run/current-system/sw/bin/python \
    /etc/nixos/scripts/flume-autofill/emit_segments_csv.py \
    --from 2026-05-10 --to 2026-05-22

# Bulk-load the now-up-to-date cache into Postgres
sudo systemd-run --uid=$(id -u flume-autofill) ... -m flume_db_sync --from-cache
```

### Monitoring health

```sql
-- Latest sample we have. Should be < 1 hour old after a sync run.
SELECT MAX(ts) AS most_recent FROM flume_minute_samples;

-- Days missing entirely from the past 30 days
SELECT d AS missing_date
FROM generate_series(CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE, '1 day') AS s(d)
WHERE NOT EXISTS (
    SELECT 1 FROM flume_minute_samples WHERE ts::date = d::date
)
ORDER BY d;

-- COMPLETE gap detection: every missing date from earliest sample
-- through today. Run this after the initial bulkload to verify no
-- days were dropped during the multi-hour historical pull. Should
-- return ZERO rows if the cache is hole-free.
WITH range AS (
    SELECT MIN(ts::date) AS first, CURRENT_DATE AS last FROM flume_minute_samples
)
SELECT d AS missing_date
FROM range, generate_series(range.first, range.last, '1 day') AS s(d)
WHERE NOT EXISTS (
    SELECT 1 FROM flume_minute_samples WHERE ts::date = d::date
)
ORDER BY d;

-- Per-day sample count — should be close to 1440 (one per minute).
-- Days with < 1440 may indicate Flume-side outages or partial pulls.
SELECT (ts::date) AS d, COUNT(*) AS samples
FROM flume_minute_samples
GROUP BY (ts::date)
HAVING COUNT(*) < 1400  -- 40 missing minutes ≈ likely real issue
ORDER BY d DESC;

-- Segment-vs-raw gallons mismatch (large = detection drift or data corruption)
SELECT ABS(
    (SELECT SUM(gallons) FROM flume_segments) -
    (SELECT SUM(gpm)     FROM flume_minute_samples)
) AS gal_delta;
```

If `gal_delta` exceeds a few percent of the raw total, segments are out
of sync with the underlying samples — most likely a detection-rule
change without re-classification. Truncate + re-load (see above).

### Re-fetching specific date ranges (gap repair)

If the gap query reveals missing dates, re-fetch just those days from
the Flume API and bulkload:

```bash
sudo CREDENTIALS_DIRECTORY=/run/secrets/flume \
    /run/current-system/sw/bin/python \
    /etc/nixos/scripts/flume-autofill/emit_segments_csv.py \
    --from YYYY-MM-DD --to YYYY-MM-DD

sudo systemctl start flume-autofill-bulkload.service
```

The bulkload is idempotent (UPSERT semantics on the natural keys), so
this can be run any number of times without duplication.

---

## Schema-evolution notes

Adding columns to `flume_segments` (e.g., a third category, an
attribution to a specific irrigation zone, additional metadata) is safe
in-place:

```sql
ALTER TABLE flume_segments
    ADD COLUMN attribution_source TEXT,
    ADD COLUMN flagged_for_review BOOLEAN DEFAULT FALSE;
```

Renaming or dropping columns requires care — the `flume_day_totals`
view depends on this table. Drop the view first, alter, recreate.

`flume_minute_samples` should generally NOT be altered — it's append-
only ground truth. If you find yourself wanting to add columns there,
that's probably a sign the new data belongs in a separate table joined
on `ts` (e.g., `flume_minute_annotations`).

---

## Where things are defined in code

* Schema DDL: `scripts/flume-autofill/flume_db_sync.py:SCHEMA_DDL`
* Segment detection: `scripts/flume-autofill/flume_autofill/detection.py`
  + `scripts/flume-autofill/emit_segments_csv.py:detect_segments` +
  `is_pool_autofill_segment`
* Cache shape: `scripts/flume-autofill/emit_segments_csv.py:chunked_pull`
  (writes one JSON per day with `[[iso_naive_ts, gpm], ...]`)
* NixOS module: `modules/services/flume-autofill.nix`
* DB provisioning: `modules/services/databases.nix` (database +
  `ensureUsers` + pg_hba peer-auth lines)
