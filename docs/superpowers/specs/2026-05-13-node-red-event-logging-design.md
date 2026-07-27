# Node-RED Event Logging — As-Shipped Design

> **Archival — 2026-05-13.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/node-red-event-logger.nix`).

Shipped 2026-05-13. Plan: `docs/superpowers/plans/2026-05-13-node-red-event-logging.md`.

Captures every message that traverses Node-RED plus all admin/audit events
into PostgreSQL, with a Grafana dashboard for inspection. The system is live;
`msg_events` and `audit_events` are accumulating rows in real time.

## Architecture

Three independent producers feed two PostgreSQL tables in a dedicated
database `nodered_events`:

```
┌──────────────────────────────────┐
│ Node-RED runtime (settings.js)   │
│                                  │
│  ┌──────────────────────────┐    │      ┌─────────────────────┐
│  │ event-logger plugin      │────┼──┐   │ PostgreSQL          │
│  │  - RED.hooks.add onSend  │    │  │   │  nodered_events DB  │
│  │  - RED.hooks.add onComp. │    │  ├──→│                     │
│  │  - 200ms batched flush   │    │  │   │  msg_events         │
│  └──────────────────────────┘    │  │   │   (partitioned by   │
│                                  │  │   │    month on ts)     │
│  ┌──────────────────────────┐    │  │   │                     │
│  │ logging.dbAudit handler  │────┼──┘   │  audit_events       │
│  │  - one row per log event │    │      │                     │
│  └──────────────────────────┘    │      └─────────────────────┘
└──────────────────────────────────┘               │
                                                    │
                                       ┌────────────┴────────────┐
                                       │  Grafana                │
                                       │   nodered_events DS     │
                                       │   "Node-RED Events" DB  │
                                       └─────────────────────────┘

┌──────────────────────────────────┐
│ systemd timer (daily 03:30)      │
│  node-red-event-logger-rotate    │
│   - create next-month partition  │
│   - drop msg_events parts >30d   │
│   - DELETE audit_events >90d     │
└──────────────────────────────────┘
```

Both writers connect to PostgreSQL over the local Unix socket
(`/run/postgresql`) using peer authentication as the `node-red` system user.
Grafana reads via its own `grafana` PG role (peer auth, SELECT-only).
No passwords on either side.

## Database schema

### `msg_events` — message hook events (partitioned)

| Column         | Type         | Purpose                                                    |
|----------------|--------------|------------------------------------------------------------|
| `id`           | BIGSERIAL    | Per-partition sequence; not globally unique                |
| `ts`           | TIMESTAMPTZ  | Partition key, time of event                               |
| `hook`         | TEXT         | `onSend` or `onComplete`                                   |
| `msgid`        | TEXT         | Node-RED `msg._msgid`; the trace correlator                |
| `tab_id`       | TEXT         | Flow tab containing the node (`srcNode.z`)                 |
| `node_id`      | TEXT         | Source node id                                             |
| `node_type`    | TEXT         | e.g. `inject`, `function`, `api-current-state`             |
| `node_name`    | TEXT         | Node's user-visible name                                   |
| `topic`        | TEXT         | `msg.topic` if present                                     |
| `payload`      | JSONB        | `msg.payload`, JSON-serialized, truncated to 4 KB          |
| `payload_size` | INT          | Original byte size before truncation                       |
| `error`        | TEXT         | `event.error` from `onComplete`, when present              |

Indexes: `(ts)`, `(msgid)`, `(node_id)`.

Partitioned `BY RANGE (ts)` with monthly children named
`msg_events_YYYY_MM`. The initial partition is created by `schema.sql`; the
next-month partition is created proactively by the daily rotation timer.

### `audit_events` — admin/runtime events (non-partitioned)

| Column    | Type         | Purpose                                                |
|-----------|--------------|--------------------------------------------------------|
| `id`      | BIGSERIAL    | Primary key                                            |
| `ts`      | TIMESTAMPTZ  | Event time                                             |
| `level`   | INT          | Node-RED log level (info/warn/error/audit)             |
| `type`    | TEXT         | Log type field (e.g. `comms`, `flows`)                 |
| `event`   | TEXT         | Event name (e.g. `runtime.started`, `flows.deploy`)    |
| `name`    | TEXT         | Optional name field from log record                    |
| `node_id` | TEXT         | When the event names a specific node                   |
| `msg`     | TEXT         | Human-readable message (or JSON-stringified object)    |
| `"user"`  | TEXT         | Username from `msg.user.username` if present           |

Indexes: `(ts)`, `(event)`.

## Retention policy

Implemented by `systemd.timers.node-red-event-logger-rotate` running daily at
03:30 with `Persistent = true`. The unit invokes
`config/node-red-event-logger/rotate.sql`:

- **`msg_events`** — partitions whose month-end is older than 30 days are
  dropped with `DROP TABLE`. Cheap, no row-by-row delete.
- **`audit_events`** — `DELETE FROM audit_events WHERE ts < now() -
  INTERVAL '90 days'`. The audit table is small and non-partitioned, so a
  row-by-row delete is fine.
- The same script also creates next month's partition idempotently
  (`CREATE TABLE IF NOT EXISTS ... PARTITION OF msg_events`), so we never
  miss a month roll-over even if the host is offline at midnight.

## Hook strategy: only `onSend` and `onComplete`

Node-RED 4.x exposes seven hooks on `RED.hooks`: `preRoute`, `onSend`,
`postSend`, `preDeliver`, `postDeliver`, `onReceive`, `onComplete`. We
deliberately only register two:

- **`onSend`** fires once when a node hands a message to the runtime
  (before fan-out to wires).
- **`onComplete`** fires once when downstream processing finishes
  (including errors).

Every other hook is a per-wire amplification of the same logical message.
A four-wire fan-out produces 1 `onSend` + 4 `preDeliver`/`postDeliver`/
`onReceive` rows per downstream node. With the deliver/receive triplet
firing per wire, write volume is roughly 10–15× higher for no additional
diagnostic value: `onSend` already tells you the message left, `onComplete`
already tells you it arrived (or errored). The two-hook strategy keeps
write rate manageable while still letting `msgid` reconstruct the full
chain across nodes.

### Non-obvious shape of `onComplete` events

NR 4.x passes `onComplete` with `event.node = { id, node }` — the real
node is nested at `event.node.node`. Without unwrapping that, every
`onComplete` row would have NULL `tab_id`, `node_type`, `node_name`.
The plugin unwraps explicitly. See `index.js` comment near the
`RED.hooks.add('onComplete', ...)` registration.

## Where to look for what

- **"Why did node X fire?"** → `msg_events` filtered by `msgid` — see
  inspection queries below.
- **"What broke?"** → `msg_events WHERE error IS NOT NULL`, or the Grafana
  "Recent errors" panel.
- **"What was deployed and when?"** → `audit_events` filtered by
  `event LIKE 'flows.%'`.
- **"Is the runtime alive?"** → Node-RED's own `systemctl status node-red`
  and `journalctl -u node-red` are unchanged; the console handler still
  writes to the journal as before.
- **Grafana dashboard** — https://grafana.vulcan.lan, "Node-RED Events".
  Three panels: events/sec time series, recent errors table, msgid trace
  lookup (driven by a textbox dashboard variable).

## Operational notes

- **Payload truncation: 4 KB, byte-accurate.** `serializePayload()` in
  `index.js` measures via `Buffer.byteLength(s, 'utf8')`. When over the
  cap, the buffer is sliced with `Buffer.subarray()` (not `String.slice`)
  to avoid character-based truncation surprises on multi-byte UTF-8;
  partial multi-byte sequences resolve to U+FFFD. The `payload_size`
  column always carries the original (pre-truncation) byte count, so
  downstream queries can spot oversized messages without re-decoding.
- **Batched writes.** 200 ms flush interval, 500 rows per INSERT. The
  Postgres parameter limit is 65535; at 10 columns per row, 500 rows ×
  10 = 5000 params, comfortably bounded.
- **Bounded queue.** `MAX_QUEUE = 50000` rows in memory. On flush
  failure, the batch is unshifted back to the front and `queue.length` is
  truncated to the cap (oldest dropped). At ~4 KB/row worst case this
  caps in-process memory near 200 MB even during a sustained Postgres
  outage.
- **Tight PG timeouts.** `connectionTimeoutMillis: 5000` and
  `query_timeout: 5000` so a stuck PG doesn't pin a Node-RED event-loop
  tick indefinitely.
- **NODE_PATH=/var/lib/node-red/node_modules** is set on the
  `node-red.service` unit via `node-red-event-logger.nix`. This is
  load-bearing — see "Lessons learned" below.
- **No password anywhere.** Both the plugin and the audit handler open
  Postgres connections over the local Unix socket and authenticate via
  Unix peer auth on the `node-red` PG role. Grafana uses its own
  `grafana` role the same way. SOPS is not involved.

## Inspection queries

```sql
-- "Why did this node fire?" — full chain by msgid
SELECT ts, hook, node_type, node_name, topic, payload
FROM msg_events WHERE msgid = :msgid ORDER BY ts;

-- "What broke in the last hour?"
SELECT ts, node_type, node_name, error
FROM msg_events
WHERE error IS NOT NULL AND ts > now() - INTERVAL '1 hour'
ORDER BY ts DESC;

-- "Which nodes are the chattiest?"
SELECT node_type, node_name, count(*) AS events
FROM msg_events WHERE ts > now() - INTERVAL '1 day'
GROUP BY 1, 2 ORDER BY events DESC LIMIT 20;

-- "Did something change recently?" — correlate with deploys
SELECT ts, event, msg
FROM audit_events
WHERE event LIKE 'flows.%' AND ts > now() - INTERVAL '1 day'
ORDER BY ts DESC;
```

## Lessons learned

Two non-obvious bumps surfaced during implementation and are worth
preserving:

1. **Node-RED 4.x's plugin loader scans `userDir/node_modules`, not
   `userDir/plugins`.** The original plan deployed the plugin into
   `/var/lib/node-red/plugins/event-logger/`; Node-RED never picked it
   up. The shipped layout copies the plugin to
   `/var/lib/node-red/node_modules/node-red-event-logger/` (a real
   directory, not a symlink). NixOS module copies files in via a
   pre-`node-red.service` oneshot, and `restartTriggers` on
   `node-red.service` ties to the plugin store path so any source change
   forces a Node-RED restart with the new module.
2. **Node's `realpath()` breaks `require('pg')` from `/nix/store`.** The
   resolver canonicalizes file paths before walking up looking for
   `node_modules`. A `/nix/store` symlink target means the walk starts
   under `/nix/store/...-node-red-event-logger/`, where no `pg` exists.
   Two fixes are in place: (a) the plugin is copied (not symlinked) so
   it lives at a real `/var/lib/node-red/node_modules/...` path, and
   (b) `settings.js` is itself loaded out of `/nix/store`, so
   `NODE_PATH=/var/lib/node-red/node_modules` is set in the systemd
   unit so the bare-name `require('pg')` in the audit handler resolves.

## Files and their purposes

- `modules/services/node-red-event-logger.nix` — NixOS module: plugin
  install oneshot, schema migration unit, daily rotation timer +
  service, `NODE_PATH` env on `node-red.service`, `restartTriggers`
  binding plugin source to runtime restart.
- `modules/services/databases.nix` — adds the `nodered_events` database
  and the `node-red` and `grafana` Postgres roles; adds the
  `local nodered_events node-red peer` and `grafana` peer-auth lines to
  the `authentication` block.
- `modules/services/grafana.nix` — registers the `nodered_events`
  Postgres datasource and adds the dashboard JSON entry to
  `localDashboards`.
- `modules/monitoring/dashboards/node-red-events.json` — the three-panel
  Grafana dashboard (events/sec, recent errors, msgid trace).
- `config/node-red-event-logger/package.json` — plugin manifest
  (Node-RED 3+ format with the `node-red.plugins` key).
- `config/node-red-event-logger/index.js` — plugin source: hook
  registration, batching, serializer, queue management.
- `config/node-red-event-logger/schema.sql` — DDL applied on every
  rebuild by the schema migration unit (idempotent).
- `config/node-red-event-logger/rotate.sql` — DDL run by the daily
  rotation timer (idempotent; creates next month, drops >30d, deletes
  >90d audit).
- `config/node-red-settings.js` — adds the `dbAudit` handler in the
  `logging` block alongside the existing `console` handler.

## Tuning knobs (post-deploy)

- **Write rate** — default 200 ms / 500 rows. If `msg_events` exceeds
  ~100 MB/day, raise flush to 1 s or strip `onSend` and keep only
  `onComplete`.
- **Payload truncation** — `MAX_PAYLOAD_BYTES = 4096` in `index.js`.
- **Retention** — 30 d msg, 90 d audit, both in `rotate.sql`.
- **Per-tab opt-out** — not built in; add a `srcNode.z` denylist check
  inside `record()` if a noisy flow becomes a problem.
