# Climate Comfort — adaptive HVAC setpoint blend

> **Archival — 2026-05-14.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.

**Status:** Approved 2026-05-14
**Author:** John Wiegley (with Claude design assistance)

## Goal

Drive setpoints for the six HVAC zones (1 Nest upstairs + 5 Mitsubishi mini-splits downstairs) from a single ASHRAE 55–derived blend formula that reacts to the 7-day prevailing outdoor temperature, nudged slightly toward each zone's current room temperature. Replace the ad-hoc per-tab setpoint calls (`upstairs heat_cool 78-82`, `tv_room set 78 heat`, etc.) with a unified comfort model.

## Topology

| Layer | Entity | Notes |
|---|---|---|
| Upstairs unit | `climate.upstairs` (Nest) | Reads a dedicated office remote sensor |
| Downstairs mini-splits (×5) | `climate.living_room`, `climate.home_office`, `climate.guest_bedroom`, `climate.master_bedroom`, `climate.tv_room` | Mitsubishi MELView/Comfort, each its own controlled volume |
| Outdoor temp | `weather.kmhr` attribute `temperature` | NWS Mather Airport |

Each zone is computed independently and treated identically — no "unit-level" grouping.

## Core formula

Per zone, every 15 minutes:

```
anchor_C  = 0.31 * (T_out_7d_F - 32) * 5/9 + 17.8       # ASHRAE 55 adaptive
anchor_F  = clamp(anchor_C * 9/5 + 32,   68, 78)        # residential safety
nudge     = clamp(T_zone_now - anchor_F, -2, 2) * 0.3   # bias toward room state
setpoint  = round(anchor_F + nudge, 0.5)
```

The `0.3` nudge weight is intentionally low so the formula does not lock onto a stale or extreme zone reading. The 68–78 °F clamp keeps residential safety bounds even in extreme weather.

## Mode + band selection

| `T_out_7d` (°F) | `hvac_mode` | `target_temp_low` | `target_temp_high` |
|---|---|---|---|
| `< 55`         | `heat`      | `setpoint − 1`    | `setpoint + 5`     |
| `55 – 70`      | `heat_cool` | `setpoint − 2`    | `setpoint + 2`     |
| `> 70`         | `cool`      | `setpoint − 5`    | `setpoint + 1`     |

Asymmetric bands in one-sided modes reduce cycling: in heating season the room may drift up 5 °F before any action is taken (cooling never engages); mirror in cooling season.

## Bootstrap

The 7-day rolling buffer (672 samples at 15-min cadence) is stored in flow context, which on this host **persists to `/var/lib/node-red/context/<tab-id>/flow.json` automatically** (default `localfilesystem` store with 30 s flush). The buffer survives Node-RED restarts, NixOS rebuilds, and deploys.

On first deploy (or if the file is deleted), `mean_7d` is the simple mean of whatever samples exist — day-1 behavior tracks current readings; smoothing emerges over the week.

## Per-zone enablement

A zone is skipped if `hvac_mode == "off"` at compute time. No separate toggle helper. To pause the blend for a zone, set the zone off in HA / the Mitsubishi app.

## Write-throttling

A new setpoint is only written when `|new - current| ≥ 1 °F` *or* the mode would change. Avoids Nest/Mitsubishi spam and saves their cloud quotas.

## Annual visibility

Three derived values are published to HA each compute cycle:
- `input_number.outdoor_7d_mean` — the running mean in °F
- `input_number.comfort_anchor` — `anchor_F` (pre-nudge)
- `input_text.comfort_season` — one of `heat`, `shoulder`, `cool`

These show up on a Lovelace card or Grafana panel for at-a-glance "what mode is the house in." User must create the three `input_number` / `input_text` helpers in HA before deployment; flow will warn-and-skip if absent.

For Sacramento's climate, the season classification typically maps to:
- **heat**: Dec → late-Feb
- **shoulder**: Mar–early May, mid-Oct → late-Nov
- **cool**: mid-May → early-Oct

The classification is data-driven, not calendar-driven, so cold/heat anomalies are handled automatically.

## Flow architecture — "Climate Comfort" tab

Five vertical bands, top to bottom:

1. **Zone state stash** — 6 × `server-state-changed` (one per climate entity) → 1 × function that writes `{ current_temperature, hvac_mode, target_temp_low/high, target_temperature }` to `flow.context.zoneState[<entity_id>]`.
2. **Outdoor sample + 7-day mean** — `chronos-scheduler` every 15 min → `api-current-state weather.kmhr` (reads `temperature` attribute) → function that maintains a circular buffer in `flow.context.outdoorBuffer` and emits `{current, mean_7d, sample_count}`.
3. **Compute setpoints** — function reads stashed zone state + the band-2 output, emits one `msg` per *enabled* zone with `{entity_id, mode, low, high, setpoint, write_needed}`.
4. **Diff gate + HA write** — switch (`write_needed === true`) → single `api-call-service climate.set_temperature` with JSONata data including `entity_id`. Per-zone routing flows through `msg.payload.entity_id`.
5. **Status publish** — same compute function also emits a second `msg` per cycle to update the three HA helpers via `input_number.set_value` / `input_text.set_value`.

## Tunable constants

All at the top of the compute function:

| Constant | Default | Meaning |
|---|---|---|
| `SLOPE` | 0.31 | ASHRAE 55 adaptive coefficient |
| `OFFSET_C` | 17.8 | Anchor in °C when outdoor mean = 0 °C |
| `CLAMP_LOW_F` / `CLAMP_HIGH_F` | 68 / 78 | Residential bounds |
| `NUDGE_WEIGHT` | 0.3 | Room-temp pull strength (0 = pure formula, 1 = average) |
| `NUDGE_MAX` | 2 | Cap on raw nudge before weighting (°F) |
| `HEAT_THRESH` / `COOL_THRESH` | 55 / 70 | Outdoor 7-day mean → mode boundaries (°F) |
| `HEAT_BAND_LOW` / `HEAT_BAND_HIGH` | -1 / +5 | Asymmetric band offsets, heat mode |
| `COOL_BAND_LOW` / `COOL_BAND_HIGH` | -5 / +1 | Asymmetric band offsets, cool mode |
| `MID_BAND` | 2 | Symmetric half-width in shoulder mode |
| `MIN_WRITE_DELTA` | 1 | Skip writes below this °F threshold |

## Non-goals (v1)

- Humidity correction (Sacramento is dry; marginal benefit)
- Per-zone slope tuning (uniform formula; revisit if a zone consistently misses)
- Occupancy gating (still belongs to existing Office / Away tabs)
- Sleep / overnight setback (separate concern — Office tab already does eco-mode handoff)
- Manual override UI (rely on HA app: set zone to `off` to pause blend)

## Risks / failure modes

- **weather.kmhr unavailable** — function should treat missing reading as "skip this sample, use prior mean".
- **Buffer reset on Node-RED restart** — accepted; rebootstraps over 7 days. Could persist later if user wants.
- **Mitsubishi mini-split rate limits** — the 1 °F delta gate keeps writes low; expect ≤ 10 per zone per day.
- **HA helpers not yet created** — flow warns once per cycle, does not crash.

## Acceptance test

- Deploy with all 6 zones in `heat` or `cool` mode (not `heat_cool`).
- After 15 minutes, observe `nodered_events` shows `compute setpoints` `onSend` fires for enabled zones.
- After 30 minutes, observe one or more `climate.set_temperature` `onSend` if any zone's existing setpoint differs from new by ≥ 1 °F.
- Verify that turning a zone `off` in HA suppresses its writes on the next cycle.
- After 7 days, `sensor.outdoor_7d_mean` shows a stable rolling average vs current outdoor temp.
