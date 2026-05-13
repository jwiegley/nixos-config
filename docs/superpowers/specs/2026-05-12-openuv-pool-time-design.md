# OpenUV pool-time prediction — design

**Date:** 2026-05-12
**Status:** brainstorming (pending review)
**Driver:** The OpenUV integration polls `/uv` only, never `/forecast`. The user wants a once-per-day forecast pull whose hourly array drives both (a) a sunrise daily summary of the day's predicted "pool window," and (b) a scheduled event at the moment UV will descend through 3 — gated against pool water temperature ≥ 82 °F — that triggers a TTS "pool time" announcement.

## 1. Goal

Convert OpenUV's once-daily hourly UV forecast into two Node-RED events on `vulcan`:

1. **Sunrise summary** (08:00 local, or immediately if the forecast lands after 08:00): TTS announces the predicted pool-window start time and sunset.
2. **Pool-time trigger**: At the predicted moment UV descends through 3, read the IntelliCenter pool-water-temp sensor; if ≥ 82 °F, fire a TTS announcement.

Total API budget: one `/forecast` call per day. The existing HA `openuv` integration continues to handle current-UV via `/uv` independently.

## 2. Non-goals

- **No curve fitting.** Hourly forecast resolution plus linear interpolation between adjacent samples gives sub-minute precision on the descending UV=3 crossing — indistinguishable from a parabolic least-squares fit at the human-perception timescale of a voice alert. Ruled out during brainstorming.
- **No sunset-proximity cutoff.** User explicitly chose to fire the trigger even on short windows.
- **No predictive pool-temp.** Pool temperature is read live from the IntelliCenter sensor at trigger fire-time; we do not attempt to forecast it.
- **No replacement of HA's `openuv` integration polling.** The current-UV side of OpenUV stays as it is.
- **No new HA custom component.** Only stock `rest:` sensor, stock `automation`, and Node-RED.

## 3. Health & success criteria

- The `sensor.openuv_forecast` entity transitions from `unknown` → numeric (the day's predicted peak UV) once daily.
- Its `result` attribute is a non-empty array of `{uv, uv_time}` records.
- On a clear day (peak UV ≥ 4), the sunrise summary fires exactly once at 08:00 local, naming a `crossing_time` between 14:00 and sunset.
- The pool-time trigger fires within ±2 minutes of the linearly-interpolated `crossing_time`.
- On an overcast / low-UV day where the forecast's peak never exceeds 3, the summary instead announces "no pool window today" and the trigger does not fire.
- One API request per day; OpenUV free-tier quota remains ≥ 49/50.

## 4. Component overview

```
┌─────────────────────────── vulcan host ────────────────────────────────┐
│                                                                        │
│  SOPS  (/etc/nixos/secrets/secrets.yaml)                               │
│    └── home-assistant/openuv-api-key  ──► /run/secrets/...             │
│                                                                        │
│  home-assistant.service (preStart)                                     │
│    └── reads /run/secrets/.../openuv-api-key                           │
│        └── appends `openuv_api_key: <value>` to                        │
│            /var/lib/hass/secrets.yaml  (mode 600, hass:hass)           │
│                                                                        │
│  Home Assistant                                                        │
│    ┌── rest: sensor                                                    │
│    │     resource:  https://api.openuv.io/api/v1/forecast              │
│    │     params:    lat=!secret latitude  lng=!secret longitude        │
│    │     headers:   x-access-token: !secret openuv_api_key             │
│    │     scan_interval: 86400                                          │
│    │     value_template: day's peak UV  (rounded 0.1)                  │
│    │     json_attributes: [result]                                     │
│    │     →  sensor.openuv_forecast                                     │
│    │                                                                   │
│    ├── automation: "OpenUV daily forecast refresh"                     │
│    │     trigger: time 05:00 local                                     │
│    │     action:  homeassistant.update_entity sensor.openuv_forecast   │
│    │                                                                   │
│    └── existing tts.cloud_say + media_player.vlc_telnet (S106 stack)   │
│                                                                        │
│  Node-RED                       ┌─ tab: "Pool Time" (NEW)              │
│    └── flow ─────────────────►  │  events:state listener               │
│                                 │    entity: sensor.openuv_forecast    │
│                                 │       ↓                              │
│                                 │  function "compute window"           │
│                                 │    — linear-interp descending UV=3   │
│                                 │    — read sun.sun.next_setting       │
│                                 │       ↓ (split)                      │
│                                 │  ┌────────────┬────────────────┐     │
│                                 │  ↓            ↓                ↓     │
│                                 │ branch A   branch B           debug   │
│                                 │ summary    scheduled trigger          │
│                                 │ at 08:00   at crossing_time           │
│                                 │   ↓          ↓                        │
│                                 │ TTS       get pool-temp               │
│                                 │           switch ≥ 82 °F              │
│                                 │             ↓ yes                     │
│                                 │           TTS                         │
│                                 └────────────────────────────────────  │
└────────────────────────────────────────────────────────────────────────┘
```

## 5. SOPS secret wiring

The key `home-assistant/openuv-api-key` is already added to `/etc/nixos/secrets/secrets.yaml` by the user.

**New declaration in `modules/services/home-assistant.nix`** (alongside the existing `home-assistant/*` sops blocks around line 173–232), matching the yale/opnsense pattern exactly:

```nix
sops.secrets."home-assistant/openuv-api-key" = {
  owner = "hass";
  group = "hass";
  mode = "0400";
  restartUnits = [ "home-assistant.service" ];
};
```

`sopsFile` is omitted to inherit the global sops configuration — same as every neighboring `home-assistant/*` declaration. `restartUnits` is included so rotating the key triggers an HA restart that re-runs `preStart` and refreshes `/var/lib/hass/secrets.yaml`.

**In the existing HA `preStart` block** (around line 911, where `secrets.yaml` is generated), append a conditional that mirrors the postgres-password pattern:

```bash
if [ -f ${config.sops.secrets."home-assistant/openuv-api-key".path} ]; then
  OPENUV_API_KEY=$(cat ${config.sops.secrets."home-assistant/openuv-api-key".path})
  echo "openuv_api_key: $OPENUV_API_KEY" >> /var/lib/hass/secrets.yaml
fi
```

The chmod 600 already applied at line 925 covers the appended line.

**Why duplicate-store the key (already in the openuv integration UI):** HA integrations seal their config_entries to themselves. A YAML `rest:` sensor is a different subsystem and cannot reach into the openuv integration's storage. The same secret value lives in two HA subsystems — this is by design and is the cost of using a generic REST sensor for `/forecast`.

## 6. HA REST sensor

Add to the YAML `config` block in `home-assistant.nix` (near other YAML-config integrations, e.g. after `homeassistant` block around line 480–520):

```yaml
rest:
  - scan_interval: 86400
    resource: "https://api.openuv.io/api/v1/forecast"
    params:
      lat: !secret latitude
      lng: !secret longitude
    headers:
      x-access-token: !secret openuv_api_key
    sensor:
      - name: "OpenUV Forecast"
        unique_id: openuv_forecast
        value_template: >-
          {{ value_json.result | map(attribute='uv') | max | round(1) }}
        json_attributes:
          - result
```

Notes:

- `scan_interval: 86400` prevents accidental polling drift; the HA refresh automation below is the actual trigger.
- `value_template` exposes the day's peak UV as the sensor state — a useful glanceable value and a stable signal for Node-RED's state-change listener (the state changes daily even if the array contents barely moved).
- `json_attributes: [result]` exposes the full hourly array on `attributes.result`.

## 7. HA refresh automation

Add to the existing `automation` block:

```yaml
- alias: "OpenUV: refresh forecast at 05:00"
  id: openuv_forecast_refresh
  trigger:
    - platform: time
      at: "05:00:00"
  action:
    - service: homeassistant.update_entity
      target:
        entity_id: sensor.openuv_forecast
```

05:00 local is chosen so the forecast is fresh well before the 08:00 summary fires, with margin for retries on transient OpenUV outages.

## 8. Node-RED flow — tab "Pool Time"

### 8.1 Nodes

1. **`events: state`** — `entity_id: sensor.openuv_forecast`, output on state-changed (not initial-load), to avoid double-firing on Node-RED restart.
2. **`function` "compute window"** — see 8.2.
3. **`switch` "window exists"** — branch on `msg.payload.crossing_time` being non-null.
   - If null (no descending UV=3 crossing → low-UV day), route to a single TTS branch with "no pool window today".
   - If non-null, route to both branches A and B.
4. **Branch A — Sunrise summary**
   - `function` "format summary text" → renders `"Today's pool window will be from HH:MM until sunset at HH:MM."`
   - `cron / time switch` "wait until 08:00 local" — if the forecast lands *after* 08:00, dispatch immediately; otherwise hold until 08:00.
   - `call service` — `tts.cloud_say` with the configured media_player(s).
5. **Branch B — Scheduled trigger**
   - **Scheduler node — see caveat.** Stock `delay` node accepts dynamic ms delays but has known reliability issues for multi-hour holds (timer drift, restart loss with no rehydration). Prefer the `trigger` node in "send-then-wait" mode with a dynamic `msg.delay`, or — if `node-red-contrib-cron-plus` is already in the palette — its dynamic-schedule mode, which persists the schedule across Node-RED restart. Pin the choice during implementation; fall back to stock `delay` only if neither alternative is available.
   - `current state` — read pool-temp entity (TBD: probably `sensor.<intellicenter>_water_temp`; pin during implementation by querying `screenlogic` integration entities).
   - `switch` "≥ 82 °F" → yes path proceeds, no path emits a debug breadcrumb and stops.
   - `function` "format trigger text" → `"Pool time. UV has dropped, water is XX degrees."`
   - `call service` — `tts.cloud_say`.

### 8.2 `compute window` function logic

```javascript
const fc = msg.data.event.new_state.attributes.result;
if (!Array.isArray(fc) || fc.length < 2) {
    node.warn("OpenUV forecast missing or too short");
    return [null, null];
}

const THRESHOLD = 3.0;
const now = Date.now();

// 1. Find peak time/value
let peakUV = -Infinity, peakIdx = -1;
for (let i = 0; i < fc.length; i++) {
    if (fc[i].uv > peakUV) { peakUV = fc[i].uv; peakIdx = i; }
}

// 2. Scan from peak forward for descending UV=3 crossing
let crossingMs = null;
for (let i = peakIdx; i < fc.length - 1; i++) {
    const u0 = fc[i].uv, u1 = fc[i + 1].uv;
    if (u0 >= THRESHOLD && u1 < THRESHOLD) {
        const t0 = Date.parse(fc[i].uv_time);
        const t1 = Date.parse(fc[i + 1].uv_time);
        const frac = (u0 - THRESHOLD) / (u0 - u1);  // safe: u0 > u1 here
        crossingMs = t0 + frac * (t1 - t0);
        break;
    }
}

// 3. Read sun.sun.next_setting from global context (populated by a sibling
//    state listener) OR look it up via an `api-current-state` node upstream.
const sunset = global.get("sun_next_setting") || null;

msg.payload = {
    crossing_time: crossingMs ? new Date(crossingMs).toISOString() : null,
    crossing_in_ms: crossingMs ? Math.max(0, crossingMs - now) : null,
    peak_uv: Number(peakUV.toFixed(1)),
    sunset: sunset,
};
return msg;
```

Linear interpolation rationale: OpenUV documents that the descending leg of the UV curve is monotonic past peak, so the first `u0 ≥ THRESHOLD > u1` flip is the unique crossing. Linear interp over a one-hour interval where UV changes by ≤ 1 unit gives crossing-time error bounded by the curvature × interval² / 8 ≈ 30 seconds for an inverted parabola peaking at 8 — well below voice-alert audibility.

### 8.3 Sunset lookup

Two acceptable patterns; pick one during implementation:

- **Global context** — a small companion flow listens for `sun.sun` state changes and writes `next_setting` to `global.sun_next_setting`.
- **Inline** — replace the global lookup with an `api-current-state` node fed into a function that merges `crossing_time` with the sunset value.

Either works; the global-context form keeps the main function pure.

## 9. Edge cases & error handling

| Condition | Behavior |
|---|---|
| OpenUV API 5xx or network fail at 05:00 refresh | `sensor.openuv_forecast` goes `unavailable`. State-changed listener fires with `new_state = null`; function returns early; no TTS. Next day's 05:00 refresh retries. |
| OpenUV API 403 (bad/expired key) | Same as above. Manual fix path: rotate key in SOPS, rebuild. |
| Forecast array present but UV never reaches 3 (winter, heavy overcast) | `peakIdx` set but no descending crossing found. `crossing_time = null`. Sunrise summary instead says "no pool window today, peak UV X.X". Trigger does not schedule. |
| Forecast loads after 08:00 (HA restarted late, or refresh delayed) | Branch A's "wait until 08:00" detects the missed window and dispatches immediately. Branch B still schedules normally. |
| Forecast says UV=3 crossing is already in the past at load time | `crossing_in_ms` clamped to 0. Branch B's `delay` fires immediately; pool-temp gate still evaluated. Acceptable behavior: a late forecast still announces "pool time now" if conditions are met. |
| Pool-temp sensor unavailable / unknown at trigger fire-time | `switch` ≥ 82 °F evaluates false; trigger silently skips. Logged via debug node. (Don't announce on stale data.) |
| Node-RED restart mid-day | All scheduled delays are lost. On next forecast state-change (next morning), normal flow resumes. To recover same-day, the user manually calls `homeassistant.update_entity` for the sensor; the listener re-fires and re-schedules. |
| HA restart mid-day | REST sensor state persists across restart (HA reloads from recorder). State-changed listener does NOT re-fire on restart, so branch B's schedule is preserved if Node-RED stayed up. If both restarted: see previous row. |
| OpenUV quota exhausted | Refresh returns 429. Sensor `unavailable`. Same recovery as 5xx. Quota resets next UTC day. |
| Sunrise summary fires but pool temp will be cold all day | Out of scope. Summary is informational and does not gate on temp; the trigger branch B does. User can extend later if desired. |

## 10. Testing

### 10.1 Unit-ish (function node)

The `compute window` function is pure JavaScript with no Node-RED-specific I/O — paste it into a Node.js REPL with a captured `msg` payload and verify outputs against three hand-crafted fixtures:

- **Clear summer day** — peak UV 9 at noon, descending past 3 at ~17:30. Expect `crossing_time ≈ 17:30 ±5min`.
- **Overcast day** — peak UV 2.5 everywhere. Expect `crossing_time = null`.
- **Edge-of-window day** — peak UV 4 at noon, crosses 3 at ~14:00, then dips below 3 and re-emerges. Expect first descending crossing past peak (around 14:00).

### 10.2 Integration

1. Apply the NixOS change. Verify `/var/lib/hass/secrets.yaml` contains `openuv_api_key:` line (do not display its value).
2. In HA dev-tools, call `homeassistant.update_entity sensor.openuv_forecast`. Confirm state is a number and `attributes.result` is a non-empty array.
3. In Node-RED, confirm the state-change listener fires; the function debug shows `crossing_time` matching a hand calculation from the API JSON.
4. **Manual fast-forward**: in Node-RED debug, override the `crossing_in_ms` to 5 seconds via a temporary inject. Confirm branch B fires, pool-temp gate evaluates correctly, TTS plays. (Wire the temp gate to false first to confirm silent-skip; then to true to confirm announcement.)
5. **Low-UV simulation**: in HA dev-tools "Set state," replace `attributes.result` with an array whose all `uv` values are below 3. Re-fire by calling `homeassistant.update_entity`. Confirm Branch A's no-window summary plays and Branch B does not schedule.

### 10.3 Long-run observation

Watch the first three days of natural firings:

- Day 1: confirm 05:00 refresh updates the sensor (check `last_updated` attribute via dev-tools).
- Day 1: confirm 08:00 summary plays once.
- Day 1: confirm pool-time trigger plays within ±2 min of the predicted crossing.
- Day 2–3: confirm no double-fires, no leak of the previous day's schedule into the new day.

## 11. Implementation order

1. `sops.secrets."home-assistant/openuv-api-key"` declaration → rebuild → verify `/run/secrets/home-assistant/openuv-api-key` exists with `hass:hass 0400`.
2. preStart append → rebuild → verify `/var/lib/hass/secrets.yaml` contains `openuv_api_key:` line (without displaying the value).
3. `rest:` sensor definition → rebuild → verify `sensor.openuv_forecast` appears in HA with non-empty `result` attribute.
4. HA refresh automation → reload automations → verify next 05:00 fires `update_entity` (or fast-forward via dev-tools).
5. Pin the pool-temp entity name. Inspect `screenlogic`/IntelliCenter entities in HA, pick the water-temp one.
6. Node-RED flow — build tab in roughly the order: function + debug first (validate parsing), then branch B with manual fast-forward, then branch A with manual fire, then schedule glue.
7. S106 cleanup. S106 was design-only — `grep -c openuv /var/lib/node-red/flows.json` returned 0 at spec time. Before declaring this feature done, also verify no S106 residue remains in HA YAML (no `automation:` block, no `script:` block, no `input_*:` helper referencing `openuv`/`pool_time`). If anything appears, list it and decide whether to remove or supersede.

## 12. Risks & open questions

- **Pool-temp entity name TBD** — will be pinned during implementation. If the `screenlogic` integration uses a non-obvious name like `sensor.pool_temperature` or `sensor.intellicenter_water_temp`, the flow's `current state` node entity ID must match. Recoverable by edit; no risk to other components.
- **TTS service choice** — `tts.cloud_say` (HA Cloud) vs `tts.google_translate_say` vs local. The S106 design defaulted to `tts.cloud_say` with `media_player.vlc_telnet`; this design follows. If the user has since changed their TTS stack, the `call service` nodes need updating.
- **Forecast endpoint stability** — OpenUV's `/forecast` shape is stable per their docs; a field rename would break the function node. Mitigated by: function emits an explicit warning on missing `result`.
- **OpenUV quota** — 50/day free tier. Current HA integration's `/uv` polling at 30-min intervals already burns ~48/day. Adding 1 forecast pull at 05:00 brings us to ~49/50 — uncomfortably close but within budget. If the integration ever bumps to 15-min polling we'd blow the quota. Note for future maintenance: if quota becomes a concern, increase the openuv integration's `update_interval` to 60 min (saves ~24 calls/day).
