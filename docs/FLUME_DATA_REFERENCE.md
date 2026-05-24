# Flume Historical Data — Reference Guide

How the historical Flume water-use data is collected, where it lives, and
how to query / re-process it for your own analyses.

Companion to `docs/WATER_ATTRIBUTION.md` (which covers the live Phase 1/2/3
attribution stack inside Home Assistant). This document is specifically
about the **per-minute historical Flume data** persisted in PostgreSQL and
on disk under `/var/lib/flume-data/`.

---

## Where the data lives

There are four physical locations for the same underlying Flume per-minute
stream, each serving a different need:

| Location | Format | Content | Purpose |
|---|---|---|---|
| `/var/lib/flume-data/cache/per-minute-by-day/YYYY-MM-DD.json` | JSON | One file per local date, `[[iso_naive_local_ts, gpm], ...]` | Source of truth on disk; cheap re-processing |
| `/var/lib/flume-data/backfill/flume-segments.csv` | CSV | One row per continuous-usage segment + autofill classification | Excel-friendly export |
| `/var/lib/flume-data/backfill/flume-day-totals.csv` | CSV | One row per day with sum/count rollups | Excel-friendly day-level view |
| PostgreSQL `flume-data` database | SQL | Two tables + one view (see schema below) | Ad-hoc SQL queries, Grafana, joins |

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

#### v2 columns — B-Hyve-aware classification

```sql
ALTER TABLE flume_segments
    ADD COLUMN category_v2             TEXT,         -- 'pool_autofill' | 'irrigation' | 'background' | 'other'
    ADD COLUMN category_v2_reason      TEXT,         -- human-readable explanation
    ADD COLUMN category_v2_computed_at TIMESTAMPTZ;
```

The v2 classifier (`flume_data/classify_v2.py`) replaces the rolling 9-of-10
heuristic with three rules applied in order:

1. **Irrigation suppression** — if the segment overlaps any row in
   `irrigation_sessions` (sourced from `valve.sprinkler_control_*_zone`
   open/closed events in HA), it is `irrigation`. Wins over all other
   rules.
2. **Tight band** — `mean_gpm` must be in `[3.2, 3.8]` GPM (the
   characteristic pool autofill rate is ~3.5 GPM, not the looser 3-5
   v1 used).
3. **Sustained** — per-minute `gpm_stddev < 0.6` AND at least 85% of
   minutes in the [3.2, 3.8] band. Drip-zone tails fluctuate too much
   to satisfy this even when their mean drifts through 3.5.

`background` is the bucket for sub-1 GPM segments (faint leaks, drip
noise) — separated out so the "other" bucket isn't dominated by them.

When the date is older than HA recorder retention (~30 days), rule 1 is
skipped and `category_v2_reason` ends in `(no B-Hyve data)`. Filter on
that suffix when comparing recent vs historical classifications.

Use `category` for v1 (historical, pre-2026-05-23). Use `category_v2`
for accurate current totals. The v1 column stays for audit trail.

### `irrigation_sessions` — B-Hyve ground truth

```sql
CREATE TABLE irrigation_sessions (
    session_id  SERIAL      PRIMARY KEY,
    start_ts    TIMESTAMP   NOT NULL UNIQUE,      -- local PT, naive
    end_ts      TIMESTAMP   NOT NULL,             -- local PT, naive
    zone_count  INT         NOT NULL,             -- distinct zones in the session
    zones       TEXT        NOT NULL,             -- comma-separated zone slugs
    source      TEXT        NOT NULL DEFAULT 'bhyve_valve',
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

A "session" is a merge of overlapping or near-adjacent
(`gap ≤ 10 min`) zone open intervals. The 6-hourly sync extracts new
sessions from HA's `valve.sprinkler_control_*_zone` history each run;
the standalone `backfill_v2.py` bootstraps the table from whatever HA
retention still has.

### `tankless_minute_samples` — hot-water flow

```sql
CREATE TABLE tankless_minute_samples (
    ts   TIMESTAMP    NOT NULL PRIMARY KEY,  -- local PT, naive
    gpm  NUMERIC(8,3) NOT NULL
);
```

Per-minute hot-water flow from the Navien tankless heater, sourced
from `sensor.water_heater_ch1_ch1_unit1_hot_water_flow` in HA. The
underlying sensor is event-driven (emits on state change); this table
is **forward-filled** to per-minute so it joins directly with
`flume_minute_samples` on `ts`. A minute with no event keeps the prior
value (which may be 0).

**Coverage starts 2026-05-19** (when the sensor was added to HA);
older minutes won't appear here.

Used by the v3 classifier to discriminate hot-water fixtures (shower,
dishwasher, washer-hot) from cold-only ones (toilet, irrigation, pool
autofill, fridge).

### `dishwasher_cycles` — Miele ground truth

```sql
CREATE TABLE dishwasher_cycles (
    cycle_id    SERIAL    PRIMARY KEY,
    start_ts    TIMESTAMP NOT NULL UNIQUE,   -- local PT, naive
    end_ts      TIMESTAMP NOT NULL,
    program     TEXT,                        -- "Normal", "Eco" etc. (may be "no_program")
    gallons     NUMERIC(6,3),                -- peak water_consumption during cycle
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Reconstructed from `sensor.dishwasher_program_phase` transitions in
HA. A cycle starts on `not_running → pre_dishwash` and ends on
entering `drying` (no more water from there) or returning to
`not_running`. Cycles shorter than 5 minutes are dropped as aborts.

The classifier treats any flow during a cycle's `[start_ts, end_ts]`
window as dishwasher, since attempting to detect from Flume alone
fails (the Miele uses ~3.5 gal across ~3 hours in 3-5 fill pulses,
many of which are sub-segment-detection-threshold).

**Coverage starts 2026-04-23** (HA recorder retention for the
`sensor.dishwasher_*` entities).

### `flume_segment_attributions` — v3 probabilistic classifier

```sql
CREATE TABLE flume_segment_attributions (
    segment_date  DATE          NOT NULL,
    segment_start TIME          NOT NULL,
    fixture       TEXT          NOT NULL,
    probability   NUMERIC(4,3)  NOT NULL CHECK (probability BETWEEN 0 AND 1),
    gallons       NUMERIC(10,3) NOT NULL,   -- = segment.gallons × probability
    classifier    TEXT          NOT NULL DEFAULT 'v3',
    computed_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (segment_date, segment_start, fixture)
);
```

Long-format probabilistic output. **Multiple rows per segment**, one
per fixture that scored above the 5% noise threshold. Probabilities
sum to ~1.0 per segment; gallons sums to `flume_segments.gallons`
(within rounding). When a row exists in `flume_user_labels`, the
classifier replaces the multi-row distribution with a single row at
`probability = 1.0`.

The library of fixtures lives in `flume_data/fixtures.py` and uses
Gaussian likelihoods (mean ± σ from range midpoint) plus hard
constraints (must overlap B-Hyve, must be cold-only, etc.).

### `flume_minute_attributions` — wide per-minute table

```sql
CREATE TABLE flume_minute_attributions (
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
```

**This is the headline user-facing table.** One row per minute, one
column per fixture. Each minute's `total_gpm` is distributed across
the fixture columns by projecting `flume_segment_attributions` onto
the per-minute `flume_minute_samples.gpm`.

**Invariant:** for every row,
`sum(all *_gpm columns) ≈ total_gpm` (within 0.05 GPM rounding).
Verified across 1.2M rows during the initial backfill.

The `unknown_gpm` column catches two cases:
1. Minutes where the v3 classifier returned `("unknown", 1.0)`
2. Minutes with flow but no enclosing segment (sub-threshold flow
   that the segmenter skipped over)

Materialized by `refresh_minute_attributions.py`; refreshed
incrementally by the 6-hourly sync (`--days 4` window).

### `flume_user_labels` — manual ground-truth overrides

```sql
CREATE TABLE flume_user_labels (
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
```

When you can identify a segment that the classifier couldn't, label
it here. The next attribution refresh will replace the multi-fixture
probabilistic guess with `(user_fixture, 1.0)`.

```sql
-- example: label the 85-hour July 2025 event as a pool float stuck
INSERT INTO flume_user_labels (segment_date, segment_start, user_fixture, notes)
VALUES ('2025-07-23', '20:07:00', 'leak', 'pool float valve stuck open');
```

After labeling, run:
```bash
sudo -u flume-data /etc/nixos/scripts/flume-data/backfill_v3.py --days 800
sudo -u flume-data /etc/nixos/scripts/flume-data/refresh_minute_attributions.py --full
```
(or wait for the next 6-hourly sync, which only catches the most
recent 4-day window).

### `flume_questionnaire` — VIEW: events that need labeling

```sql
CREATE VIEW flume_questionnaire AS ...  -- see schema in flume_db_sync.py
```

Surfaces segments where:
- No user label exists yet
- `gallons >= 1.0` (skip noise)
- The top fixture probability is below 70% (ambiguous), OR the
  attribution is `unknown`

Ordered by gallons descending so the biggest unidentified events
appear first.

```sql
SELECT * FROM flume_questionnaire LIMIT 10;
```

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

The database is owned by the OS user `flume-data` via Postgres peer
authentication. The Grafana service user also has peer access (read).
For interactive queries:

```bash
sudo -u flume-data psql -d flume-data
```

For Python from outside the systemd sandbox (e.g., a notebook):

```python
import psycopg2
# kwargs form — DSN string mangles the hyphenated dbname
conn = psycopg2.connect(dbname="flume-data", user="flume-data")
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

> Note: `flume_day_totals` aggregates the v1 `category` column. For
> accurate post-2026-05-23 numbers, use the v2 recipes below.

### True pool autofill totals (v2, B-Hyve-aware)

```sql
SELECT date,
       SUM(gallons) FILTER (WHERE category_v2 = 'pool_autofill') AS pool_gal,
       SUM(gallons) FILTER (WHERE category_v2 = 'irrigation')    AS irrig_gal,
       SUM(gallons) FILTER (WHERE category_v2 = 'background')    AS bg_gal,
       SUM(gallons) FILTER (WHERE category_v2 = 'other')         AS other_gal,
       SUM(gallons)                                              AS total_gal
FROM flume_segments
WHERE date >= '2026-04-23'                          -- HA recorder retention
GROUP BY date
ORDER BY date DESC;
```

### What changed between v1 and v2 (audit query)

```sql
SELECT category AS v1, category_v2 AS v2, COUNT(*) AS n,
       ROUND(SUM(gallons)::numeric, 0) AS gal
FROM flume_segments
GROUP BY 1, 2
ORDER BY 1, 2;
```

### Spot-check a specific reclassification

```sql
SELECT date, start_time, duration_min, mean_gpm, peak_gpm,
       category, category_v2, category_v2_reason
FROM flume_segments
WHERE category = 'pool_autofill'
  AND category_v2 = 'irrigation'
ORDER BY date DESC, start_time;
```

### Which irrigation sessions hit on a given day

```sql
SELECT start_ts, end_ts,
       EXTRACT(EPOCH FROM (end_ts - start_ts))::int / 60 AS minutes,
       zone_count, zones
FROM irrigation_sessions
WHERE start_ts::date = '2026-05-21'
ORDER BY start_ts;
```

### v3 — minute-by-minute attribution (the headline view)

```sql
-- what was happening every minute of an interesting hour
SELECT to_char(ts, 'HH24:MI') AS t, total_gpm,
       NULLIF(dishwasher_gpm, 0)         AS dishwasher,
       NULLIF(shower_gpm, 0)             AS shower,
       NULLIF(toilet_flush_gpm, 0)       AS toilet,
       NULLIF(sink_cold_gpm, 0)          AS sink_cold,
       NULLIF(sink_hot_gpm, 0)           AS sink_hot,
       NULLIF(fridge_event_gpm, 0)       AS fridge,
       NULLIF(unknown_gpm, 0)            AS unknown
FROM flume_minute_attributions
WHERE ts BETWEEN '2026-05-22 06:00' AND '2026-05-22 10:00'
  AND total_gpm > 0
ORDER BY ts;
```

### v3 — weekly water breakdown by category

```sql
SELECT ts::date AS day,
       ROUND(SUM(pool_autofill_gpm)::numeric, 0)        AS pool,
       ROUND(SUM(shower_gpm + sink_hot_gpm + dishwasher_gpm)::numeric, 0) AS hot_domestic,
       ROUND(SUM(toilet_flush_gpm + sink_cold_gpm + fridge_event_gpm)::numeric, 0) AS cold_domestic,
       ROUND(SUM(clothes_washer_hot_gpm + clothes_washer_cold_gpm)::numeric, 0) AS laundry,
       ROUND(SUM(irrigation_spray_gpm + irrigation_drip_gpm + irrigation_bubbler_gpm)::numeric, 0) AS irrigation,
       ROUND(SUM(unknown_gpm)::numeric, 0)              AS unknown,
       ROUND(SUM(total_gpm)::numeric, 0)                AS total
FROM flume_minute_attributions
WHERE ts >= now() - INTERVAL '7 days'
GROUP BY 1 ORDER BY 1;
```

### v3 — find segments with low classifier confidence (review candidates)

```sql
SELECT * FROM flume_questionnaire LIMIT 20;
```

### v3 — see all attributions for a single segment

```sql
SELECT fixture, probability, gallons, classifier
FROM flume_segment_attributions
WHERE segment_date = '2026-05-22' AND segment_start = '09:29:00'
ORDER BY probability DESC;
```

### v3 — invariant check (column sums must equal total_gpm)

```sql
SELECT COUNT(*) AS minutes,
       COUNT(*) FILTER (WHERE abs(total_gpm - (
           irrigation_spray_gpm + irrigation_drip_gpm + irrigation_bubbler_gpm
         + pool_autofill_gpm + dishwasher_gpm + shower_gpm + sink_hot_gpm
         + clothes_washer_hot_gpm + clothes_washer_cold_gpm + toilet_flush_gpm
         + sink_cold_gpm + fridge_event_gpm + leak_gpm + unknown_gpm
       )) > 0.05) AS invariant_failures
FROM flume_minute_attributions;
```

### v3 — manually label a segment

```sql
-- example: the 85-hour July 2025 event was a stuck pool float valve
INSERT INTO flume_user_labels (segment_date, segment_start, user_fixture, notes)
VALUES ('2025-07-23', '20:07:00', 'leak', 'pool float valve stuck open');

-- example: weekend dishwasher cycle the classifier missed (pre-Miele data era)
INSERT INTO flume_user_labels (segment_date, segment_start, user_fixture, confidence)
VALUES ('2025-09-20', '14:32:00', 'dishwasher', 'likely');
```

After labeling N segments, refresh the materialized table so the
labels propagate to `flume_minute_attributions`:

```bash
sudo -u flume-data /etc/nixos/scripts/flume-data/backfill_v3.py
sudo -u flume-data /etc/nixos/scripts/flume-data/refresh_minute_attributions.py --full
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
   /var/lib/flume-data/cache/per-minute-by-day/YYYY-MM-DD.json
            │
            ├──→ flume-data-daily-sync.service (oneshot, every 6h)
            │       loads last 3 days from cache, computes segments,
            │       UPSERTs into BOTH tables.
            │
            └──→ emit_segments_csv.py (manual)
                    one-shot reads cache, writes the two CSVs.
```

### The 6-hourly sync timer

`flume-data-daily-sync.timer` fires at **00:30, 06:30, 12:30, 18:30**
local time. It triggers `flume-data-daily-sync.service`, which runs
`python -m flume_db_sync --days 3`.

Each run does the full pipeline end-to-end in ~1 second (after the
initial backfill):

1. Pull Flume API data for the 3-day rolling window → `flume_minute_samples` + `flume_segments`
2. Pull tankless hot-water events from HA Postgres → `tankless_minute_samples` (per-minute interpolated)
3. Pull Miele dishwasher phases from HA Postgres → `dishwasher_cycles`
4. Pull B-Hyve valve events from HA Postgres → `irrigation_sessions`
5. Run v3 classifier on the recent segments → `flume_segment_attributions`
6. Refresh the wide projection → `flume_minute_attributions`

The 3-day rolling window absorbs late-arriving data without re-fetching
the full history. Cache hits are free (no API call); only genuinely
missing days trigger Flume API calls. The window itself is ≈ 4 API calls
on a typical run — well under the per-hour budget.

```bash
# Check next firing time
systemctl list-timers flume-data-daily-sync.timer

# Trigger a sync immediately
sudo systemctl start flume-data-daily-sync.service

# See what happened (with credential redaction)
sudo journalctl -u flume-data-daily-sync.service --since '10 min ago' \
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
sudo systemd-run --uid=$(id -u flume-data) --gid=$(id -g flume-data) \
    --setenv=PYTHONPATH=$(systemctl show flume-data-daily-sync.service \
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
    /etc/nixos/scripts/flume-data/emit_segments_csv.py

# Or a specific date range
sudo CREDENTIALS_DIRECTORY=/run/secrets/flume \
    /run/current-system/sw/bin/python \
    /etc/nixos/scripts/flume-data/emit_segments_csv.py \
    --from 2024-02-01 --to 2024-12-31
```

The cache directory under `/var/lib/flume-data/cache/` persists
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
   `/etc/nixos/scripts/flume-data/flume_data/detection.py` (or
   the duplicate in `emit_segments_csv.py` — long-term, deduplicate).
2. `nixos-rebuild switch` to deploy.
3. `TRUNCATE flume_segments` to drop the old classification.
4. Run `--from-cache` to repopulate from the (unchanged) raw samples
   with the new rule. **`flume_minute_samples` is unaffected** — that's
   the point of separating raw from derived.

### Re-calibrating v3 fixture signatures

The v3 fixture library lives in
`/etc/nixos/scripts/flume-data/flume_data/fixtures.py`. Each fixture
has a Gaussian likelihood centered on the midpoint of its
(mean_gpm, duration, gallons, hot_frac, peak/mean) ranges.

To tighten or expand a fixture (e.g., after observing that your shower
runs at 1.8 GPM rather than the assumed 2.0):

1. Edit the `Range(low, high)` for the relevant field in `fixtures.py`.
2. `nixos-rebuild switch` to deploy.
3. Re-attribute:
   ```bash
   sudo -u flume-data /etc/nixos/scripts/flume-data/backfill_v3.py
   sudo -u flume-data /etc/nixos/scripts/flume-data/refresh_minute_attributions.py --full
   ```

A useful re-calibration cadence is every ~2 weeks, as new
`tankless_minute_samples` and `dishwasher_cycles` data accumulates.
Look at `flume_questionnaire` for segments where the classifier is
uncertain — those are the candidates for either user labeling or
fixture-range tuning.

### Labeling unknown events

When `flume_questionnaire` shows a high-gallon event the classifier
couldn't identify (or got wrong), insert a row in
`flume_user_labels`. The next attribution refresh will replace the
multi-row probabilistic guess with a single `(user_fixture, 1.0)` row.

```sql
INSERT INTO flume_user_labels (segment_date, segment_start, user_fixture, notes)
VALUES ('2025-07-23', '20:07:00', 'leak', 'pool float stuck open');
```

Then:
```bash
sudo -u flume-data /etc/nixos/scripts/flume-data/backfill_v3.py
sudo -u flume-data /etc/nixos/scripts/flume-data/refresh_minute_attributions.py --full
```

Labeled segments are also propagated into the wide
`flume_minute_attributions` table, so dashboards and reports pick up
the correction automatically.

### Backups

The whole `flume-data` database is included in the daily
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
    /etc/nixos/scripts/flume-data/emit_segments_csv.py \
    --from 2026-05-10 --to 2026-05-22

# Bulk-load the now-up-to-date cache into Postgres
sudo systemd-run --uid=$(id -u flume-data) ... -m flume_db_sync --from-cache
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
    /etc/nixos/scripts/flume-data/emit_segments_csv.py \
    --from YYYY-MM-DD --to YYYY-MM-DD

sudo systemctl start flume-data-bulkload.service
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

* Schema DDL (all tables + views): `scripts/flume-data/flume_db_sync.py:SCHEMA_DDL`
* v1 segment detection: `scripts/flume-data/flume_data/detection.py`
  + `scripts/flume-data/emit_segments_csv.py:detect_segments` +
  `is_pool_autofill_segment`
* v2 sustained-flow classifier: `scripts/flume-data/flume_data/classify_v2.py`
* v3 fixture library: `scripts/flume-data/flume_data/fixtures.py`
* v3 probabilistic classifier: `scripts/flume-data/flume_data/classify_v3.py`
* B-Hyve irrigation extractor: `scripts/flume-data/flume_data/irrigation_sessions.py`
* Tankless hot-water reader: `scripts/flume-data/flume_data/tankless.py`
* Miele dishwasher reader: `scripts/flume-data/flume_data/dishwasher.py`
* One-shot backfills:
  - `scripts/flume-data/backfill_v2.py` (category_v2 + irrigation_sessions)
  - `scripts/flume-data/backfill_v3.py` (flume_segment_attributions)
  - `scripts/flume-data/refresh_minute_attributions.py` (per-minute wide table)
* Cache shape: `scripts/flume-data/emit_segments_csv.py:chunked_pull`
  (writes one JSON per day with `[[iso_naive_ts, gpm], ...]`)
* NixOS module: `modules/services/flume-data.nix`
* DB provisioning: `modules/services/databases.nix` (database +
  `ensureUsers` + pg_hba peer-auth lines including `local hass flume-data peer`)
* Preliminary fixture EDA findings: `docs/FLUME_FIXTURE_EDA.md`
* v3 design rationale: `docs/FLUME_V3_DESIGN.md`
