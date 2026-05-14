# Node-RED Event Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture every message that traverses Node-RED plus all admin/audit events into PostgreSQL, with a Grafana dashboard for inspection.

**Architecture:** A Node-RED plugin under `/var/lib/node-red/plugins/event-logger/` registers two `RED.hooks` listeners (`onSend`, `onComplete`) and batches inserts into a dedicated Postgres DB `nodered_events`. A second pluggable logger handler in `settings.js` captures audit events (deploys, restarts, errors) to the same DB. Daily partitions + a retention timer keep disk usage bounded. Grafana provides the inspection UI.

**Tech Stack:** Node-RED 4.1.2 hooks API, PostgreSQL (existing service), Grafana (existing service), NixOS module system for declarative deploy, `pg` npm module (already installed via `node-red-contrib-postgresql`).

---

## File Structure

**New files:**
- `modules/services/node-red-event-logger.nix` — NixOS module: provisions plugin symlink, runs schema migrations, registers retention timer
- `config/node-red-event-logger/index.js` — plugin source: hook registration + batched writer
- `config/node-red-event-logger/package.json` — plugin manifest (Node-RED 3+ format)
- `config/node-red-event-logger/schema.sql` — table DDL run by a one-shot systemd unit
- `config/node-red-event-logger/rotate.sql` — partition rotation SQL run by the timer
- `modules/monitoring/dashboards/node-red-events.json` — Grafana dashboard JSON

**Modified files:**
- `modules/services/databases.nix` — add `nodered_events` to `ensureDatabases`, add `node-red` user to `ensureUsers`, add a `local nodered_events node-red peer` line to the `authentication` block
- `config/node-red-settings.js` — replace the existing `logging:` block with one that adds the `dbAudit` handler alongside the existing `console` handler
- `modules/services/grafana.nix` — add `nodered_events` Postgres datasource and register the new dashboard in `localDashboards`
- `hosts/vulcan/default.nix` — import the new event-logger module

---

## Schema Reference

Used in Task 2 and queried by the plugin and dashboard.

```sql
CREATE TABLE IF NOT EXISTS msg_events (
    id          BIGSERIAL,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    hook        TEXT NOT NULL,                    -- 'onSend' | 'onComplete'
    msgid       TEXT,
    tab_id      TEXT,
    node_id     TEXT,
    node_type   TEXT,
    node_name   TEXT,
    topic       TEXT,
    payload     JSONB,                            -- truncated to 4 KB serialized
    payload_size INT,                             -- bytes before truncation
    error       TEXT
) PARTITION BY RANGE (ts);

CREATE INDEX IF NOT EXISTS msg_events_ts_idx     ON msg_events (ts);
CREATE INDEX IF NOT EXISTS msg_events_msgid_idx  ON msg_events (msgid);
CREATE INDEX IF NOT EXISTS msg_events_node_idx   ON msg_events (node_id);

CREATE TABLE IF NOT EXISTS audit_events (
    id      BIGSERIAL PRIMARY KEY,
    ts      TIMESTAMPTZ NOT NULL DEFAULT now(),
    level   INT,
    type    TEXT,
    event   TEXT,
    name    TEXT,
    node_id TEXT,
    msg     TEXT,
    "user"  TEXT
);
CREATE INDEX IF NOT EXISTS audit_events_ts_idx    ON audit_events (ts);
CREATE INDEX IF NOT EXISTS audit_events_event_idx ON audit_events (event);

-- Grant the node-red role write access. Tables are owned by `postgres`
-- (the schema migration runs as postgres); node-red has INSERT only,
-- which is exactly what the plugin needs.
GRANT USAGE ON SCHEMA public TO "node-red";
GRANT INSERT ON msg_events TO "node-red";
GRANT INSERT ON audit_events TO "node-red";
-- BIGSERIAL needs sequence USAGE for the implicit nextval()
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO "node-red";
-- Future partitions of msg_events inherit ACLs from the parent, so no
-- per-partition GRANT is needed at rotation time.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT INSERT ON TABLES TO "node-red";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE ON SEQUENCES TO "node-red";
```

Partition strategy: monthly partitions named `msg_events_YYYY_MM`, created by retention timer. Default retention: 30 days (drop partitions older than that).

---

## Task 1: Provision Postgres database and user

**Files:**
- Modify: `modules/services/databases.nix:129-165`

- [ ] **Step 1: Add nodered_events to ensureDatabases**

Edit `modules/services/databases.nix`. In the `ensureDatabases` list (around line 129), add `"nodered_events"` as a new entry alongside the existing ones.

- [ ] **Step 2: Add node-red user to ensureUsers**

In the `ensureUsers` list (around line 141), add:

```nix
{ name = "node-red"; }
```

Do **not** set `ensureDBOwnership = true`. The NixOS Postgres module enforces `user_name == database_name` when ownership is requested, and we deliberately want a verbose database name (`nodered_events`) with a system-username-derived role name (`node-red`). Tables will be owned by the `postgres` superuser (the schema migration in Task 2 runs as `postgres`); the `node-red` role gets explicit `INSERT` grants in `schema.sql`. This is the same precedent the existing `openclaw` role follows.

- [ ] **Step 3: Add peer-auth rule for node-red on the unix socket**

Locate the `authentication = lib.mkOverride 10 '' ... ''` block in `databases.nix` (around line 180). The current rules send all non-postgres local users to `scram-sha-256`. Add a peer-auth carve-out so the `node-red` system user can connect to `nodered_events` without a password, matching the pattern used for `immich`.

Insert this line **before** the `local   all       all                     scram-sha-256` line:

```
        local   nodered_events  node-red                peer
```

The final ordering of the relevant lines should be:

```
        local   all       postgres                peer
        local   immich    immich                  peer
        local   nodered_events  node-red                peer
        local   all       all                     scram-sha-256
```

- [ ] **Step 4: Rebuild and verify**

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
sudo -u postgres psql -c "\l nodered_events"
sudo -u postgres psql -c "\du node-red"
```

Expected: `nodered_events` listed; `node-red` shown as a role.

- [ ] **Step 5: Verify peer-auth login works as node-red user**

```bash
sudo -u node-red psql -d nodered_events -c "SELECT current_user, current_database();"
```

Expected output: `node-red | nodered_events` with no password prompt.

- [ ] **Step 6: Commit**

```bash
git add modules/services/databases.nix
git commit -m "feat(postgres): provision nodered_events database for Node-RED audit log"
```

---

## Task 2: Schema migration unit

**Files:**
- Create: `config/node-red-event-logger/schema.sql` (use the SQL block from "Schema Reference" above, verbatim)
- Create: `modules/services/node-red-event-logger.nix` (skeleton with schema migration unit only)

- [ ] **Step 1: Write the schema file**

Create `config/node-red-event-logger/schema.sql` with the DDL from the Schema Reference section. Add one extra statement at the end to create the initial partition:

```sql
DO $$
DECLARE
    p_name TEXT;
    p_start DATE;
    p_end DATE;
BEGIN
    p_start := date_trunc('month', now())::date;
    p_end := (p_start + INTERVAL '1 month')::date;
    p_name := 'msg_events_' || to_char(p_start, 'YYYY_MM');
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF msg_events FOR VALUES FROM (%L) TO (%L)',
        p_name, p_start, p_end
    );
END $$;
```

- [ ] **Step 2: Create initial NixOS module skeleton with schema migration**

Create `modules/services/node-red-event-logger.nix`:

```nix
{ config, pkgs, lib, ... }:

let
  schemaSql = ../../config/node-red-event-logger/schema.sql;
in
{
  systemd.services.node-red-event-logger-schema = {
    description = "Apply Node-RED event-logger schema migrations";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql -d nodered_events -v ON_ERROR_STOP=1 -f ${schemaSql}
    '';
  };
}
```

- [ ] **Step 3: Import module into the host's NixOS configuration**

The host entry-point is `hosts/vulcan/default.nix`. Open it and find the `imports = [ ... ]` block (around line 9). Existing node-red modules are imported around line 88. Add a new entry alongside them:

```nix
    ../../modules/services/node-red-event-logger.nix
```

- [ ] **Step 4: Rebuild and verify schema is applied**

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
sudo systemctl status node-red-event-logger-schema
sudo -u postgres psql -d nodered_events -c "\dt+"
```

Expected: `msg_events` (partitioned, 0 rows), `audit_events`, and one initial partition `msg_events_YYYY_MM`.

- [ ] **Step 5: Commit**

```bash
git add modules/services/node-red-event-logger.nix config/node-red-event-logger/schema.sql hosts/vulcan/default.nix
git commit -m "feat(node-red): event-logger schema migration unit"
```

---

## Task 3: Plugin source

**Files:**
- Create: `config/node-red-event-logger/package.json`
- Create: `config/node-red-event-logger/index.js`

- [ ] **Step 1: Write the plugin manifest**

Create `config/node-red-event-logger/package.json`:

```json
{
  "name": "node-red-event-logger",
  "version": "0.1.0",
  "description": "Logs all Node-RED message events and errors to PostgreSQL via the Hooks API",
  "main": "index.js",
  "node-red": {
    "plugins": {
      "event-logger": "index.js"
    }
  },
  "keywords": ["node-red", "plugin"]
}
```

- [ ] **Step 2: Write the plugin source**

Create `config/node-red-event-logger/index.js`:

```javascript
'use strict';

const { Pool } = require('pg');

const MAX_PAYLOAD_BYTES = 4096;
const FLUSH_INTERVAL_MS = 200;
const MAX_BATCH = 500;
// Bound the in-memory queue so a sustained postgres outage can't OOM Node-RED.
// At ~4 KB/row worst case this caps memory around 200 MB.
const MAX_QUEUE = 50000;

module.exports = function (RED) {
    const pool = new Pool({
        host: '/run/postgresql',
        database: 'nodered_events',
        max: 2,
        connectionTimeoutMillis: 5000,
        query_timeout: 5000,
    });

    pool.on('error', (err) => {
        RED.log.error(`[event-logger] pg pool error: ${err.message}`);
    });

    let queue = [];
    let flushing = false;

    const flush = async () => {
        if (flushing || queue.length === 0) return;
        flushing = true;
        const batch = queue.splice(0, MAX_BATCH);
        try {
            const cols = [];
            const vals = [];
            // 10 columns per row; postgres parameter limit is 65535,
            // so MAX_BATCH=500 (5000 params) is safely bounded.
            batch.forEach((row, i) => {
                const o = i * 10;
                cols.push(`($${o+1},$${o+2},$${o+3},$${o+4},$${o+5},$${o+6},$${o+7},$${o+8}::jsonb,$${o+9},$${o+10})`);
                vals.push(row.hook, row.msgid, row.tab_id, row.node_id, row.node_type,
                          row.node_name, row.topic, row.payload, row.payload_size, row.error);
            });
            await pool.query(
                `INSERT INTO msg_events (hook, msgid, tab_id, node_id, node_type, node_name, topic, payload, payload_size, error)
                 VALUES ${cols.join(',')}`,
                vals
            );
        } catch (e) {
            // Re-queue at the front so the next tick retries. Cap enforced after.
            queue.unshift(...batch);
            if (queue.length > MAX_QUEUE) queue.length = MAX_QUEUE;
            RED.log.error(`[event-logger] flush failed (${batch.length} rows requeued, queue=${queue.length}): ${e.message}`);
        } finally {
            flushing = false;
        }
    };

    setInterval(flush, FLUSH_INTERVAL_MS).unref();

    const serializePayload = (payload) => {
        if (payload === undefined || payload === null) return { json: null, size: 0 };
        let s;
        try {
            s = JSON.stringify(payload);
        } catch {
            s = String(payload);
        }
        const size = Buffer.byteLength(s, 'utf8');
        if (size > MAX_PAYLOAD_BYTES) {
            // Byte-aware truncation; partial multi-byte sequences resolve to U+FFFD.
            const buf = Buffer.from(s, 'utf8').subarray(0, MAX_PAYLOAD_BYTES - 64);
            s = JSON.stringify({ _truncated: true, preview: buf.toString('utf8') });
        }
        return { json: s, size };
    };

    const record = (hook, srcNode, msg, error) => {
        if (!srcNode) return;
        // Under sustained backpressure, drop oldest to keep memory bounded.
        if (queue.length >= MAX_QUEUE) queue.shift();
        const { json, size } = serializePayload(msg && msg.payload);
        queue.push({
            hook,
            msgid: (msg && msg._msgid) || null,
            tab_id: srcNode.z || null,
            node_id: srcNode.id || null,
            node_type: srcNode.type || null,
            node_name: srcNode.name || null,
            topic: (msg && msg.topic) || null,
            payload: json,
            payload_size: size,
            error: error ? String(error.message || error) : null,
        });
    };

    RED.hooks.add('onSend', (events) => {
        const list = Array.isArray(events) ? events : [events];
        for (const ev of list) record('onSend', ev.source && ev.source.node, ev.msg, null);
    });

    // NR 4.x: event.node is a `{id, node}` wrapper for onComplete (see
    // @node-red/runtime/lib/nodes/Node.js). The real node is at event.node.node;
    // without this unwrap, tab_id/node_type/node_name end up NULL on every row.
    RED.hooks.add('onComplete', (event) => {
        const ref = event.node;
        record('onComplete', ref && ref.node, event.msg, event.error);
    });

    RED.log.info('[event-logger] plugin loaded; hooks registered');
};
```

- [ ] **Step 3: Local smoke test of pg connect**

Verify the `pg` module is present in Node-RED's node_modules and connection works:

```bash
cd /var/lib/node-red
sudo -u node-red node -e "const {Pool} = require('pg'); const p = new Pool({host:'/run/postgresql', database:'nodered_events'}); p.query('SELECT now()').then(r=>{console.log(r.rows[0]); p.end();}).catch(e=>{console.error(e.message); process.exit(1);})"
```

Expected: prints `{ now: <timestamp> }` and exits cleanly.

- [ ] **Step 4: Commit**

```bash
git add config/node-red-event-logger/package.json config/node-red-event-logger/index.js
git commit -m "feat(node-red): event-logger plugin source"
```

---

## Task 4: Deploy plugin via NixOS module

**Files:**
- Modify: `modules/services/node-red-event-logger.nix` (add plugin deployment block)

- [ ] **Step 1: Extend the module to deploy the plugin and re-trigger Node-RED on source changes**

Replace `modules/services/node-red-event-logger.nix` with the full version below. Two key correctness details:

- The plugin directory is deployed via `systemd.tmpfiles.rules` using the `L+` (force-replace symlink) directive, pointing into the Nix store. That means: any time the plugin source changes, the Nix store path changes, the symlink target changes, and `systemd-tmpfiles` updates it on the next rebuild.
- We also add `restartTriggers` to `services.node-red`'s systemd unit so Node-RED restarts when the plugin source changes — without this, a rebuild that only changes plugin source leaves Node-RED running with the stale module loaded.

```nix
{ config, pkgs, lib, ... }:

let
  pluginSrc = pkgs.stdenv.mkDerivation {
    name = "node-red-event-logger";
    src = ../../config/node-red-event-logger;
    installPhase = ''
      mkdir -p $out
      cp $src/package.json $src/index.js $out/
    '';
  };
  pluginDest = "/var/lib/node-red/node_modules/node-red-event-logger";
  schemaSql = ../../config/node-red-event-logger/schema.sql;
in
{
  # Install the plugin via a copy (not a symlink). Why: Node.js's resolver
  # calls realpath() before module lookup, so a /nix/store symlink would
  # cause require('pg') to search /nix/store/...-node-red-event-logger/node_modules
  # — where pg does not exist. With a real file at /var/lib/node-red/node_modules/
  # node-red-event-logger/index.js, the resolver walks up one level and finds
  # /var/lib/node-red/node_modules/pg (transitive of node-red-contrib-postgresql).
  # restartTriggers on this service re-runs the copy when pluginSrc changes.
  systemd.services.node-red-event-logger-install = {
    description = "Install Node-RED event-logger plugin into userDir/node_modules";
    before = [ "node-red.service" ];
    wantedBy = [ "node-red.service" ];
    restartTriggers = [ pluginSrc ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/rm -rf ${pluginDest}
      ${pkgs.coreutils}/bin/mkdir -p ${pluginDest}
      ${pkgs.coreutils}/bin/cp ${pluginSrc}/package.json ${pluginSrc}/index.js ${pluginDest}/
      ${pkgs.coreutils}/bin/chown -R node-red:node-red ${pluginDest}
      ${pkgs.coreutils}/bin/chmod 0644 ${pluginDest}/package.json ${pluginDest}/index.js
    '';
  };

  # Restart Node-RED when plugin source changes
  systemd.services.node-red.restartTriggers = [ pluginSrc ];

  # Make modules installed into Node-RED's userDir resolvable from settings.js
  # (loaded out of /nix/store by node-red) and from any other code path whose
  # caller location isn't under /var/lib/node-red. Without this, settings.js's
  # `require('pg')` for the audit handler fails because Node walks up from
  # /nix/store, not /var/lib/node-red.
  systemd.services.node-red.environment.NODE_PATH = "/var/lib/node-red/node_modules";

  systemd.services.node-red-event-logger-schema = {
    description = "Apply Node-RED event-logger schema migrations";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql -d nodered_events -v ON_ERROR_STOP=1 -f ${schemaSql}
    '';
  };
}
```

The schema migration unit from Task 2 is rolled into this module (replace the earlier skeleton — don't duplicate). The plugin install service from the original Task 4 draft is gone; the `L+` tmpfiles rule plus `restartTriggers` handles deploy + reload deterministically.

- [ ] **Step 2: Rebuild and verify plugin lands**

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
sudo systemctl status node-red-event-logger-install
ls -la /var/lib/node-red/node_modules/node-red-event-logger/
```

Expected: `node-red-event-logger-install` is `active (exited)`. The directory is a real directory (not a symlink) owned by `node-red:node-red`, containing `package.json` and `index.js` (mode 0644).

- [ ] **Step 3: Verify plugin loads in Node-RED**

```bash
sudo journalctl -u node-red --since "2 min ago" | grep "event-logger"
```

Expected: `[event-logger] plugin loaded; hooks registered`

- [ ] **Step 4: Commit**

```bash
git add modules/services/node-red-event-logger.nix
git commit -m "feat(node-red): deploy event-logger plugin via NixOS module"
```

---

## Task 5: Add audit handler to settings.js

**Files:**
- Modify: `config/node-red-settings.js` — **replace** the existing `logging: { console: { ... } }` block (it lives around lines 141–147 today)

- [ ] **Step 1: Locate the existing logging block**

Open `config/node-red-settings.js`. There is already a `logging:` key in the exported settings object:

```javascript
    /**
     * Logging Configuration
     */
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        }
    },
```

This must be **replaced** (not duplicated) — JS objects with a duplicated key silently keep the last one, which would drop the console handler.

- [ ] **Step 2: Replace it with the combined block (console + dbAudit)**

Use Edit to swap the existing block with the following, preserving the surrounding comment header:

```javascript
    /**
     * Logging Configuration
     *
     * console:  human-readable info to journalctl/stdout
     * dbAudit:  every audit event (deploys, edits, nodes installed, runtime errors)
     *           is written to PostgreSQL nodered_events.audit_events.
     *           Hook-level message tracing is handled by the event-logger plugin.
     */
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        },
        dbAudit: {
            level: "info",
            metrics: false,
            audit: true,
            // NODE_PATH is set to /var/lib/node-red/node_modules in the
            // node-red service unit (see node-red-event-logger.nix), which
            // lets this bare-name require resolve even though settings.js
            // is loaded out of /nix/store.
            handler: function(/* settings */) {
                const { Pool } = require('pg');
                const pool = new Pool({
                    host: '/run/postgresql',
                    database: 'nodered_events',
                });
                pool.on('error', (err) => console.error('[audit] pg error:', err.message));
                return function(msg) {
                    const txt = typeof msg.msg === 'object'
                        ? JSON.stringify(msg.msg)
                        : (msg.msg == null ? null : String(msg.msg));
                    pool.query(
                        `INSERT INTO audit_events (level, type, event, name, node_id, msg, "user")
                         VALUES ($1,$2,$3,$4,$5,$6,$7)`,
                        [msg.level, msg.type || null, msg.event || null, msg.name || null,
                         msg.id || null, txt, (msg.user && msg.user.username) || null]
                    ).catch(e => console.error('[audit] insert failed:', e.message));
                };
            }
        }
    },
```

- [ ] **Step 3: Rebuild and verify Node-RED logs an audit entry on restart**

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
sleep 8
sudo -u postgres psql -d nodered_events -c "SELECT ts, level, event FROM audit_events ORDER BY ts DESC LIMIT 5;"
```

Expected: at least one row with `event` like `runtime.started` or similar, within the last minute.

- [ ] **Step 4: Commit**

```bash
git add config/node-red-settings.js
git commit -m "feat(node-red): wire audit logger handler to nodered_events"
```

---

## Task 6: Retention timer

**Files:**
- Modify: `modules/services/node-red-event-logger.nix` (add timer + service)

- [ ] **Step 1: Create the rotation SQL as a separate file**

Create `config/node-red-event-logger/rotate.sql`. This file is kept separate from the module's Nix string to avoid `${...}` interpolation foot-guns (Nix `''...''` strings interpolate `${...}` even though PG `$$...$$` does not collide today — separating files makes future edits safe by default):

```sql
-- Create next month's partition if missing
DO $$
DECLARE p_start DATE; p_end DATE; p_name TEXT;
BEGIN
    p_start := (date_trunc('month', now()) + INTERVAL '1 month')::date;
    p_end   := (p_start + INTERVAL '1 month')::date;
    p_name  := 'msg_events_' || to_char(p_start, 'YYYY_MM');
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF msg_events FOR VALUES FROM (%L) TO (%L)',
        p_name, p_start, p_end);
END $$;

-- Drop partitions whose end date is older than 30 days
DO $$
DECLARE r RECORD; cutoff DATE := (now() - INTERVAL '30 days')::date;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS part_name,
               (regexp_replace(inhrelid::regclass::text, '.*_(\d{4})_(\d{2})$', '\1-\2-01'))::date AS p_start
        FROM pg_inherits
        WHERE inhparent = 'msg_events'::regclass
    LOOP
        IF r.p_start + INTERVAL '1 month' < cutoff THEN
            EXECUTE format('DROP TABLE IF EXISTS %s', r.part_name);
        END IF;
    END LOOP;
END $$;

-- Trim audit_events to 90 days
DELETE FROM audit_events WHERE ts < now() - INTERVAL '90 days';
```

- [ ] **Step 2: Append rotate service + timer to the module**

In `modules/services/node-red-event-logger.nix`, add a `rotateSql` let-binding alongside `schemaSql`:

```nix
let
  pluginSrc = ...;  # existing
  schemaSql = ../../config/node-red-event-logger/schema.sql;
  rotateSql = ../../config/node-red-event-logger/rotate.sql;
in
```

Then append to the module body:

```nix
  systemd.services.node-red-event-logger-rotate = {
    description = "Rotate Node-RED event log partitions (create next month, drop >30d)";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql -d nodered_events -v ON_ERROR_STOP=1 -f ${rotateSql}
    '';
  };

  systemd.timers.node-red-event-logger-rotate = {
    description = "Daily Node-RED event log rotation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
    };
  };
```

- [ ] **Step 3: Rebuild and trigger rotation manually to verify**

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
sudo systemctl start node-red-event-logger-rotate
sudo systemctl status node-red-event-logger-rotate
sudo -u postgres psql -d nodered_events -c "SELECT inhrelid::regclass FROM pg_inherits WHERE inhparent = 'msg_events'::regclass;"
```

Expected: two partitions listed (current month + next month).

- [ ] **Step 4: Commit**

```bash
git add modules/services/node-red-event-logger.nix config/node-red-event-logger/rotate.sql
git commit -m "feat(node-red): retention timer for nodered_events partitions"
```

---

## Task 7: Smoke test end-to-end

**Files:** none modified — verification only.

- [ ] **Step 1: Fire the Pool Time "simulate crossing now" inject**

In the Node-RED UI: open the Pool Time tab, click the button on the `simulate crossing now` inject node.

- [ ] **Step 2: Verify chain landed in msg_events**

```bash
sudo -u postgres psql -d nodered_events -c "
SELECT ts, hook, node_type, node_name, topic, LEFT(payload::text, 80) AS payload_preview
FROM msg_events
WHERE ts > now() - INTERVAL '2 minutes'
ORDER BY ts ASC
LIMIT 20;"
```

Expected: several rows with hooks `onSend`/`onComplete`, node_type values like `inject`, `api-current-state`, `function`, etc. All sharing the same `msgid`.

- [ ] **Step 3: Verify msgid correlation works**

```bash
MSGID=$(sudo -u postgres psql -d nodered_events -At -c "SELECT msgid FROM msg_events WHERE ts > now() - INTERVAL '2 minutes' AND msgid IS NOT NULL ORDER BY ts ASC LIMIT 1;")
sudo -u postgres psql -d nodered_events -c "
SELECT ts, hook, node_type, node_name
FROM msg_events
WHERE msgid = '$MSGID'
ORDER BY ts;"
```

Expected: full chain from inject through TTS, in temporal order.

- [ ] **Step 4: Verify audit table received Node-RED start**

```bash
sudo -u postgres psql -d nodered_events -c "
SELECT ts, level, event, LEFT(msg, 80) AS msg_preview
FROM audit_events
WHERE ts > now() - INTERVAL '10 minutes'
ORDER BY ts DESC
LIMIT 10;"
```

Expected: rows present from recent Node-RED operations.

---

## Task 8: Grafana datasource and dashboard

**Files:**
- Create: `config/grafana/dashboards/node-red-events.json`
- Maybe modify: Grafana provisioning config (depends on existing setup; check `modules/monitoring/services/grafana.nix` or wherever datasources/dashboards are declared)

- [ ] **Step 1: Add nodered_events as a Grafana Postgres datasource**

Open `modules/services/grafana.nix`. Find the `services.grafana.provision.datasources.settings.datasources = [ ... ]` list (existing Postgres datasources are likely defined there). Add an entry for `nodered_events`:

```nix
{
  name = "nodered_events";
  type = "postgres";
  uid = "nodered_events";
  url = "/run/postgresql";
  user = "grafana";
  jsonData = {
    database = "nodered_events";
    sslmode = "disable";
    postgresVersion = 1500;
  };
}
```

Grafana already runs as a system user with peer-auth permissions to query Postgres on this host. If `grafana` is not already in `nodered_events`'s ACL, grant SELECT on the two tables. Add the following statement to `config/node-red-event-logger/schema.sql` (so it's idempotent and applied on every schema run):

```sql
GRANT USAGE ON SCHEMA public TO grafana;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana;
```

(If the host doesn't have a `grafana` Postgres role, check `databases.nix` for the actual user Grafana uses, and substitute.)

- [ ] **Step 2: Author the dashboard JSON**

Create `modules/monitoring/dashboards/node-red-events.json` (matches the existing convention used for `home-assistant.json`, `copyparty.json`, etc.). Use the existing `home-assistant.json` as a structural template (same datasource type, same Grafana version). Three panels:

1. **Events/sec** (time series, datasource `nodered_events`):
   ```sql
   SELECT $__timeGroup(ts, '1m') AS time, count(*) AS events
   FROM msg_events
   WHERE $__timeFilter(ts)
   GROUP BY 1 ORDER BY 1
   ```
2. **Recent errors** (table, datasource `nodered_events`):
   ```sql
   SELECT ts, node_type, node_name, error
   FROM msg_events
   WHERE error IS NOT NULL AND $__timeFilter(ts)
   ORDER BY ts DESC LIMIT 50
   ```
3. **Message trace lookup** (table, variable-driven):
   ```sql
   SELECT ts, hook, node_type, node_name, topic, payload
   FROM msg_events
   WHERE msgid = '$msgid'
   ORDER BY ts
   ```

Add a dashboard variable `msgid` (type: textbox) to drive panel 3.

- [ ] **Step 3: Register the dashboard in localDashboards**

In `modules/services/grafana.nix`, find the `localDashboards = { ... }` attribute set (around line 49). Add an entry:

```nix
"node-red-events.json" = ../monitoring/dashboards/node-red-events.json;
```

Path is relative to `modules/services/grafana.nix`, so `../monitoring/dashboards/node-red-events.json` resolves to `modules/monitoring/dashboards/node-red-events.json`.

- [ ] **Step 4: Rebuild and verify**

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
sudo systemctl status grafana
```

Open https://grafana.vulcan.lan in a browser, navigate to the new dashboard, confirm all three panels render with data.

- [ ] **Step 5: Commit**

```bash
git add modules/monitoring/dashboards/node-red-events.json modules/services/grafana.nix config/node-red-event-logger/schema.sql
git commit -m "feat(grafana): Node-RED event inspection dashboard"
```

---

## Task 9: Documentation and project memory

**Files:**
- Create: `docs/superpowers/specs/2026-05-13-node-red-event-logging-design.md` (post-hoc design spec capturing what shipped)
- Update: `/home/johnw/.claude/projects/-etc-nixos/memory/` — add a project memory entry

- [ ] **Step 1: Capture the as-shipped design**

Write `docs/superpowers/specs/2026-05-13-node-red-event-logging-design.md` summarizing:
- Architecture: plugin + audit handler + retention timer
- Database schema and retention policy
- Where to look for what (msg_events vs audit_events; Grafana panels)
- Operational notes (truncation rule, batching window, partition naming)

- [ ] **Step 2: Add project memory**

Save a project memory file at `/home/johnw/.claude/projects/-etc-nixos/memory/project_node_red_event_logging.md` with: storage location, retention policy, where to find files in this repo, how to query for a single msgid chain, where the dashboard lives.

Add a line to `/home/johnw/.claude/projects/-etc-nixos/memory/MEMORY.md` indexing it.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-13-node-red-event-logging-design.md
git commit -m "docs(node-red): event-logging design spec"
```

---

## Tradeoffs and Knobs (post-deploy tuning)

- **Write rate** — default 200 ms flush, 500-row batch. If `msg_events` grows >100 MB/day, raise flush to 1 s or cut hooks to only `onComplete`.
- **Payload truncation** — fixed at 4 KB. Change `MAX_PAYLOAD_BYTES` in `index.js` if you need more.
- **Retention** — 30 d for messages, 90 d for audit. Change the `INTERVAL` clauses in the rotate service.
- **Per-tab opt-out** — not built in; add a filter inside `record()` that checks `srcNode.z` against a denylist if a noisy flow becomes a problem.

---

## Reference: Inspection queries

Save these for daily use:

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
