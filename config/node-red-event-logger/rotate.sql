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
