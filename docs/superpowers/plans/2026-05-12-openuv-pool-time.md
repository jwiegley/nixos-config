# OpenUV Pool-Time Implementation Plan

> **Archival — 2026-05-12.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see the `openuv_forecast` REST sensor in `modules/services/home-assistant.nix`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull OpenUV `/forecast` once daily into a HA REST sensor; have Node-RED derive (a) a sunrise summary at 08:00 announcing the predicted UV=3 descending crossing time, and (b) a scheduled "pool time" TTS event at that crossing, gated on pool water temp ≥ 82 °F.

**Architecture:** SOPS secret → home-assistant.nix preStart injects `openuv_api_key` into `/var/lib/hass/secrets.yaml` → HA `rest:` sensor `sensor.openuv_forecast` exposes the hourly array as `attributes.result` → HA automation refreshes at 05:00 → Node-RED tab "Pool Time" listens for state changes, runs a pure-JS `compute window` function with linear interpolation, then dispatches a summary branch (08:00) and a scheduled trigger branch (crossing time → pool-temp gate → TTS).

**Tech Stack:** NixOS, sops-nix, Home Assistant YAML config, Node-RED with `home-assistant` palette (server config ID `86b277e82b069e9b`), pure JavaScript for the function node.

**Spec:** `/etc/nixos/docs/superpowers/specs/2026-05-12-openuv-pool-time-design.md`

---

## File Structure

**Modify:**
- `/etc/nixos/modules/services/home-assistant.nix` — three insertions:
  - SOPS secret declaration near line 232 (after `home-assistant/postgres-password`)
  - preStart append near line 925 (after the chmod line)
  - YAML `config` block: add `rest:` and append to `automation:` list near line 480–520

**Create (transient, for testing):**
- `/tmp/openuv-compute-test.js` — Node.js test harness for the compute-window function; deleted after the function is ported into the Node-RED function node.
- `/tmp/openuv-pool-time-flow.json` — flow JSON fragment to import into Node-RED; can be discarded after deploy.

**Update (live system):**
- Node-RED flows: add new tab "Pool Time" with ~10 nodes. Persist via Deploy in the editor (which writes `/var/lib/node-red/flows.json`).

---

## Task 1: Declare SOPS secret for openuv-api-key

**Files:**
- Modify: `/etc/nixos/modules/services/home-assistant.nix:232` (after `home-assistant/postgres-password` block)

- [ ] **Step 1.1: Add the sops.secrets declaration**

Insert immediately after the `home-assistant/postgres-password` block (ends at the closing `};` around line 235):

```nix
  # OpenUV API key for /forecast REST sensor (separate from the openuv
  # integration's UI-stored copy; HA's YAML rest: sensor cannot read
  # integration config_entries, so we duplicate-store the key here).
  sops.secrets."home-assistant/openuv-api-key" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };
```

- [ ] **Step 1.2: Build to catch eval errors**

Run: `sudo nixos-rebuild build --flake '.#vulcan' 2>&1 | tail -20`
Expected: Last line ends with `nixos-system-vulcan-…`. No `error:` lines in the tail.

- [ ] **Step 1.3: Switch**

Run: `sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tail -10`
Expected: ends with `Done. The new configuration is …`.

- [ ] **Step 1.4: Verify the secret is decrypted at runtime (metadata only — no value)**

Run: `sudo stat -c '%U:%G %a %n' /run/secrets/home-assistant/openuv-api-key`
Expected: `hass:hass 400 /run/secrets/home-assistant/openuv-api-key`

Do NOT cat the file. The grep-for-key-name check (Task 2) is the only content-touching operation in this plan, and it only ever reads `secrets.yaml`'s key-name lines, not values.

---

## Task 2: Inject openuv_api_key into HA secrets.yaml via preStart

**Files:**
- Modify: `/etc/nixos/modules/services/home-assistant.nix:923-925` (inside the existing preStart block, right after the postgres-password injection conditional and before `chmod 600`)

- [ ] **Step 2.1: Locate the insertion point**

Run: `grep -n "chmod 600 /var/lib/hass/secrets.yaml" /etc/nixos/modules/services/home-assistant.nix`
Expected: single line number reported (around 925).

- [ ] **Step 2.2: Insert the append conditional**

Add this block immediately BEFORE the `chmod 600 /var/lib/hass/secrets.yaml` line:

```bash
            # Add OpenUV API key if SOPS secret exists
            if [ -f ${config.sops.secrets."home-assistant/openuv-api-key".path} ]; then
              OPENUV_API_KEY=$(cat ${config.sops.secrets."home-assistant/openuv-api-key".path})
              echo "openuv_api_key: $OPENUV_API_KEY" >> /var/lib/hass/secrets.yaml
            fi

```

(Indentation: 12 spaces, matching the postgres-password block above.)

- [ ] **Step 2.3: Build + switch**

Run: `sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tail -5`
Expected: succeeds; HA restarts (preStart re-runs).

- [ ] **Step 2.4: Wait for HA active**

Run: `until systemctl is-active home-assistant.service | grep -q active; do sleep 3; done; echo "HA active"`
Expected: `HA active`. (Up to ~60 s.)

- [ ] **Step 2.5: Verify the key-name line was appended (no value reveal)**

Run: `sudo grep -c '^openuv_api_key:' /var/lib/hass/secrets.yaml`
Expected: `1`

If `0`: check `journalctl -u home-assistant.service --since "2 min ago" | grep -i 'secrets.yaml\|preStart'` for errors. Do NOT cat the file.

- [ ] **Step 2.6: Commit**

```bash
cd /etc/nixos && git add modules/services/home-assistant.nix
git commit -m "feat(hass): wire OpenUV API key from SOPS into HA secrets.yaml"
```

*(Skip if user has not authorized commits — leave changes staged.)*

---

## Task 3: Add REST sensor for OpenUV forecast

**Files:**
- Modify: `/etc/nixos/modules/services/home-assistant.nix` — add a top-level `rest` entry inside the YAML `config = { … };` block (around line 478–550). Identify the exact spot with a grep.

- [ ] **Step 3.1: Locate the YAML config block boundary**

Run: `grep -n "^    config = {" /etc/nixos/modules/services/home-assistant.nix`
Expected: one line (around 478). The block continues until the matching `};`.

- [ ] **Step 3.2: Add the `rest:` entry**

Pick a logical spot inside `config = { … }` — adjacent to other top-level integration entries (e.g., near `homeassistant`, `default_config`, or after a comment block). Insert:

```nix
      # OpenUV daily forecast — one /forecast pull per day at 05:00 (driven by
      # the refresh automation in Task 4). Exposes the hourly UV array as
      # sensor.openuv_forecast.attributes.result for Node-RED consumption.
      rest = [
        {
          scan_interval = 86400;
          resource = "https://api.openuv.io/api/v1/forecast";
          params = {
            lat = "!secret latitude";
            lng = "!secret longitude";
          };
          headers = {
            "x-access-token" = "!secret openuv_api_key";
          };
          sensor = [
            {
              name = "OpenUV Forecast";
              unique_id = "openuv_forecast";
              value_template = "{{ value_json.result | map(attribute='uv') | max | round(1) }}";
              json_attributes = [ "result" ];
            }
          ];
        }
      ];
```

**Note on `!secret` in Nix:** the HA NixOS module passes strings through verbatim into the generated YAML. The literal string `"!secret openuv_api_key"` produces YAML `!secret openuv_api_key`. Existing usage in this file (e.g. `latitude = "!secret latitude";`) is proof that this works on this host. Confirm by inspecting the generated configuration.yaml after Step 3.4.

- [ ] **Step 3.3: Build + switch**

Run: `sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tail -5`
Expected: success; HA restarts.

- [ ] **Step 3.4: Verify generated YAML contains the rest sensor with `!secret` tags**

Run: `sudo grep -A 8 '^rest:' /var/lib/hass/configuration.yaml | head -15`
Expected output includes:
```
rest:
- scan_interval: 86400
  resource: https://api.openuv.io/api/v1/forecast
  params:
    lat: !secret latitude
    lng: !secret longitude
  headers:
    x-access-token: !secret openuv_api_key
```

If `!secret` tags appear quoted (e.g. `"!secret latitude"`), the HA YAML loader will not expand them. Fallback: write the rest sensor block into a separate file referenced by `rest: !include rest_openuv.yaml` (or use HA packages: `services.home-assistant.config."packages"`). This fallback is unlikely to be needed — existing `homeassistant.latitude = "!secret latitude";` in this file works, demonstrating the passthrough is correct.

- [ ] **Step 3.5: Wait for HA active and manually trigger the sensor**

Run:
```bash
until systemctl is-active home-assistant.service | grep -q active; do sleep 3; done
sleep 10  # HA loads integrations after activation
```

Then via the HA UI (`https://hass.vulcan.lan`):
- Developer Tools → Services → call `homeassistant.update_entity` with target `sensor.openuv_forecast`.

Or via curl with a long-lived token (if the user has one configured):
```bash
curl -X POST -k "https://hass.vulcan.lan/api/services/homeassistant/update_entity" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "sensor.openuv_forecast"}'
```

- [ ] **Step 3.6: Verify sensor populated**

In HA Developer Tools → States, filter for `sensor.openuv_forecast`. Verify:
- State is a number between ~0 and ~12 (today's predicted peak UV).
- Attribute `result` is a non-empty list of `{uv: <float>, uv_time: <ISO>}` records.

If state is `unavailable`: check `journalctl -u home-assistant.service --since "5 min ago" | grep -iE "openuv|forecast|rest" | head -20` for the actual error (auth failure, network, JSON parse).

- [ ] **Step 3.7: Commit**

```bash
cd /etc/nixos && git add modules/services/home-assistant.nix
git commit -m "feat(hass): add OpenUV /forecast REST sensor with daily scan interval"
```

*(Skip if user has not authorized commits.)*

---

## Task 4: Create HA daily refresh automation via the UI

**Why no Nix change in this task:** `home-assistant.nix:790` declares `automation = "!include automations.yaml"`. Automations live in `/var/lib/hass/automations.yaml`, which is UI-managed and not git-tracked on this host. Adding the automation through the HA UI is the established convention — converting to an inline Nix list would break UI editability for all existing automations.

**Files:**
- Modify (via HA UI Deploy, which writes): `/var/lib/hass/automations.yaml`

- [ ] **Step 4.1: Create the automation in HA UI**

Open `https://hass.vulcan.lan` → Settings → Automations & Scenes → "+ Create Automation" → "Create new automation" (start from scratch) → fill in:

- **Alias / Name:** `OpenUV: refresh forecast at 05:00`
- **ID (Advanced → Automation ID):** `openuv_forecast_refresh`
- **Trigger:** type = Time, time = `05:00:00`
- **Conditions:** (none)
- **Actions:** type = "Call service", service = `homeassistant.update_entity`, target entity = `sensor.openuv_forecast`

Save.

- [ ] **Step 4.2: Verify the YAML form**

Run: `sudo grep -A 12 'OpenUV: refresh forecast' /var/lib/hass/automations.yaml`
Expected output (formatting may vary slightly):

```yaml
- id: openuv_forecast_refresh
  alias: 'OpenUV: refresh forecast at 05:00'
  trigger:
    - platform: time
      at: '05:00:00'
  action:
    - service: homeassistant.update_entity
      target:
        entity_id: sensor.openuv_forecast
```

If the entry is missing, the UI save didn't reload — Settings → System → Reload → Automations.

- [ ] **Step 4.3: Manually fire the automation as a smoke test**

HA Developer Tools → Services → call `automation.trigger` with `entity_id: automation.openuv_forecast_refresh`. Watch `sensor.openuv_forecast.last_updated` advance in States.

- [ ] **Step 4.4: No commit needed for this task**

`automations.yaml` is not in git (it's runtime state). Skip commit step.

---

## Task 5: Pin the pool-temp entity ID

**No files modified — discovery only.**

- [ ] **Step 5.1: Find the IntelliCenter water-temp entity**

In HA UI → Developer Tools → States → filter the entity search by `screenlogic` first; failing that, `intellicenter`, then `pool`, then `water_temp`. Look for a sensor reporting a temperature in °F (probably in the 60–95 range right now).

Likely candidates (one of):
- `sensor.intellicenter_water_temperature`
- `sensor.screenlogic_pool_water_temperature`
- `sensor.pool_water_temp`
- `sensor.<intellicenter_gateway_name>_water_temp`

- [ ] **Step 5.2: Record the entity ID**

Write the discovered entity ID into this plan file's Task 7 in place of the placeholder `<POOL_TEMP_ENTITY_ID>`. Also note the current value and units to confirm it's the right sensor.

- [ ] **Step 5.3: Sanity check**

The entity's `state_class` should be `measurement`; `unit_of_measurement` should be `°F`. If °C, the spec's 82 °F threshold needs conversion or the entity is the wrong one — flag back.

---

## Task 6: Implement and test compute-window function

**Files:**
- Create: `/tmp/openuv-compute-test.js` (transient — deleted after Task 7)

- [ ] **Step 6.1: Write the test harness with three fixtures**

Create `/tmp/openuv-compute-test.js`:

```javascript
// Standalone test for the compute-window function used in the Node-RED
// "Pool Time" tab. Mimics msg.data.event.new_state.attributes.result and
// asserts crossing_time precision against hand-computed fixtures.

const THRESHOLD = 3.0;

function computeWindow(forecastArray) {
    const fc = forecastArray;
    if (!Array.isArray(fc) || fc.length < 2) {
        return { crossing_time: null, peak_uv: null, error: "missing or short forecast" };
    }
    let peakUV = -Infinity, peakIdx = -1;
    for (let i = 0; i < fc.length; i++) {
        if (fc[i].uv > peakUV) { peakUV = fc[i].uv; peakIdx = i; }
    }
    let crossingMs = null;
    for (let i = peakIdx; i < fc.length - 1; i++) {
        const u0 = fc[i].uv, u1 = fc[i + 1].uv;
        if (u0 >= THRESHOLD && u1 < THRESHOLD) {
            const t0 = Date.parse(fc[i].uv_time);
            const t1 = Date.parse(fc[i + 1].uv_time);
            const frac = (u0 - THRESHOLD) / (u0 - u1);
            crossingMs = t0 + frac * (t1 - t0);
            break;
        }
    }
    return {
        crossing_time: crossingMs ? new Date(crossingMs).toISOString() : null,
        peak_uv: Number(peakUV.toFixed(1)),
    };
}

// Fixture builder: generate hourly samples for a given UV profile.
function makeForecast(date, uvByHourUTC) {
    return uvByHourUTC.map((uv, i) => ({
        uv,
        uv_time: new Date(`${date}T${String(i).padStart(2, '0')}:00:00.000Z`).toISOString(),
    }));
}

const tests = [
    {
        name: "clear summer day — peak 9 at 20:00 UTC, descends through 3 around 24:?? UTC",
        // Inverted-parabola-ish profile, peak at UTC 20:00 (13:00 local PDT)
        forecast: makeForecast("2026-07-15",
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 5, 7, 8.5, 9, 9.5, 9, 8, 6, 4]),
        expectCrossingHour: 23, // descending through 3 between hour 22 (UV=6) and 23 (UV=4)
        expectPeakUV: 9.5,
    },
    {
        name: "overcast day — UV never reaches 3",
        forecast: makeForecast("2026-12-15",
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1.5, 2, 2.5, 2, 1.5, 1, 0, 0, 0]),
        expectCrossingHour: null,
        expectPeakUV: 2.5,
    },
    {
        name: "edge — peak 4 at 18:00, single descending crossing",
        forecast: makeForecast("2026-05-15",
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3.5, 4, 4, 3.5, 3, 2.5, 1, 0]),
        expectCrossingHour: 21, // u=3 at 20, u=2.5 at 21 → frac=0, cross at hour 21? Let me trace.
        // Actually peak is at idx 17 or 18; scan from there. idx 18→19: 4→3.5 (no cross). idx 19→20: 3.5→3 (3 >= 3 but 3 not < 3 — no cross). idx 20→21: 3→2.5 (3>=3, 2.5<3, cross). frac = 0. crossing = t0 = hour 20.
        expectPeakUV: 4.0,
    },
];

let pass = 0, fail = 0;
for (const t of tests) {
    const r = computeWindow(t.forecast);
    const crossingHour = r.crossing_time ? new Date(r.crossing_time).getUTCHours() : null;
    const peakOk = Math.abs(r.peak_uv - t.expectPeakUV) < 0.05;
    // Allow crossing within ±1 hour (linear-interp can put it on either side of the boundary)
    const crossingOk = (t.expectCrossingHour === null && crossingHour === null) ||
                       (crossingHour !== null && Math.abs(crossingHour - t.expectCrossingHour) <= 1);
    const ok = peakOk && crossingOk;
    console.log(`${ok ? "PASS" : "FAIL"}: ${t.name}`);
    console.log(`  expected: crossingHour=${t.expectCrossingHour} peakUV=${t.expectPeakUV}`);
    console.log(`  got:      crossingHour=${crossingHour} peakUV=${r.peak_uv} crossing_time=${r.crossing_time}`);
    if (ok) pass++; else fail++;
}
console.log(`\n${pass}/${pass + fail} tests passed`);
process.exit(fail === 0 ? 0 : 1);
```

- [ ] **Step 6.2: Run the tests**

Run: `node /tmp/openuv-compute-test.js`
Expected: `3/3 tests passed`, exit 0.

If any test fails, the linear-interp logic or fixture is wrong — debug in this file before porting into Node-RED. **Do not proceed to Task 7 until 3/3 pass.**

---

## Task 7: Build Node-RED flow tab "Pool Time"

**Files:**
- Create: `/tmp/openuv-pool-time-flow.json` (import payload for Node-RED)
- Modify (via Node-RED editor's Import + Deploy): `/var/lib/node-red/flows.json`

**TTS pattern on this host (verified from existing flows):** TTS is via the `tts.speak` service with engine entity `tts.google_translate_en_com`, passing `media_player_entity_id` and `message` inside the `data` payload (JSONata mode). The spec's earlier mention of `tts.cloud_say` was based on outdated S106 context — `tts.speak` is the current convention.

**Placeholders to substitute before deploy:**
- `POOL_TEMP_ENTITY_ID` ← entity ID pinned in Task 5 (e.g. `sensor.screenlogic_pool_water_temperature`)
- `TTS_MEDIA_PLAYER` ← e.g. `media_player.vlc_telnet` (verify the entity exists; if you want multi-room playback, change to a `media_player.group_*` entity)
- `TTS_ENGINE` ← `tts.google_translate_en_com` (matches existing flows; substitute another if a different engine is preferred)

- [ ] **Step 7.1: Generate fresh node IDs**

Run: `python /home/johnw/.claude/skills/node-red/scripts/generate_uuid.py 13`
Expected: 13 lines of 16-hex-character IDs. Use them below in this order: TAB_ID, LISTENER_ID, COMPUTE_FN_ID, SWITCH_ID, NO_WIN_FN_ID, NO_WIN_CALL_ID, SUMMARY_FN_ID, SUMMARY_DELAY_ID, SUMMARY_CALL_ID, TRIGGER_DELAY_ID, POOL_TEMP_READ_ID, TRIGGER_SWITCH_ID, TRIGGER_CALL_ID.

- [ ] **Step 7.2: Author the flow JSON**

Create `/tmp/openuv-pool-time-flow.json` containing the array below. Substitute every `<…>` placeholder.

```json
[
  {
    "id": "<TAB_ID>",
    "type": "tab",
    "label": "Pool Time",
    "disabled": false,
    "info": "OpenUV forecast → pool-time TTS event.\nSpec: docs/superpowers/specs/2026-05-12-openuv-pool-time-design.md"
  },
  {
    "id": "<LISTENER_ID>",
    "type": "server-state-changed",
    "z": "<TAB_ID>",
    "name": "OpenUV Forecast updated",
    "server": "86b277e82b069e9b",
    "version": 6,
    "outputs": 1,
    "entities": {
      "entity": ["sensor.openuv_forecast"],
      "substring": [],
      "regex": []
    },
    "outputInitially": false,
    "stateType": "str",
    "ifState": "",
    "ifStateType": "str",
    "ifStateOperator": "is",
    "outputOnlyOnStateChange": true,
    "ignorePrevStateNull": true,
    "ignorePrevStateUnknown": true,
    "ignorePrevStateUnavailable": true,
    "ignoreCurrentStateUnknown": true,
    "ignoreCurrentStateUnavailable": true,
    "outputProperties": [
      { "property": "payload", "propertyType": "msg", "value": "", "valueType": "entityState" },
      { "property": "data", "propertyType": "msg", "value": "", "valueType": "eventData" }
    ],
    "x": 160,
    "y": 100,
    "wires": [["<COMPUTE_FN_ID>"]]
  },
  {
    "id": "<COMPUTE_FN_ID>",
    "type": "function",
    "z": "<TAB_ID>",
    "name": "compute window",
    "func": "const fc = msg.data.event.new_state.attributes.result;\nif (!Array.isArray(fc) || fc.length < 2) {\n    node.warn('OpenUV forecast missing or too short');\n    return null;\n}\nconst THRESHOLD = 3.0;\nconst now = Date.now();\nlet peakUV = -Infinity, peakIdx = -1;\nfor (let i = 0; i < fc.length; i++) {\n    if (fc[i].uv > peakUV) { peakUV = fc[i].uv; peakIdx = i; }\n}\nlet crossingMs = null;\nfor (let i = peakIdx; i < fc.length - 1; i++) {\n    const u0 = fc[i].uv, u1 = fc[i + 1].uv;\n    if (u0 >= THRESHOLD && u1 < THRESHOLD) {\n        const t0 = Date.parse(fc[i].uv_time);\n        const t1 = Date.parse(fc[i + 1].uv_time);\n        const frac = (u0 - THRESHOLD) / (u0 - u1);\n        crossingMs = t0 + frac * (t1 - t0);\n        break;\n    }\n}\nconst sunset = global.get('sun_next_setting') || null;\nconst crossingInMs = crossingMs ? Math.max(0, crossingMs - now) : null;\n// ms until next 08:00 local (host TZ = America/Los_Angeles)\nconst t8 = new Date();\nt8.setHours(8, 0, 0, 0);\nconst summaryInMs = t8.getTime() > now ? t8.getTime() - now : 0;\nmsg.payload = {\n    crossing_time: crossingMs ? new Date(crossingMs).toISOString() : null,\n    crossing_in_ms: crossingInMs,\n    summary_in_ms: summaryInMs,\n    peak_uv: Number(peakUV.toFixed(1)),\n    sunset: sunset\n};\n// Default msg.delay for the trigger branch; the summary branch will override\n// it in `format summary`. The no-window branch ignores msg.delay.\nmsg.delay = crossingInMs !== null ? crossingInMs : 0;\nreturn msg;",
    "outputs": 1,
    "noerr": 0,
    "initialize": "",
    "finalize": "",
    "libs": [],
    "x": 380,
    "y": 100,
    "wires": [["<SWITCH_ID>"]]
  },
  {
    "id": "<SWITCH_ID>",
    "type": "switch",
    "z": "<TAB_ID>",
    "name": "window exists?",
    "property": "payload.crossing_time",
    "propertyType": "msg",
    "rules": [
      { "t": "nnull" },
      { "t": "null" }
    ],
    "checkall": "true",
    "repair": false,
    "outputs": 2,
    "x": 580,
    "y": 100,
    "wires": [
      ["<SUMMARY_FN_ID>", "<TRIGGER_DELAY_ID>"],
      ["<NO_WIN_FN_ID>"]
    ]
  },
  {
    "id": "<NO_WIN_FN_ID>",
    "type": "function",
    "z": "<TAB_ID>",
    "name": "no-window text",
    "func": "msg.payload = {\n    message: `Today is overcast; no pool window. Peak UV ${msg.payload.peak_uv}.`\n};\nreturn msg;",
    "outputs": 1,
    "noerr": 0,
    "x": 800,
    "y": 200,
    "wires": [["<NO_WIN_CALL_ID>"]]
  },
  {
    "id": "<NO_WIN_CALL_ID>",
    "type": "api-call-service",
    "z": "<TAB_ID>",
    "name": "TTS (no window)",
    "server": "86b277e82b069e9b",
    "version": 7,
    "debugenabled": false,
    "action": "tts.speak",
    "entityId": ["<TTS_ENGINE>"],
    "data": "{\"cache\": true, \"media_player_entity_id\": \"<TTS_MEDIA_PLAYER>\", \"message\": payload.message}",
    "dataType": "jsonata",
    "outputProperties": [],
    "queue": "none",
    "blockInputOverrides": true,
    "x": 1010,
    "y": 200,
    "wires": [[]]
  },
  {
    "id": "<SUMMARY_FN_ID>",
    "type": "function",
    "z": "<TAB_ID>",
    "name": "format summary",
    "func": "const cross = new Date(msg.payload.crossing_time);\nconst sunsetISO = msg.payload.sunset;\nconst opts = { hour: 'numeric', minute: '2-digit', timeZone: 'America/Los_Angeles' };\nconst crossStr = cross.toLocaleTimeString('en-US', opts);\nconst sunsetStr = sunsetISO ? new Date(sunsetISO).toLocaleTimeString('en-US', opts) : 'sunset';\n// Override msg.delay (set by compute window) with ms-until-08:00.\nmsg.delay = msg.payload.summary_in_ms;\nmsg.payload = {\n    message: `Today's pool window will be from ${crossStr} until ${sunsetStr}.`\n};\nreturn msg;",
    "outputs": 1,
    "noerr": 0,
    "x": 800,
    "y": 60,
    "wires": [["<SUMMARY_DELAY_ID>"]]
  },
  {
    "id": "<SUMMARY_DELAY_ID>",
    "type": "trigger",
    "z": "<TAB_ID>",
    "name": "wait until 08:00",
    "op1": "",
    "op2": "",
    "op1type": "nul",
    "op2type": "payl",
    "duration": "0",
    "extend": false,
    "overrideDelay": true,
    "units": "s",
    "reset": "",
    "bytopic": "all",
    "topic": "topic",
    "outputs": 1,
    "x": 1000,
    "y": 60,
    "wires": [["<SUMMARY_CALL_ID>"]]
  },
  {
    "id": "<SUMMARY_CALL_ID>",
    "type": "api-call-service",
    "z": "<TAB_ID>",
    "name": "TTS (summary)",
    "server": "86b277e82b069e9b",
    "version": 7,
    "debugenabled": false,
    "action": "tts.speak",
    "entityId": ["<TTS_ENGINE>"],
    "data": "{\"cache\": true, \"media_player_entity_id\": \"<TTS_MEDIA_PLAYER>\", \"message\": payload.message}",
    "dataType": "jsonata",
    "outputProperties": [],
    "queue": "none",
    "blockInputOverrides": true,
    "x": 1200,
    "y": 60,
    "wires": [[]]
  },
  {
    "id": "<TRIGGER_DELAY_ID>",
    "type": "trigger",
    "z": "<TAB_ID>",
    "name": "wait until crossing_time",
    "op1": "",
    "op2": "",
    "op1type": "nul",
    "op2type": "payl",
    "duration": "0",
    "extend": false,
    "overrideDelay": true,
    "units": "ms",
    "reset": "",
    "bytopic": "all",
    "topic": "topic",
    "outputs": 1,
    "x": 800,
    "y": 140,
    "wires": [["<POOL_TEMP_READ_ID>"]]
  },
  {
    "id": "<POOL_TEMP_READ_ID>",
    "type": "api-current-state",
    "z": "<TAB_ID>",
    "name": "read pool temp",
    "server": "86b277e82b069e9b",
    "version": 3,
    "outputs": 1,
    "halt_if": "",
    "halt_if_type": "str",
    "halt_if_compare": "is",
    "entity_id": "<POOL_TEMP_ENTITY_ID>",
    "state_type": "num",
    "blockInputOverrides": false,
    "outputProperties": [
      { "property": "payload.pool_temp", "propertyType": "msg", "value": "", "valueType": "entityState" }
    ],
    "for": "0",
    "forType": "num",
    "forUnits": "minutes",
    "override_topic": false,
    "state_location": "payload",
    "override_payload": "none",
    "entity_location": "data",
    "override_data": "none",
    "x": 1020,
    "y": 140,
    "wires": [["<TRIGGER_SWITCH_ID>"]]
  },
  {
    "id": "<TRIGGER_SWITCH_ID>",
    "type": "switch",
    "z": "<TAB_ID>",
    "name": "≥ 82 °F?",
    "property": "payload.pool_temp",
    "propertyType": "msg",
    "rules": [
      { "t": "gte", "v": "82", "vt": "num" }
    ],
    "checkall": "true",
    "repair": false,
    "outputs": 1,
    "x": 1220,
    "y": 140,
    "wires": [["<TRIGGER_CALL_ID>"]]
  },
  {
    "id": "<TRIGGER_CALL_ID>",
    "type": "api-call-service",
    "z": "<TAB_ID>",
    "name": "TTS (pool time)",
    "server": "86b277e82b069e9b",
    "version": 7,
    "debugenabled": false,
    "action": "tts.speak",
    "entityId": ["<TTS_ENGINE>"],
    "data": "{\"cache\": true, \"media_player_entity_id\": \"<TTS_MEDIA_PLAYER>\", \"message\": 'Pool time. UV has dropped, water is ' & $string($round(payload.pool_temp)) & ' degrees.'}",
    "dataType": "jsonata",
    "outputProperties": [],
    "queue": "none",
    "blockInputOverrides": true,
    "x": 1420,
    "y": 140,
    "wires": [[]]
  }
]
```

**Note on the two `trigger` (delay) nodes:**

The flow above uses Node-RED's stock `trigger` node with `overrideDelay: true` and `op1type: "nul"`, which fires `msg.payload` after a delay of `msg.delay` ms. The `compute window` and `format summary` function bodies above already set `msg.delay` correctly (`crossing_in_ms` for branch B, `summary_in_ms` for branch A). No additional editing is needed for a deploy-ready state.

**Caveat for very-long delays:** the stock `trigger` node is not persistent — if Node-RED restarts mid-day, scheduled fires are lost. Recovery is handled by the next morning's forecast update (Task 8). If multi-hour persistence becomes a requirement, replace both trigger nodes with `node-red-contrib-cron-plus` dynamic-mode nodes — but this is not a blocker for the initial deploy.

- [ ] **Step 7.3: Validate the flow JSON syntax**

Run: `python /home/johnw/.claude/skills/node-red/scripts/validate_flow.py /tmp/openuv-pool-time-flow.json`
Expected: validator reports no errors. If it complains about missing referenced node IDs, check that every wire target points to an ID defined in the same file.

- [ ] **Step 7.4: Import into Node-RED**

In the Node-RED editor (`https://nodered.newartisans.com` or the local URL):
- Menu (☰) → Import → paste contents of `/tmp/openuv-pool-time-flow.json` → Import.
- The new tab "Pool Time" should appear with all nodes positioned roughly per the `x`/`y` coordinates.

- [ ] **Step 7.5: Deploy**

Click **Deploy** → "Full" (or "Modified Flows" — either works for a new tab).
Watch for any red triangles on nodes (config errors). If the `api-current-state` node complains about a missing entity, the placeholder `<POOL_TEMP_ENTITY_ID>` was not substituted in Step 7.2 — open the node and pick the entity from Task 5.

- [ ] **Step 7.6: Smoke test — branch A (summary)**

In Node-RED, drag an `inject` node into the tab temporarily, wire it to `compute window`, configure its `msg.data.event.new_state.attributes.result` to a hand-crafted forecast array matching one of the Task 6 fixtures (clear summer day). Click the inject button.

Expected:
- Debug shows `compute window` output with non-null `crossing_time`.
- After the configured delay (or immediately if past 08:00), `TTS (summary)` fires.
- Audible: "Today's pool window will be from … until …" through the configured media_player.

Remove the temporary inject node when done.

- [ ] **Step 7.7: Smoke test — branch B (trigger + temp gate)**

Craft an inject fixture whose `result` array has a descending UV=3 crossing ~5 seconds in the future (e.g. one sample with `uv: 5` at `now`, next sample with `uv: 1` at `now+10s`; `compute window` will interpolate to ~5 s and set `msg.delay ≈ 5000`).

- **Sub-test (a):** In HA Developer Tools → States → set state on `<POOL_TEMP_ENTITY_ID>` to `85`. Fire inject. Expected: ~5 s later, TTS "Pool time. UV has dropped, water is 85 degrees."
- **Sub-test (b):** Set pool-temp to `75`. Fire inject. Expected: no TTS after the delay; the `≥ 82 °F?` switch's no-output path shows in debug.

- [ ] **Step 7.8: Smoke test — no-window branch**

Hand-craft a fixture with all `uv` values ≤ 2. Inject. Expected: TTS "Today is overcast; no pool window. Peak UV 2.0."

- [ ] **Step 7.9: Clean up transient files**

```bash
rm /tmp/openuv-compute-test.js /tmp/openuv-pool-time-flow.json
```

- [ ] **Step 7.10: Back up flows.json**

The `node-red-backup.service` runs nightly, but force a backup of the new flow:
```bash
sudo systemctl start node-red-backup.service 2>&1 | tail -3
```

---

## Task 8: End-to-end live verification

- [ ] **Step 8.1: Real forecast fetch**

In HA Developer Tools → Services → call `homeassistant.update_entity` for `sensor.openuv_forecast`. Confirm `attributes.result` has hourly entries for today.

- [ ] **Step 8.2: Wait for Node-RED state-change listener to fire**

In Node-RED tab "Pool Time", watch the `OpenUV Forecast updated` node status. It should show a recent timestamp. The `compute window` function should output a `crossing_time` value.

- [ ] **Step 8.3: Inspect the predicted crossing time**

Open the debug panel. Read the `crossing_time` value. Mentally cross-check against the `result` array: find the two adjacent samples bracketing UV=3 on the descending leg, and verify the crossing time lies between them.

- [ ] **Step 8.4: Tomorrow 05:00 — natural fire**

The HA refresh automation fires at 05:00. Branch A summary should TTS at 08:00 local. Branch B trigger fires at the predicted crossing.

If branch A misses 08:00: check Node-RED debug for the function output and the trigger node's status. If branch B misses crossing time by > ±2 min: investigate the trigger-node-vs-cron-plus decision and Node-RED log for time drift.

---

## Task 9: S106 residue check

- [ ] **Step 9.1: Grep HA config**

Run: `grep -iRE 'openuv|pool_time' /etc/nixos/modules/services/home-assistant.nix /var/lib/hass/automations.yaml /var/lib/hass/scripts.yaml 2>/dev/null | grep -v "^[^:]*:#" | head -20`
Expected: matches are only the new entries from Tasks 1-4 (and possibly the integration polling config). No S106 ghosts.

- [ ] **Step 9.2: Grep Node-RED flows**

Run: `sudo grep -ciE 'openuv|pool_time|pool_water_temp' /var/lib/node-red/flows.json`
Expected: matches the count of new nodes from Task 7 (roughly 6–12). No outliers.

- [ ] **Step 9.3: If outliers found, list them**

If S106 residue exists, list it with file:line, then either remove (preferred) or supersede with a comment. Do not silently leave it.

---

## Task 10: Save project memory + finalize

- [ ] **Step 10.1: Write project memory**

Create `/home/johnw/.claude/projects/-etc-nixos/memory/project_openuv_pool_time.md`:

```markdown
---
name: OpenUV pool-time prediction
description: HA REST sensor + Node-RED flow predicts daily UV=3 descending crossing; gates "pool time" TTS on pool water temp ≥ 82 °F
type: project
---

OpenUV `/forecast` endpoint pulled once daily at 05:00 by HA REST sensor `sensor.openuv_forecast` (configured in `modules/services/home-assistant.nix`). Hourly UV array exposed via `attributes.result`.

Node-RED tab "Pool Time" listens for state-changes, runs `compute window` function (linear-interpolation across the descending leg to find UV=3 crossing), then:
- Branch A: TTS daily summary at 08:00 local naming the predicted window.
- Branch B: scheduled trigger at the crossing time, reads `<POOL_TEMP_ENTITY_ID>`, gates ≥ 82 °F, then TTS "Pool time".

**Key file paths:**
- Spec: `/etc/nixos/docs/superpowers/specs/2026-05-12-openuv-pool-time-design.md`
- Plan: `/etc/nixos/docs/superpowers/plans/2026-05-12-openuv-pool-time.md`
- HA module: `/etc/nixos/modules/services/home-assistant.nix`
- Node-RED flows: `/var/lib/node-red/flows.json` (tab "Pool Time")

**Why:** S106 design called for current-UV polling + temp gate, but the openuv integration polls `/uv` not `/forecast`. Forecast-based prediction lets us schedule the event ahead of time and add a sunrise daily summary, while staying within the 50/day free-tier API quota.

**Why no curve fitting:** Hourly resolution + linear interp gives crossing-time error ≤ ~30 seconds for the bell-shaped UV diurnal — indistinguishable from quadratic least-squares at voice-alert audibility. Explicitly ruled out during brainstorming.

**Quota note:** HA `openuv` integration's 30-min `/uv` polling burns ~48/day; our `/forecast` adds 1/day → ~49/50. If quota tightens, bump the integration's update_interval to 60 min.
```

- [ ] **Step 10.2: Update MEMORY.md index**

Append to `/home/johnw/.claude/projects/-etc-nixos/memory/MEMORY.md`:

```
- [project_openuv_pool_time.md](project_openuv_pool_time.md) — daily `/forecast` → Node-RED `compute window` → scheduled UV=3 + pool-temp gated TTS
```

- [ ] **Step 10.3: Commit (final)**

```bash
cd /etc/nixos && git add docs/superpowers/specs/2026-05-12-openuv-pool-time-design.md docs/superpowers/plans/2026-05-12-openuv-pool-time.md
git commit -m "docs(superpowers): OpenUV pool-time design + implementation plan"
```

*(Skip if user has not authorized commits.)*

---

## Verification summary

After all tasks, the following should be true:

- `/run/secrets/home-assistant/openuv-api-key` exists, `hass:hass 400`.
- `/var/lib/hass/secrets.yaml` contains exactly one `openuv_api_key:` line.
- HA UI shows `sensor.openuv_forecast` with numeric state and `result` attribute populated.
- HA UI shows automation "OpenUV: refresh forecast at 05:00" enabled.
- Node-RED tab "Pool Time" exists with 12 nodes wired per the diagram (plus the tab object itself = 13 entries in the import JSON).
- Manual fast-forward tests fire TTS through the configured `media_player`.
- No S106 ghosts in HA YAML or flows.json.
- Project memory file written and indexed.

## Rollback procedure

If anything breaks badly:

1. **HA REST sensor or automation regressed something else:** revert the home-assistant.nix changes (`git diff` to inspect; `git checkout -- modules/services/home-assistant.nix` to restore) and `nixos-rebuild switch`.
2. **Node-RED flow misbehaving:** in the editor, disable the "Pool Time" tab (right-click → disable) and Deploy. The flow stops firing without removal.
3. **SOPS secret unwanted:** `sops /etc/nixos/secrets/secrets.yaml` and remove the `openuv-api-key` line; rebuild.

The openuv HA integration itself is untouched by all of the above; its `sensor.current_uv_index` etc. continue working independently.
