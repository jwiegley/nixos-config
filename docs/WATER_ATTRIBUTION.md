# Water Attribution

Track each gallon Flume measures into categories — pool autofill, per-zone
irrigation, hot-water domestic, and residual "other" — with daily, weekly,
and monthly totals in HA's Energy dashboard and Grafana.

## Sensors created

### Detection state
- `binary_sensor.flume_gpm_in_autofill_range` — true when current GPM ∈ [3, 5]
- `binary_sensor.pool_autofill_active` — true when ≥ 9 of last 10 min in range AND rolling mean in [3, 5]
- `sensor.flume_minutes_in_autofill_range_10m` — rolling count (history_stats)
- `sensor.flume_gpm_10m_mean` — rolling mean (statistics platform)

### Cumulative gallons (monotonic, `state_class: total_increasing`)
- `sensor.water_pool_autofill_total`
- `sensor.water_<zone>_total` (one per B-Hyve zone)
- `sensor.water_irrigation_total` (aggregate sum of zones)
- `sensor.water_domestic_hot_total` (NaviLink-derived)
- `sensor.water_other_total` (residual)

### Cycles (`state_class: total`, reset at cycle boundary)
- `sensor.water_<source>_daily` / `_weekly` / `_monthly`

## What "other" includes

"Other" is the residual after subtracting autofill, per-zone irrigation, and
domestic hot water from Flume's total. It captures:

- Cold-water indoor use (toilets, cold taps, washing-machine cold cycles, ice
  maker) — NaviLink only measures hot water
- Outdoor non-irrigation/non-pool (hose use, outdoor faucets, drip-line leaks
  downstream of B-Hyve valves)
- Measurement noise / timing slop

A leak alert based on `sensor.water_other_daily` is a good v2 addition.

## Adding or splitting a zone

Edit `services.home-assistant-water-attribution.zones` in `configuration.nix`:

```nix
zones = [
  { slug = "front_yard"; name = "Front Yard"; type = "spray"; }
  # ... add new entry here, or split front_yard into front_yard_north / _south ...
];
```

Then `sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'`. HA reloads
automatically via `restartTriggers`.

## Tuning autofill detection

```nix
services.home-assistant-water-attribution.autofill = {
  gpmMin = 3.0;
  gpmMax = 5.0;
  windowMinutes = 10;
  minMinutesInRange = 9;
  enforceMeanCheck = true;
};
```

## Weekly report email

Arrives Monday ~03:30 local. Subject: `[vulcan] Weekly water report — DATE → DATE`.

Includes:
- This-week-vs-last-week totals per category
- Per-zone irrigation breakdown
- Daily breakdown
- Notable observations
- Cross-check anomaly section (only when delta > tolerance)

Tolerance defaults: 5 gal absolute, 3% relative. Tune via
`services.flume-autofill.deltaToleranceGal` / `deltaTolerancePct`.

## Historical backfill

Discover what's available:

    sudo -u flume-autofill /run/current-system/sw/bin/python -m flume_autofill backfill --discover

Backfill a year:

    sudo systemctl start 'flume-autofill-backfill@2024.service'

Backfill a specific day (e.g., from a Phase 2 anomaly email):

    sudo systemctl start 'flume-autofill-backfill@2026-05-18.service'

Once values look correct in HA's Statistics tab and Grafana, promote into the
live LTS namespace:

    flume-autofill backfill --promote --through 2026-05-21

Rollback:

    flume-autofill backfill --unpromote --through 2026-05-21

## v1 backfill scope and limitations

**Backfill v1 reconstructs `pool_autofill` totals only.** Per-zone irrigation
totals during the backfill window are NOT reconstructed in v1 — the algorithm
would need to integrate valve open/close intervals from VictoriaMetrics against
the gated Flume GPM, mirroring Phase 1's per-zone YAML logic in Python. This
is in scope for a v2 backfill update.

**What this means for the user:**

- The Energy dashboard, Grafana, and HA Statistics tab show historical
  pool_autofill values immediately after Phase 3 + `--promote`.
- Historical per-zone irrigation values remain at zero (the zones did receive
  water in the past, but our backfill doesn't yet attribute it).
- "Live forward" — i.e., from the moment Phase 1 was deployed onward — every
  per-zone value is tracked correctly. Only the pre-deployment history is
  missing per-zone detail.

If you need historical per-zone data: the raw minute resolution is preserved
in VictoriaMetrics (100-year retention), so the algorithm can be added later
without losing any source data.
