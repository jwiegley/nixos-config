# Flume v3 Design — Per-Minute Attribution + User Feedback Loop

> **Status (2026-07-27):** this is the **design record**, not a to-do list and not the
> as-built schema. Most of it shipped on 2026-05-23 (phase 3a `503bcff`, 3b `7e179e3`,
> 3c `b21395e`), **but the per-minute table was immediately rebuilt in long format**
> (commit `e9beaf0`, "replace wide `flume_minute_attributions` with long format"), so
> the wide one-column-per-fixture schema in section 1 below **does not exist**. For the
> schema that is actually deployed read
> [`FLUME_DATA_REFERENCE.md`](./FLUME_DATA_REFERENCE.md) and the authoritative DDL in
> `scripts/flume-data/flume_db_sync.py`. Still unbuilt as of 2026-07-27: the phase-3d
> **email digest of unlabeled big events** — `flume_user_labels` and the
> `flume_questionnaire` view exist, but nothing in `scripts/flume-data/` reads the view,
> so nothing surfaces questions to the user yet.

Building on v2 (B-Hyve-aware classifier) and the fixture EDA, v3 adds:

1. **Per-minute wide attribution table** — one column per fixture
2. **Feedback loop** — surface ambiguous events for user labeling, fold
   labels back into the classifier
3. **Miele dishwasher ground truth** — third source after B-Hyve and tankless
4. **Multiplicity-tolerant attribution** — handle 2-4 simultaneous showers

---

## 1. Per-minute wide table

> **Superseded — do not query against this.** The shipped
> `flume_minute_attributions` is **long format**: `(ts, fixture, gpm, source,
> computed_at)` with `PRIMARY KEY (ts, fixture)` and `source IN ('v3','user')`, zero or
> more rows per minute. The invariant is the same in spirit but tighter: per-minute
> `SUM(gpm)` equals `flume_minute_samples.gpm` within **0.05** GPM (not 0.1), and the
> refresh script asserts it after every rebuild. See
> `scripts/flume-data/flume_db_sync.py` for the live DDL. The wide design below is
> retained because the *column list* is still the fixture vocabulary the classifier
> uses.

```sql
CREATE TABLE flume_minute_attributions (
    ts                       TIMESTAMP    NOT NULL PRIMARY KEY,
    total_gpm                NUMERIC(8,3) NOT NULL,
    -- Ground-truth-backed categories (high confidence)
    irrigation_spray_gpm     NUMERIC(8,3) NOT NULL DEFAULT 0,
    irrigation_drip_gpm      NUMERIC(8,3) NOT NULL DEFAULT 0,
    irrigation_bubbler_gpm   NUMERIC(8,3) NOT NULL DEFAULT 0,
    pool_autofill_gpm        NUMERIC(8,3) NOT NULL DEFAULT 0,
    dishwasher_gpm           NUMERIC(8,3) NOT NULL DEFAULT 0,
    -- Hot-water-flow-informed categories
    shower_gpm               NUMERIC(8,3) NOT NULL DEFAULT 0,
    sink_hot_gpm             NUMERIC(8,3) NOT NULL DEFAULT 0,
    clothes_washer_hot_gpm   NUMERIC(8,3) NOT NULL DEFAULT 0,
    -- Cold-only fixtures (no hot water flow)
    clothes_washer_cold_gpm  NUMERIC(8,3) NOT NULL DEFAULT 0,
    toilet_flush_gpm         NUMERIC(8,3) NOT NULL DEFAULT 0,
    sink_cold_gpm            NUMERIC(8,3) NOT NULL DEFAULT 0,
    fridge_event_gpm         NUMERIC(8,3) NOT NULL DEFAULT 0,
    leak_gpm                 NUMERIC(8,3) NOT NULL DEFAULT 0,
    -- Catch-all
    unknown_gpm              NUMERIC(8,3) NOT NULL DEFAULT 0,
    -- Provenance
    classifier_version       TEXT         NOT NULL DEFAULT 'v3',
    has_user_label           BOOLEAN      NOT NULL DEFAULT FALSE,
    computed_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX flume_minute_attributions_date
    ON flume_minute_attributions ((ts::date));
```

**Invariant**: row-sum of all `*_gpm` columns ≈ `total_gpm` (within 0.1
GPM rounding tolerance).

### Sample query — total water by category for last 7 days

```sql
SELECT
    SUM(irrigation_spray_gpm + irrigation_drip_gpm + irrigation_bubbler_gpm) AS irrigation,
    SUM(pool_autofill_gpm)         AS pool,
    SUM(shower_gpm)                AS shower,
    SUM(dishwasher_gpm)            AS dishwasher,
    SUM(clothes_washer_hot_gpm + clothes_washer_cold_gpm) AS clothes_washer,
    SUM(toilet_flush_gpm)          AS toilet,
    SUM(sink_hot_gpm + sink_cold_gpm) AS sink,
    SUM(fridge_event_gpm)          AS fridge,
    SUM(leak_gpm)                  AS leak,
    SUM(unknown_gpm)               AS unknown
FROM flume_minute_attributions
WHERE ts >= now() - INTERVAL '7 days';
```

### Sample query — what was happening at 9 AM on a specific day

```sql
SELECT * FROM flume_minute_attributions
WHERE ts BETWEEN '2026-05-22 09:00' AND '2026-05-22 10:00'
ORDER BY ts;
```

---

## 2. Attribution algorithm (per minute)

For each minute `T` with `total_gpm = X`:

```
remaining = X

# Tier 1: hard ground truth — subtract attributed shares first
if irrigation active for any zone at T:
    for each active zone Z:
        attribute zone_type_gpm(Z) = expected_flow(Z)  # uses static zone table
        remaining -= expected_flow(Z)

if dishwasher phase in {pre_dishwash, main_dishwash, rinse, final_rinse}:
    # Cap by program-stage expected GPM (calibrate from water_consumption deltas)
    dishwasher_gpm = min(remaining, DISHWASHER_PEAK_GPM)
    remaining -= dishwasher_gpm

# Tier 2: pool_autofill — when v2 detector says yes for this segment
if segment containing T has category_v2 == 'pool_autofill':
    pool_autofill_gpm = min(remaining, POOL_GPM)  # ~3.5
    remaining -= pool_autofill_gpm

# Tier 3: split hot-water remainder
hot_at_t = tankless_minute_samples.gpm at T
hot_attributable = min(hot_at_t, remaining)

# Allocate hot among shower / sink_hot / washer_hot using likelihood
# (heuristic: shower if 5+ min sustained at >= 1.5 GPM, washer_hot if peaky)
shower_gpm, sink_hot_gpm, clothes_washer_hot_gpm = allocate_hot(hot_attributable, segment_context)
remaining -= (shower_gpm + sink_hot_gpm + clothes_washer_hot_gpm)

# Tier 4: cold-only allocation
# Use segment shape:
#   - peak/mean > 3 and duration > 25min → clothes_washer_cold
#   - 1 minute at 1.4-3 GPM → toilet_flush
#   - 0.1-0.7 GPM short → fridge_event
#   - else → sink_cold
... allocate ...

# Tier 5: leftover
unknown_gpm = max(0, remaining)
```

The triangular-likelihood scoring from v3's segment-attribution design
is wrapped in `allocate_hot()` and the cold-only allocator.

> **As built (2026-07-27):** there is no `allocate_hot()` anywhere in
> `scripts/flume-data/`, and the likelihood kernel is **Gaussian**, not triangular —
> `fixtures.Range.likelihood()` centres a Gaussian on the range midpoint with
> `sigma = (high - low) / 4`, precisely to avoid the triangular kernel's "edge-cliff"
> (a sample sitting exactly at `low` would score 0 and kill the whole fixture).
> Scoring and allocation live in `flume_data/classify_v3.py`.

### Multiplicity (3-4 simultaneous showers)

The per-minute table allocates **GPM**, not fixture counts. If
`hot_at_t = 8 GPM` and the only hot-water fixture in play is showers,
then `shower_gpm = 8`. The classifier doesn't need to know "this is 4
showers" — the gallons go in the right bucket regardless.

---

## 3. Feedback loop

### User-label table

```sql
CREATE TABLE flume_user_labels (
    label_id         SERIAL PRIMARY KEY,
    segment_date     DATE NOT NULL,
    segment_start    TIME NOT NULL,
    user_fixture     TEXT NOT NULL,
    confidence       TEXT NOT NULL DEFAULT 'certain'
        CHECK (confidence IN ('certain','likely','guess')),
    notes            TEXT,
    labeled_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (segment_date, segment_start)
);
```

When a label exists:
- `flume_minute_attributions` for that segment's minutes get the user
  fixture set to 100% (gpm = total_gpm for that fixture, all others 0)
- `has_user_label = true`
- Subsequent re-classification respects the label

### Questionnaire view

```sql
CREATE VIEW flume_questionnaire AS
SELECT
    f.date, f.start_time, f.duration_min, f.mean_gpm, f.peak_gpm, f.gallons,
    f.category_v2,
    -- top guesses with confidence
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
  AND f.gallons >= 1.0                  -- skip background
  AND (
    -- ambiguous (no fixture > 70% confident)
    (SELECT MAX(probability) FROM flume_segment_attributions a
     WHERE a.segment_date=f.date AND a.segment_start=f.start_time) < 0.7
    OR
    -- or unknown (no attribution at all)
    NOT EXISTS (SELECT 1 FROM flume_segment_attributions a
                WHERE a.segment_date=f.date AND a.segment_start=f.start_time)
  )
ORDER BY f.gallons DESC;
```

### User labeling workflow

Three options, in order of effort:

| Option | How | When to use |
|---|---|---|
| **A. psql one-liner** | `INSERT INTO flume_user_labels (segment_date, segment_start, user_fixture) VALUES ('2026-05-22', '09:29:00', 'shower');` | Power user; one or two labels at a time |
| **B. Email weekly report** | "Top 10 unknown events this week, paste back fixture names per line" | Steady ongoing labeling |
| **C. Grafana panel + button** | Click a row → modal asks for fixture → POST to a small flask endpoint that does the INSERT | Best UX; needs ~half-day of work |

Recommend starting with **A** until we have ~30 labels, then **C** if
worth investing.

---

## 4. Miele ground truth integration

Add to `tankless.py` (or new `dishwasher.py`):

```python
def fetch_dishwasher_cycles(ha_dsn, since_local, until_local) -> list[DishwasherCycle]:
    """Return (start_ts, end_ts, total_gallons, program) for each cycle."""
    # Read sensor.dishwasher_program_phase transitions
    # Cycle start: any phase != not_running/unavailable/finished after one of those
    # Cycle end: returns to not_running/finished
    # Total gallons: peak value of sensor.dishwasher_water_consumption during cycle
```

Per-minute allocation during a cycle:
- Distribute `total_gallons` across the cycle's active minutes
  proportional to Flume's observed flow at each minute
- This handles the discrete-fill-pulse pattern correctly

---

## 5. Calibrated fixture library v3.1 (updated from EDA)

> **Superseded by code.** The library that actually runs is
> `scripts/flume-data/flume_data/fixtures.py` (`FIXTURES`), and several ranges there
> are wider than this table — e.g. `shower` is `mean_gpm 1.3–10.0` ("high end
> accommodates 3-4 simultaneous"), `toilet_flush` is `1.2–2.5`, and
> `clothes_washer_hot` is no longer TBD (`2.0–10.0`, `peak_over_mean 2.5–8.0`). Read
> `fixtures.py` for current values; the table below is the calibration this design
> started from.

Based on user feedback:

| Fixture | Mean GPM | Notes |
|---|---:|---|
| shower | **2.0-2.5** (was 1.3-2.8) | Standard heads. Multiple instances handled by GPM allocation. |
| dishwasher | ground truth from Miele | Override classifier entirely when phase != not_running |
| clothes_washer_hot | TBD | Need to observe |
| clothes_washer_cold | 4-10 mean, peak 15-30 | Already characterized (5/22 23:44 event) |
| fridge_event | 0.1-1.0 | Need to look up Whirlpool/Sub-Zero/etc. manual for dispenser/ice maker flow rate |
| toilet_flush | 1.3-3.0, 1-2 min, 1.4-3 gal | Confirmed (multiple events) |
| pool_autofill | 3.2-3.8 | Confirmed (v2) |
| irrigation_* | ground truth from B-Hyve | Use zone.type from config |

---

## Implementation phases

| Phase | Description | Adds |
|---|---|---|
| **3a** | Miele dishwasher ground truth into a new `dishwasher_cycles` table; same sync pattern as B-Hyve | high-confidence dishwasher attribution |
| **3b** | Build `flume_segment_attributions` (long format, one row per fixture per segment) with probabilistic classifier | base attribution |
| **3c** | Materialize `flume_minute_attributions` (wide format) from segment attributions + Miele + B-Hyve + tankless | the table you want |
| **3d** | Add `flume_user_labels` table + `flume_questionnaire` view + email digest of unlabeled big events | feedback loop |
| **3e** | Backfill the past 30 days (where we have all 3 ground truth sources) and the past ~2 years (B-Hyve only, no hot water context) | populate |

---

## Open questions remaining

1. **Email digest frequency for unlabeled events**: weekly or monthly?
   — **still open** as of 2026-07-27; the digest itself was never built (see the
   status note at the top).
2. **Looking up fridge water flow rate**: I can do this if you tell me
   the make/model. Or I can use a reasonable default (~0.6 GPM ice
   maker, ~0.4 GPM dispenser) and calibrate when we see data.
   — **resolved**: the literature defaults were adopted. `fixtures.py`'s
   `fridge_event` records "dispenser ~0.4 GPM, ice maker ~0.6 GPM (per user decision
   to use literature defaults until refrigerator make/model tells us otherwise)".
3. **Dishwasher water_consumption resets**: cumulative per cycle? Does
   it reset to 0 between cycles, or accumulate forever? (Will check
   when I implement.)
   — **resolved during implementation**: cumulative within a cycle, resets per cycle
   on the Miele. `flume_data/dishwasher.py` takes the per-cycle `max()` of
   `sensor.dishwasher_water_consumption` as the cycle's gallons.
