# Water Attribution

Track each gallon Flume measures into categories — pool autofill, per-zone
irrigation, hot-water domestic, and residual "other" — with daily, weekly,
and monthly totals in HA's Energy dashboard and Grafana.

## Sensors created

### Detection state

Entity names and thresholds below reflect the **live** band as of 2026-07-27.
The `_<N>m` suffix is derived from `autofill.windowMinutes`, so it changes if
you retune the window (see *Tuning autofill detection*).

- `binary_sensor.flume_gpm_in_autofill_range` — true when current GPM ∈ [1.3, 1.9]
- `binary_sensor.pool_autofill_active` — true when ≥ 4 of last 5 min in range
  AND rolling mean in [1.3, 1.9] AND `binary_sensor.irrigation_active` is not
  `on` AND the domestic hot leg is < 0.1 gpm (the irrigation/hot guards added
  with the low-flow band)
- `sensor.flume_minutes_in_autofill_range_5m` — rolling count (history_stats)
- `sensor.flume_gpm_5m_mean` — rolling mean (statistics platform)

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

Edit `services.home-assistant-water-attribution.zones` in
`hosts/vulcan/default.nix` (there is no `configuration.nix` in this repo):

```nix
zones = [
  { slug = "front_yard"; name = "Front Yard"; type = "spray"; }
  # ... add new entry here, or split front_yard into front_yard_north / _south ...
];
```

Then `sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'`. HA reloads
automatically via `restartTriggers`.

## Tuning autofill detection

Live values in `hosts/vulcan/default.nix` as of 2026-07-27 (the auto-fill valve
was replaced 2026-05-26 and now does short 2–9 min top-offs at 1.3–1.9 gpm
instead of the old valve's long 3–5 gpm fills — see the rationale comment above
the block in that file). The module's own `mkOption` defaults are still the old
`3.0 / 5.0 / 10 / 9`:

```nix
services.home-assistant-water-attribution.autofill = {
  gpmMin = 1.3;
  gpmMax = 1.9;
  windowMinutes = 5;
  minMinutesInRange = 4;
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
`services.flume-data.deltaToleranceGal` / `deltaTolerancePct`.

## Historical backfill

> **There is no `flume-data` executable on PATH** (verified 2026-07-27). The
> argparse `prog` name is `flume-data`, but nothing installs a wrapper — the
> code is only ever run as `python -m flume_data` from the units in
> `modules/services/flume-data.nix`, which supply `PYTHONPATH`,
> `FLUME_AUTOFILL_CONFIG` and the Python env that actually has `requests` /
> `psycopg2` / `websocket-client`. The stock `/run/current-system/sw/bin/python`
> has none of those.

Discover what's available (read-only, safe to run ad hoc — borrow the
interpreter from the deployed unit so you never hardcode a store path):

    PYENV=$(systemctl cat 'flume-data-backfill@.service' \
              | sed -n 's|^ExecStart=\(/nix/store/[^ ]*\)/bin/python .*|\1|p')
    sudo -u flume-data env \
        PYTHONPATH=/etc/nixos/scripts/flume-data \
        FLUME_AUTOFILL_CONFIG=/var/lib/flume-data/zones.json \
        "$PYENV/bin/python" -m flume_data backfill --discover

Backfill a year:

    sudo systemctl start 'flume-data-backfill@2024.service'

Backfill a specific day (e.g., from a Phase 2 anomaly email):

    sudo systemctl start 'flume-data-backfill@2026-05-18.service'

Once values look correct in HA's Statistics tab and Grafana, promote into the
live LTS namespace:

    ... -m flume_data backfill --promote --through 2026-05-21

Rollback:

    ... -m flume_data backfill --unpromote --through 2026-05-21

Unlike `--discover`, both of these write to Home Assistant over its WebSocket
API and read the HA token from `$CREDENTIALS_DIRECTORY/ha_token`
(`flume_data/backfill.py:343,386,469`). They therefore have to run under systemd
with the same `LoadCredential=` set as `flume-data-backfill@.service` — a bare
shell invocation raises `KeyError: 'CREDENTIALS_DIRECTORY'`. Note also that
`--unpromote` ignores `--through`: HA's `recorder/clear_statistics` is not
range-filtered, so it wipes the whole backfilled namespace.

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
