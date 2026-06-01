# Home Assistant Alerting & Monitoring

> **STATUS (2026-06-01): The Prometheus HA alert rules described historically below
> were REMOVED — they could never fire.** Home Assistant telemetry is *pushed* to
> **VictoriaMetrics** via the InfluxDB line protocol; it is **never scraped into
> Prometheus**. The rules referenced `homeassistant_*` metric names that have no
> backing series in Prometheus, so all 23 sat permanently `state=inactive`. HA
> safety/security/energy alerting now lives in **Node-RED**, which is event-driven,
> already the alert sink, and can *remediate* (not just notify). This document records
> the architecture truth, what replaced the dead rules, and the original intent (now a
> Node-RED implementation reference).

## Why the Prometheus rules were dead

| | VictoriaMetrics | Prometheus |
|---|---|---|
| HA entity state | **Yes** — pushed via InfluxDB, ~60s, 100y retention | **No** — 0 `homeassistant_*` / 0 `entity_id` series |
| Metric naming | InfluxDB-style: `state_value`, `%_value`, `kWh_value`, `ppm_value`, `degF_value`, labeled by `entity_id`+`domain` | n/a for HA |
| Role | HA historian | infra/service telemetry + alerting brain |

The `homeassistant_*` names came from an old era when HA was scraped into Prometheus.
Once HA moved to pushing VictoriaMetrics, those names stopped existing in Prometheus
and the alert rules became no-ops. Removing them changes **no** live behavior. (Full
analysis: the TSDB overlap study, 2026-05-31.)

## Where HA safety alerting lives now: Node-RED

Node-RED is the right home: it consumes HA's state-change stream in real time (lower
latency than vmalert-over-VM-over-InfluxDB-push), it is already the Alertmanager→iPhone
sink (`Alert Notifier` tab), and it can take *action* — it already locks doors on
departure and shuts the pool heater on low-flow.

**Redeploy/restart durability:** dwell timers ("door open for 15 min") are NOT held in
in-memory `setTimeout`/`trigger` state (which resets on every flow redeploy). They use
the **persisted flow-context** idiom (the same mechanism as the Pool tab's *save/restore
swim window* nodes): `flow.set('safety', …)` writes through to
`/var/lib/node-red/context/` (localfilesystem context store, 30s flush), and a periodic
scan re-evaluates dwell from that persisted map. A redeploy or a vulcan restart does not
drop a pending alert window.

### Existing Node-RED coverage (pre-2026-06)

- **Door-device low battery** — Home tab, `sensor.{front_door,side_door,garage}_battery < 20%` → notify.
- **Pool salinity low** — Pool tab, `sensor.intellichlor_1_salt` → email + notify.
- **Pool heater low water flow** — dedicated *Pool Heater Alarm* tab (IntelliCenter
  UltraTemp Low Water Flow → turn off heater + notify, auto-disarm).
- **Departure security** — *Away* tab: on everyone-away, lock doors + ADT arm away +
  HVAC off/eco (proactive remediation).
- **Flume leak false-positive suppression** — the `flume-data` Postgres DB +
  `flume_data/classify_v2.py` classifier reads HA state to suppress spurious leaks.

### New `HA Safety` tab (the gap-closers)

These are the concerns that had **no** replacement after the Prometheus rules were
removed. Implemented as a single persist-and-scan flow (one `server-state-changed`
feeding a persisted `flow.safety` map; a 1-minute `chronos` scan evaluates dwell):

| Alert | Entity | Bad state | Dwell | Severity |
|---|---|---|---|---|
| Water leak | `binary_sensor.flume_sensor_sierra_oaks_leak_detected` | on | immediate | critical |
| High water flow (burst pipe) | `binary_sensor.flume_sensor_sierra_oaks_high_flow` | on | 2m | critical |
| Door left open | `binary_sensor.{front_door,garage,side_door}_door` | open | 15m → 30m | warning → critical |
| Door left unlocked | `lock.{front_door,garage,side_door}` | unlocked | 30m | critical |
| Door unlocked, everyone away | locks + `binary_sensor.everyone_away` | unlocked + away | 5m | critical |
| Door open, everyone away | doors + `binary_sensor.everyone_away` | open + away | 10m | critical |
| Flume sensor offline | `binary_sensor.flume_sensor_sierra_oaks_connectivity` | disconnected | 10m | warning |
| Flume battery low | `binary_sensor.flume_sensor_sierra_oaks_battery` | on | 1h | warning |
| Solar production low | `sensor.envoy_202332010883_energy_production_today` | < 0.5 kWh, 10:00–15:00 | 30m | warning |
| Freeze warning | `binary_sensor.freeze` | on | 10m | info |

**Deferred** (lower value; build later if wanted): dishwasher problem/door, iPhone
battery low, HVAC-running-with-door-open, pool temperature deviation, critical-device
offline.

**Dropped as dead** (no telemetry in *either* TSDB — the Traeger entities don't exist):
the four grill rules (`GrillTemperatureDangerouslyHigh`, `GrillOnNobodyHome`,
`GrillLeftOnExtended`, `GrillNeedsCleaning`).

## Original Prometheus rule intent (historical reference)

The 23 removed rules and their thresholds are preserved in git history at
`modules/monitoring/alerts/home-assistant.yaml` (last present before the 2026-06-01
removal commit). They informed the `HA Safety` tab above. Note two correctness fixes
that were applied during migration: pool/probe temperatures are stored in **°F** in
VictoriaMetrics (the old rules' Celsius thresholds were wrong), and the grill rules were
dropped because their entities never existed.
