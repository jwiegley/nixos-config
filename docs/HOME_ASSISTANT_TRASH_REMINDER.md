# Trash Pickup Reminder — Design & Future Work

Status as of 2026-05-22. Resume the **Phase 2** work below once the color-changing
bulb arrives.

## Phase 1 — Deployed

Replaces the old single-TTS HA automation that fired off the now-deleted
`local_calendar.sacramento_waste`. New flow uses the
`waste_collection_schedule` integration's per-bin sensors and announces *which*
bins are going so John can tell whether Organics is included that week.

### Components

| Layer | Where | Purpose |
|---|---|---|
| Schedule source | HA `waste_collection_schedule` integration (Sacramento County, CA) | ICS feed from Sacramento County's ReCollect endpoint; produces 4 sensors + 1 calendar |
| Acknowledgment state | `input_boolean.trash_taken_out` | Set on by "Mark Done" tap; reset off by the nightly announcement when a new pickup is coming |
| Announcement | Node-RED tab **Home**, "Announce Trash Day" band | Nightly 20:00 announcement TTS + actionable iOS push |
| Listener | Node-RED tab **Home**, "Acknowledge Mark Done" band | Catches `mobile_app_notification_action`, flips `input_boolean` on if action is `TRASH_ACK` |

### Sensors used (waste_collection_schedule)

```
sensor.waste_collection_schedule_garbage
sensor.waste_collection_schedule_recycling
sensor.waste_collection_schedule_organics
sensor.waste_collection_schedule_street_sweeping   # not used in announcement
calendar.waste_collection_schedule_sacramento_county_ca  # informational, not driven by automation
```

State format from the integration: `"<Type> in <N> days"`. Function parses `\d+`
out of the state, treats `N == 1` as "tomorrow". Falls back to `attributes.daysTo`
if exposed.

### Node-RED nodes — Home tab `9fc588ef6d4255d1`

| ID | Type | Name | Role |
|---|---|---|---|
| `10bc1179bfd440969f778ab1cff07cae` | `chronos-scheduler` | `20:00 nightly` | Fires every night at 20:00 local |
| `ba28e073e55c4bfa8045d7b0b805c944` | `function` | `Build trash-day announcement` | Reads the three bin sensors, filters `daysTo == 1`, builds the announcement message. Returns null if no pickup tomorrow. |
| `ae11248baae5122d` | `api-call-service` | `Trash Reminder` (TTS) | `tts.speak` → `media_player.vlc_telnet` with `message: payload` |
| `83c0d7003a1fadaf` | `api-call-service` | `notify` | `notify.notify` with `actions: [{action: "TRASH_ACK", title: "Mark Done"}]` |
| `d792afd4adeb49febf7153483049c520` | `api-call-service` | `reset trash_taken_out off` | `input_boolean.turn_off` on `input_boolean.trash_taken_out` |
| `f8c00512355e457cb76b7633402f2d9b` | `server-events` | `mobile notification action` | Listens for `mobile_app_notification_action` events |
| `6b77825babf440b0a401455dfc049c1a` | `switch` | `action == TRASH_ACK?` | Gates on `payload.action == "TRASH_ACK"` |
| `6a21a41a5d25462682ae832554437391` | `api-call-service` | `trash_taken_out on` | `input_boolean.turn_on` on `input_boolean.trash_taken_out` |

Wiring:

```
[chronos: 20:00 nightly]
       ↓
[function: Build trash-day announcement]
       ├──→ [TTS: Trash Reminder]
       ├──→ [notify: with Mark Done action]
       └──→ [reset trash_taken_out off]

[server-events: mobile notification action]
       ↓
[switch: action == TRASH_ACK?]
       ↓
[trash_taken_out on]
```

### Files added

- `/var/lib/hass/packages/trash.yaml` — declares the `input_boolean`. 5 functional lines.
- `/etc/nixos/overlays/waste_collection_schedule.nix` — bumps the Mampfes
  integration to **v2.24.0** for the named "Sacramento County, CA" source
  dropdown. (Nixpkgs ships 2.10.0, which had only a generic "ReCollect"
  entry — same engine, less friendly UX.)
- Wired into `/etc/nixos/overlays/default.nix` under `home-assistant-custom-components`.

### Function-node code (Phase 1)

```javascript
// Build trash-day announcement from waste_collection_schedule sensors.
// State format: "<Type> in <N> days" — parse N; if N==1, it's tomorrow.
const states = global.get('homeassistant.homeAssistant.states') || {};

const bins = [
    ['sensor.waste_collection_schedule_garbage',   'Garbage'],
    ['sensor.waste_collection_schedule_recycling', 'Recycling'],
    ['sensor.waste_collection_schedule_organics',  'Organics'],
];

const tomorrow = bins.filter(([id, _]) => {
    const s = states[id];
    if (!s) return false;
    if (typeof s.attributes?.daysTo === 'number') {
        return s.attributes.daysTo === 1;
    }
    const m = String(s.state).match(/in (\d+) days?/);
    return m && parseInt(m[1], 10) === 1;
}).map(([_, label]) => label);

if (tomorrow.length === 0) {
    node.status({fill: 'grey', shape: 'ring', text: 'no pickup tomorrow'});
    return null;
}

const list = tomorrow.length === 1
    ? tomorrow[0]
    : tomorrow.slice(0, -1).join(', ') + ' and ' + tomorrow[tomorrow.length - 1];
const verb = tomorrow.length === 1 ? 'is' : 'are';

msg.payload = `Tomorrow is trash day. ${list} ${verb} being picked up.`;
msg.topic = 'Trash Day';
node.status({fill: 'green', shape: 'dot',
             text: tomorrow.join('+')});
return msg;
```

---

## Phase 2 — Color-cycling ambient escalation (pending hardware)

**Trigger condition:** if `input_boolean.trash_taken_out` is still `off` **one
hour after the announcement fired**, start a visual escalation: a smart bulb
alternates between red and yellow until the boolean flips on, OR until a hard
cutoff time.

### Behavioral spec

| Event | Action |
|---|---|
| 20:00 nightly, announcement fires, pickup tomorrow | Start a 1-hour timer; bulb stays off |
| 21:00 (1h after), if `input_boolean.trash_taken_out == off` | Begin color cycle: red → yellow → red → yellow … |
| Boolean flips `off → on` (Mark Done tapped) | Immediately stop cycle, turn bulb off |
| Cutoff time, e.g. 23:30 or 00:00 | Stop cycle, turn bulb off; leave boolean as-is for history |
| No pickup tomorrow (function returned null) | No timer started, no escalation possible |

The cycle is a **visual nag**, deliberately ambient and peripheral — it doesn't
fight for attention like a notification, but you'll catch it if you walk past
the room. Per the original behavior research, varying-channel cues defeat
habituation.

### Open implementation questions (resolve when hardware arrives)

1. **Which bulb?** Probably whichever you mount near the office desk or living
   room — somewhere you'll see during the 21:00–23:30 window. Needs to be RGB
   (i.e. controllable hue), not just dimmable white. Note the entity ID once
   it's added to HA.
2. **Cycle interval.** Too fast feels frantic, too slow doesn't register as a
   pattern. Suggest **3 seconds per color** as a starting point. Adjustable in
   the chronos-repeat node.
3. **Cutoff time.** Pick a wall-clock hour (`23:30`?) — set as a second chronos
   trigger that calls "stop cycle" regardless of boolean state, so the bulb
   doesn't strobe through the night if you fall asleep without acknowledging.
4. **Color values.** Red ≈ `[255, 0, 0]`, Yellow ≈ `[255, 200, 0]`. Saturated
   colors are more visible at low light levels. Brightness probably ~180/255.
5. **Should the bulb turn off** between announcement (20:00) and start (21:00)?
   Probably yes — it should only ever be on as the escalation indicator. Don't
   blow away the user's normal bulb usage; if the bulb is part of a room scene,
   pick a different bulb or use a dedicated indicator.

### Node-RED structure to add (sketch)

Wire off the existing function output (the `msg` carrying the announcement) so
this only arms when there IS a pickup tomorrow:

```
[function: Build trash-day announcement]
       ├──→ [TTS]                  (existing)
       ├──→ [notify with action]   (existing)
       ├──→ [reset trash_taken_out off]  (existing)
       └──→ [delay: 60 min]
                  ↓
            [api-current-state: input_boolean.trash_taken_out == off?]
                  ↓ (match → still not acknowledged)
            [chronos-repeat: every 3s, output alternating payload red/yellow]
                  ↓
            [api-call-service: light.turn_on with {rgb_color, brightness}]

[state listener: input_boolean.trash_taken_out → on]
       ↓
[stop chronos-repeat] + [light.turn_off]

[chronos: 23:30 cutoff]
       ↓
[stop chronos-repeat] + [light.turn_off]
```

### House-style notes for the Phase 2 build

- The repeat-interval JSONata gotcha: `chronos-repeat` interprets the JSONata
  expression as **milliseconds**, not seconds. For 3-second cycle: return
  `3000`, not `3`. (See CLAUDE.md pitfall #2.)
- The `api-current-state` gate at 21:00: `halt_if: "off"` wired to **output 1
  (no-match)** means "fire when state is NOT off" = "fire when acknowledged".
  We want the opposite — wire output 0 (match) onward to "start cycling".
  Double-check the wiring; same `halt_if` string is used both ways elsewhere
  in this codebase. (Pitfall #1.)
- Use a state-change trigger (`server-state-changed`) on
  `input_boolean.trash_taken_out` rather than polling — `for: 0s` so any
  transition fires immediately.
- The "stop cycle" path needs to cancel any in-flight delay nodes — set
  `msg.reset = true` on the delay node, send any payload to the chronos-repeat
  to stop it. Don't use `msg.complete` (drains to expired output, not what we
  want). (Pitfall #5.)
- Add a subflow-style status emitter on the bulb-control node so you can see
  current cycle state in the editor: `node.status({fill: 'red', shape: 'ring',
  text: 'red'})` and `node.status({fill: 'yellow', shape: 'ring', text:
  'yellow'})`.

### Things to consider before building

- **Spook compatibility:** No special concern. Spook adds reload services; not
  relevant here.
- **Repeat-during-restart:** If Node-RED restarts mid-cycle, the cycle timer is
  lost. Acceptable — the next restart of the cycle will only happen with a
  fresh 20:00 trigger. State of `input_boolean.trash_taken_out` survives because
  it's a YAML-defined HA entity.
- **Edge case: pickup never happens because of holiday.** Nightly cron is
  robust — it only fires the cascade when `daysTo == 1`. If pickup slips from
  Wed to Thu, the announcement fires Wed night, not Tue.
- **Mark Done is the only ack path.** Manually setting `input_boolean.trash_taken_out`
  to `on` from the HA UI also stops the cycle, since the state-change listener
  catches it regardless of source. Good fallback if iOS push delivery fails.

### Memory references to consult when resuming

- `feedback_ha_journal_pairing_code_leak.md` — don't tail HA journal unfiltered
  during verification
- `feedback_app_settings_can_contain_keys.md` — don't `cat` settings files
  during HA debugging

### Files this design touches (if you proceed)

- **No new HA YAML.** Everything Phase 2 needs already exists.
- **No new overlays.** Same `waste_collection_schedule` 2.24.0 derivation.
- Node-RED tab `9fc588ef6d4255d1` (Home) — add 1 delay, 1 api-current-state, 1
  chronos-repeat, 1 light.turn_on, 1 server-state-changed (or trigger),
  1 light.turn_off, 1 chronos cutoff. ~7 new nodes.
- Tell Claude the bulb's entity ID and which room/desk it's near.

---

## Quick smoke test (Phase 1, anytime)

1. Set `input_boolean.trash_taken_out` to `off` via Dev Tools.
2. Trigger the chronos-scheduler manually (double-click in Node-RED editor →
   Inject tab → fire button next to the schedule entry).
3. If `daysTo == 1` on any of garbage/recycling/organics: TTS plays, push
   arrives with Mark Done.
4. Tap Mark Done. Verify `input_boolean.trash_taken_out` is now `on` in HA
   history.
5. If nothing happens, the function node-status will show "no pickup
   tomorrow" — that means no bin has daysTo=1 today, which is the right
   no-op. Wait until the day before an actual pickup to retest.
