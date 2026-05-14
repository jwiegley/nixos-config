'use strict';

const { Pool } = require('pg');

const MAX_PAYLOAD_BYTES = 4096;
const FLUSH_INTERVAL_MS = 200;
const MAX_BATCH = 500;

module.exports = function (RED) {
    const pool = new Pool({
        host: '/run/postgresql',
        database: 'nodered_events',
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
            RED.log.error(`[event-logger] flush failed (${batch.length} rows dropped): ${e.message}`);
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
            s = JSON.stringify({ _truncated: true, preview: s.slice(0, MAX_PAYLOAD_BYTES - 64) });
        }
        return { json: s, size };
    };

    const record = (hook, srcNode, msg, error) => {
        if (!srcNode) return;
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

    RED.hooks.add('onComplete', (event) => {
        record('onComplete', event.node, event.msg, event.error);
    });

    RED.log.info('[event-logger] plugin loaded; hooks registered');
};
