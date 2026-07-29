# Flume Fixture EDA — Preliminary Findings (2026-05-23)

Initial exploratory analysis to bootstrap the v3 probabilistic fixture
classifier. **Data window: 2026-05-20 → 2026-05-23 (4 days)** — limited
by when the tankless water heater sensor went online (2026-05-19).

The library proposed at the bottom is a starting point; it will be
re-calibrated every ~2 weeks as more data accumulates.

> **Status (2026-07-27):** archival snapshot — every number below is from the 4-day
> 2026-05-20..23 window and has **not** been refreshed. The promised ~2-weekly
> re-calibration has not happened: `scripts/flume-data/flume_data/fixtures.py`, the
> library that actually runs, has not been touched since it was committed on
> 2026-05-23 (`76cc9ba`). Read `fixtures.py` for the live fixture ranges and
> `FLUME_DATA_REFERENCE.md` for the deployed schema; use this document only as the
> record of how those numbers were derived.

---

## Data inventory

| Source | Coverage | Granularity | Notes |
|---|---|---|---|
| `flume_minute_samples` | 2024-02-01 → 2026-05-23 (~840 days) | per-minute | Authoritative whole-house flow |
| `flume_segments` | same | per-event | 39,020 rows, classified by v2 |
| `tankless_minute_samples` | 2026-05-20 → 2026-05-23 (4 days) | per-minute, forward-filled | Hot-water flow from Navien |
| `irrigation_sessions` | 2026-04-23 → 2026-05-23 (30 days) | per-session | B-Hyve valve open/close ground truth |

For the 4 days with full instrumentation, ~210 segments are
characterizable. Most of those are `background` (sub-1 GPM).

---

## Sanity checks

- **Tankless flow during irrigation:** 28.6 gal across 1032 irrigation
  minutes (avg 0.03 GPM). Consistent with brief coincidental indoor
  usage; **irrigation does not draw on the hot water heater** as
  expected. ✓
- **Tankless flow during pool autofill (5/21 10:40, 117 min):** 18.7 gal
  total (avg 0.16 GPM). Same — coincidental indoor use only. ✓
- **Tankless peak GPM observed:** 2.8 GPM. Consistent with a shower
  (no dishwasher or washer-hot pulses exceeded this in the window).

---

## Observed fixture events

Pulling all segments with `gallons >= 2` from the 4-day window
(hot-active segments are starred):

| date | start | dur (min) | mean GPM | peak GPM | gal | hot_gal | hot_frac | likely fixture |
|---|---|---:|---:|---:|---:|---:|---:|---|
| 5/21 | 01:00 | 22 | 3.69 | — | 81 | 6.6 | 0.08 | **irrigation** (B-Hyve confirmed) |
| 5/21 | 02:30 | 41 | 14.55 | — | 596 | 6.3 | 0.01 | **irrigation** (B-Hyve confirmed) |
| 5/21 | 08:00 | 12 | 1.43 | — | 17.2 | 14.6 | 0.85 | ★ **shower** |
| 5/21 | 10:40 | 117 | 3.62 | — | 423 | 18.7 | 0.04 | **pool autofill** (v2 confirmed) |
| 5/21 | 18:54 | 7 | 0.71 | — | 5.0 | 6.6 | 1.32 | ★ sink hot (brief) |
| 5/21 | 19:19 | 8 | 0.74 | — | 5.9 | 7.2 | 1.22 | ★ sink hot (brief) |
| 5/21 | 22:00 | 83 | 8.35 | — | 693 | 13.2 | 0.02 | **irrigation** (B-Hyve confirmed) |
| 5/22 | 06:27 | 7 | 0.37 | — | 2.6 | 9.4 | 3.67 | **dishwasher fill** (cycle 06:31-09:24) |
| 5/22 | 06:51 | 4 | 0.51 | — | 2.0 | 6.2 | 3.05 | **dishwasher fill** (same cycle) |
| 5/22 | 09:29 | 21 | 1.10 | — | 23.1 | 24.2 | 1.05 | ★ **shower (long, possibly 2 simultaneous)** — Miele cycle ended 09:24 |
| 5/22 | 18:06 | 5 | 0.53 | — | 2.6 | 4.4 | 1.68 | ★ sink hot |
| 5/22 | 21:43 | 10 | 1.49 | — | 14.9 | 0.7 | 0.05 | sink cold or fill |
| 5/22 | 23:44 | **48** | **6.41** | **25.66** | **308** | **0.0** | **0.0** | **clothes washer (cold)** ★ peak signature |
| 5/22 | 23:35 | 1 | 1.58 | — | 1.6 | 0.0 | 0.0 | toilet flush |
| 5/22 | 23:27 | 5 | 0.80 | — | 4.0 | 0.6 | 0.15 | sink (mostly cold) |
| 5/20 | 12:57 | 1 | 1.44 | — | 1.4 | 0.0 | 0.0 | toilet flush |
| 5/22 | 06:24 | 1 | 1.38 | — | 1.4 | 0.0 | 0.0 | toilet flush |
| 5/22 | 08:07 | 1 | 1.38 | — | 1.4 | 0.0 | 0.0 | toilet flush |

### Key observations

1. **Toilet flush signature is unmistakable**: 1 minute, mean ~1.4 GPM,
   no hot water, total ~1.4 gal. Four such events seen in 4 days
   (matches typical usage).
2. **Shower signature** (5/21 08:00): 12 min, 1.4 GPM, hot_frac 0.85.
   The 1.4 GPM is **lower than the textbook 2.0-2.5** — suggests a
   low-flow shower head or the user adjusts to <full. Calibrate to
   actual.
3. **Dishwasher signature** (Miele ground truth, 13 cycles in 30 days):
   each cycle runs 2-3 hours wall-clock with 3.7 gal typical (1.6 for
   quick, 5.0 for intensive). The actual *Flume-visible* water is just
   2-3 short fill pulses (e.g., 5/22 06:27 + 06:51 = 4.6 gal across
   11 min). Most of the cycle window is heating/circulation, not new
   water draw. Use Miele `dishwasher_cycles` as ground truth — don't
   try to detect from Flume alone.
4. **Clothes washer (cold)** (5/22 23:44): **distinctive peak signature**
   — 48-min segment with peak 25.66 GPM (washer fill pressure) but
   mean only 6.41. The `peak / mean` ratio (~4x) is the discriminator.
   No hot water — this was a cold cycle. 308 gallons is a single load.
5. **Brief "sink hot" events** with `hot_frac > 1`: indicates
   measurement timing offsets (tankless reports flow throughout a
   minute even if Flume averaged only part of it). Treat as
   "hot-active" without interpreting absolute hot fraction.

### Background events (gallons < 2)

| GPM bucket | Duration | Count | Avg gal | Likely fixture |
|---:|---:|---:|---:|---|
| 0.1-0.2 | 1-4 min | 16 | 0.3 | refrigerator ice maker / dispenser, drip |
| 0.3-0.5 | 1-5 min | 17 | 1.0 | sink brief, fridge fill |
| 0.6-0.9 | 2-5 min | 21 | 2.1 | sink cold, washer pre-fill |

Single-minute events at 1.4-1.6 GPM are toilet flushes (above). The
sub-1 GPM segments are dominated by refrigerator events (the user has
both a dispenser and ice maker — these fire many times per day).

---

## Proposed v3 fixture library (PRELIMINARY — needs re-calibration)

| Fixture | Mean GPM | Peak GPM | Duration | Gallons | Hot frac | Cold-only test | Other |
|---|---:|---:|---:|---:|---:|---|---|
| **irrigation_spray** | 15-28 | 18-30 | 4-8 min | 80-200 | 0 | required | B-Hyve overlap, zone.type=spray |
| **irrigation_drip** | 1.0-3.5 | 1.5-4 | 5-15 min | 8-30 | 0 | required | B-Hyve overlap, zone.type=drip |
| **irrigation_bubbler** | 1.0-3.0 | 1.5-4 | 5-15 min | 8-25 | 0 | required | B-Hyve overlap, zone slug includes planter/dining |
| **pool_autofill** | 3.2-3.8 | 3.5-4.5 | 60-150 min | 200-550 | 0 | required | stddev < 0.6, 85%+ in band, no B-Hyve overlap |
| **shower** | 1.3-2.8 | 1.5-3.0 | 5-15 min | 8-35 | > 0.5 | — | — |
| **dishwasher** | 0.9-1.6 | 1.0-2.0 | 8-25 min | 8-30 | > 0.7 | — | may have multi-cycle |
| **clothes_washer** | 4-10 (incl. pulses) | 15-30 | 25-60 min | 20-50 | 0-0.5 | mostly | peak/mean ratio > 3 |
| **toilet_flush** | 1.3-3.0 | 1.3-3.0 | 1-2 min | 1.3-3.0 | 0 | required | tight signal |
| **sink_cold** | 0.4-2.5 | 0.5-3 | 1-3 min | 0.4-7 | 0 | required | catch-all for cold short events |
| **sink_hot** | 0.4-2.5 | 0.5-3 | 1-3 min | 0.4-7 | > 0.4 | — | hot tap |
| **fridge_event** | 0.1-1.0 | 0.1-1.0 | 1-4 min | 0.1-1.5 | 0 | required | dispenser or ice maker |
| **leak** | 0.05-0.3 | 0.05-0.5 | > 60 min | varies | 0 | required | long-duration low-flow (TBD) |

### Calibration uncertainty

These signatures need re-validation as data accumulates. Specific
unknowns from the 4-day window:

- **Shower**: only one observed (1.4 GPM × 12 min). User mentioned
  weekend is exceptional (more occupants); typical weekday shower
  signature may differ.
- **Clothes washer hot cycle**: not observed in window. May look like
  cold cycle with hot fraction > 0.5.
- **Refrigerator dispenser vs ice maker**: indistinguishable from
  Flume alone at 1-min resolution; treating as one bucket `fridge_event`.

---

## Proposed classifier design (v3)

### Schema

```sql
CREATE TABLE flume_segment_attributions (
    segment_date  DATE          NOT NULL,
    segment_start TIME          NOT NULL,
    fixture       TEXT          NOT NULL,
    probability   NUMERIC(4,3)  NOT NULL CHECK (probability BETWEEN 0 AND 1),
    gallons       NUMERIC(10,3) NOT NULL,   -- = segment.gallons * probability
    computed_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (segment_date, segment_start, fixture),
    FOREIGN KEY (segment_date, segment_start)
        REFERENCES flume_segments (date, start_time)
);
```

Multiple rows per segment, probabilities sum to 1.0, gallons distributed
proportionally. Queryable like:

```sql
SELECT fixture, SUM(gallons) AS attributed_gal
FROM flume_segment_attributions
WHERE segment_date >= '2026-05-01'
GROUP BY fixture
ORDER BY 2 DESC;
```

### Likelihood scoring

For each segment, the classifier computes a score per fixture from the
library:

```
score(fixture | segment) =
    L_mean(segment.mean_gpm, fixture.mean_gpm_range)
  × L_dur (segment.duration_min, fixture.duration_range)
  × L_gal (segment.gallons, fixture.gallons_range)
  × L_hot (segment.hot_frac, fixture.hot_frac_range)
  × L_peak(segment.peak_gpm/segment.mean_gpm, fixture.peak_ratio)
  × L_ctx (B-Hyve overlap, etc.)
```

Each `L_*` is a triangular distribution centered on the range midpoint
that goes to 0 outside the range. Probabilities are then computed as
`P(fixture | segment) = score(f) / sum(score(f') for all f')`.

> **As built:** the triangular kernel was replaced by a **Gaussian** one before
> shipping — `fixtures.Range.likelihood()` uses `sigma = (high - low) / 4`, so values
> inside the range score ≥ 0.135 and the score decays smoothly outside it rather than
> hitting zero at the edge. The probability normalisation is as described.

Hard constraints (cold-only, B-Hyve overlap) zero out the score
entirely. This means a segment with hot water can never be classified
as `irrigation_*` or `pool_autofill` or `toilet_flush`.

### Iteration plan

Every 2 weeks (manual or on a timer):
1. Pull segments where the top-probability classification has
   confidence < 0.7 (the ambiguous ones)
2. Surface them in a Grafana panel for spot-checking
3. Adjust the fixture library YAML based on patterns
4. Re-backfill `flume_segment_attributions`

---

## Open questions for the user

1. **Shower GPM**: Is your shower head low-flow (~1.5 GPM) or standard
   (~2.0-2.5)? The 5/21 08:00 sample looked low-flow; want to confirm
   before locking the signature.
2. **Multiple showers simultaneously**: Do you ever run two showers at
   once? If yes, the simultaneous-event problem becomes harder.
3. **Dishwasher cycle structure**: Does your dishwasher do multiple
   short fills (5-7 min each) or one long fill (20+ min)? The 5/22
   event looked like one long fill — atypical for most dishwashers.
4. **Washer hot cycles**: How often do you run hot/warm vs cold? Will
   determine if we need a separate `clothes_washer_hot` fixture.
5. **Refrigerator water usage**: Roughly how many ice maker fills per
   day? Helps us validate the "fridge_event" count target.
