#!/usr/bin/env bash
# Audit whether the Upstairs VTherm's eco setpoint actually reaches the Nest.
#
# Background: obr nixos-i4e. Setting climate.upstairs_vtherm to eco is supposed to
# push the eco setpoint (88) onto climate.upstairs. On 2026-08-17 it did not, and
# the Nest went on cooling the room to 78-82 for ten hours. The failure is SILENT --
# nothing is logged at either end -- so the only way to see it is to compare the two
# entities' recorded history.
#
# The original hypothesis (no demand => no write) was REFUTED by this audit on
# 2026-08-25: propagation succeeded at room 76.6/77.0/78.1, well below the 88
# setpoint, which is exactly the no-demand condition. What the data shows instead is
# intermittent failure of the write -- 5 of the 9 transitions needing one failed
# before 2026-08-19, and 0 of the 6 since, coinciding with the Node-RED mirror
# deployed that day. John's decision was to treat the mirror as the fix and close the
# issue after a clean run, which is what this script measures.
#
# CLASSIFICATION -- the subtlety that makes a naive version wrong. A transition where
# the Nest is ALREADY at >= the eco setpoint needs no write at all, and produces no
# rows in the window. Scoring those as failures overstated the failure count by 8 on
# the first pass. They are reported separately as no-ops.
#
# Read-only: SELECTs against the HA recorder only. Safe to run any time.

set -euo pipefail

ECO_SETPOINT="${ECO_SETPOINT:-88}"
WINDOW_SECS="${WINDOW_SECS:-600}" # how long after onset the write may land
TZ_LOCAL="America/Los_Angeles"

# Entity metadata_ids are resolved by name so this keeps working if HA renumbers them.
# One query per entity, deliberately: parsing them out of a single aggregated string
# needs a non-greedy match, and a greedy `.*\([0-9]\+\)=` silently yields the LAST
# digit of each id (1277 -> 7), which then fails in a way that looks like a missing
# entity rather than a parsing bug.
metaid() {
  sudo -u postgres psql -d hass -Atc \
    "SELECT metadata_id FROM states_meta WHERE entity_id = '$1' LIMIT 1;"
}

vt=$(metaid 'climate.upstairs_vtherm')
nest=$(metaid 'climate.upstairs')
room=$(metaid 'sensor.upstairs_temperature')

if [[ -z ${vt:-} || -z ${nest:-} || -z ${room:-} ]]; then
  echo "could not resolve entity metadata_ids (vtherm=${vt:-?} nest=${nest:-?} room=${room:-?})" >&2
  exit 1
fi

sudo -u postgres psql -d hass -Atc "
WITH v AS (
  SELECT s.last_updated_ts AS ts,
         (sa.shared_attrs::json->>'preset_mode') AS preset,
         lag((sa.shared_attrs::json->>'preset_mode'))
           OVER (ORDER BY s.last_updated_ts) AS prev
  FROM states s JOIN state_attributes sa ON sa.attributes_id = s.attributes_id
  WHERE s.metadata_id = ${vt}
    AND sa.shared_attrs::json->>'preset_mode' IS NOT NULL
),
onset AS (SELECT ts FROM v WHERE preset = 'eco' AND prev IS DISTINCT FROM 'eco')
SELECT to_char(to_timestamp(o.ts) AT TIME ZONE '${TZ_LOCAL}','YYYY-MM-DD HH24:MI'),
       (SELECT round(state::numeric,1) FROM states r
          WHERE r.metadata_id = ${room} AND r.last_updated_ts <= o.ts
            AND r.state ~ '^[0-9.]+\$'
          ORDER BY r.last_updated_ts DESC LIMIT 1),
       (SELECT (sa2.shared_attrs::json->>'temperature') FROM states n2
          JOIN state_attributes sa2 ON sa2.attributes_id = n2.attributes_id
          WHERE n2.metadata_id = ${nest} AND n2.last_updated_ts <= o.ts
          ORDER BY n2.last_updated_ts DESC LIMIT 1),
       (SELECT max((sa3.shared_attrs::json->>'temperature')::numeric) FROM states n3
          JOIN state_attributes sa3 ON sa3.attributes_id = n3.attributes_id
          WHERE n3.metadata_id = ${nest}
            AND n3.last_updated_ts BETWEEN o.ts AND o.ts + ${WINDOW_SECS})
FROM onset o ORDER BY o.ts;" |
  awk -F'|' -v eco="${ECO_SETPOINT}" '
  {
    before = $3 + 0; max = $4 + 0
    if (before >= eco)   { cls = "already-at-eco (no-op)"; noop++ }
    else if (max >= eco) { cls = "PROPAGATED";             ok++;  last_ok = $1 }
    else                 { cls = "*** FAILED ***";         bad++; last_bad = $1 }
    printf "  %s  room=%-5s  nest %s -> %s   %s\n",
           $1, $2, $3, ($4 == "" ? "(no write)" : $4), cls
  }
  END {
    needed = ok + bad
    printf "\n  %d eco onsets: %d propagated, %d failed, %d no-op (Nest already >= %s)\n",
           ok + bad + noop, ok, bad, noop, eco
    if (needed > 0)
      printf "  failure rate over transitions that needed a write: %.0f%% (%d/%d)\n",
             100 * bad / needed, bad, needed
    printf "  last failure: %s\n", (last_bad == "" ? "none in retained history" : last_bad)
    print  "\n  Closing criterion for nixos-i4e (John, 2026-08-25): treat the Node-RED"
    print  "  mirror as the fix and close once a clean run has accumulated. The last"
    print  "  known failure was 08-17 23:29; everything after 2026-08-19 has propagated."
    # Full ISO dates, not MM-DD: a MM-DD string compare would call "01-05" older
    # than "08-19" and mis-fire this banner every January, and a monitoring script
    # that cries regression on a date boundary is worse than no banner at all.
    if (bad > 0 && last_bad >= "2026-08-19")
      print "\n  REGRESSION: a failure occurred on/after 2026-08-19 -- the mirror is NOT covering it."
  }'
