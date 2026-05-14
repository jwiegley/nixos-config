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

-- Grant the grafana role read-only access for the inspection dashboard.
GRANT USAGE ON SCHEMA public TO grafana;
GRANT SELECT ON msg_events TO grafana;
GRANT SELECT ON audit_events TO grafana;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana;

-- Initial partition for the current month
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
