"""Export Home Assistant entity availability as node-exporter textfile metrics.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add one
here or flake8 flags it as E265.

WHY THIS EXISTS, AND WHY IT SHIPS WITHOUT AN ALERT
--------------------------------------------------
197 HA entities are currently unavailable/unknown and nothing measured that, so the number
could drift indefinitely without anyone noticing. This collector makes it observable.

It deliberately ships with NO alert rule. Plan item D9 (clean up the entity debris) is the
prerequisite, and it is operator-executed. A threshold fitted to today's baseline would
encode ~33 known-dead duplicate twins as "normal", which manufactures exactly the dead-rule
class the surrounding effort exists to remove. Ship the metric, let the operator clean up,
observe the post-cleanup baseline, and only then set a threshold. See
docs/HA_ENTITY_WORKLIST_2026-07-29.md for the concrete cleanup list.

WHY THE RECORDER DATABASE RATHER THAN THE HA API
------------------------------------------------
The REST API needs a long-lived token, which would mean plumbing another secret for a
read-only health count. The recorder database is already on this host and reachable with
peer auth as the postgres user, so this needs no credential at all.

WHY max()/GROUP BY AND NOT DISTINCT ON
--------------------------------------
Measured on the live table (3.8M rows, 1243 MB): the obvious `DISTINCT ON (metadata_id)
... ORDER BY state_id DESC` form takes 2.30-2.33 s, while the `state_id IN (SELECT
max(state_id) ... GROUP BY metadata_id)` form takes 0.19-0.22 s -- about 11.5x faster. Both
return the same count. Do not "optimise" this into DISTINCT ON.

FIGURE CORRECTED: a first measurement recorded 5.42 s for DISTINCT ON and claimed 26x. That
was a COLD-CACHE artifact of running it first. Re-timed twice in each order, the steady-state
ratio is ~11.5x and is order-independent, which makes the conclusion stronger than the
original inflated number did -- but the original number was wrong.

Correctness of this form is not just empirical: `states.state_id` is an IDENTITY bigint, so it
increases monotonically with insertion order, which is why max(state_id) is the newest row.
Confirmed against live data too -- comparing max(state_id) per entity against the row with the
newest last_updated_ts gives 0 disagreements across all entities.

WHY A STALENESS GAUGE FOR NAMED ENTITIES (added 2026-08-30)
-----------------------------------------------------------
The alarmdotcom integration froze from 2026-08-28 00:39 to 2026-08-30 11:44. The alarm panel
kept reporting `armed_night` the whole time, so Home Assistant showed the house as armed while
nothing was updating. It surfaced only because the operator noticed by eye, two days late.

Nothing on this host could have caught it, and that is not for want of monitoring -- every
cheaper signal was tested against this incident and none of them move:

  hass_config_entries{domain="alarmdotcom"}   stayed state="loaded" throughout
  entity state                                stayed a real state, never `unavailable`
  integration logs                            ZERO lines in 7 days, no exception, no reauth
  last_reported (REST)                        equals last_changed for this entity; only
                                              59 of 1292 entities advance it at all
  homeassistant.update_entity                 returns HTTP 200 and refreshes nothing

That leaves time-since-last-state-change, which is a blunt instrument and is why this is an
ALLOWLIST rather than a blanket per-entity metric: it is only meaningful for entities whose
real-world cadence is known, and the label is per-entity so cardinality must stay bounded.

Metrics emitted:
  hass_entity_unavailable_total          entities whose latest state is unavailable/unknown
  hass_entity_unavailable{category=...}  duplicate_twin | mail_and_packages | other
  hass_entity_unavailable_by_domain{...} per HA domain (calendar, sensor, ...)
  hass_entity_tracked_total              all entities the recorder knows about
  hass_entity_seconds_since_change{entity_id=...}  age of the newest state row, allowlist only
  hass_entity_present{entity_id=...}     1 if the allowlisted entity exists in the recorder
  hass_entity_exporter_success           0 if this collector could not read the database
  hass_entity_exporter_timestamp_seconds
"""

import collections
import os
import re
import subprocess
import sys
import time

OUT = os.environ.get(
    "TEXTFILE_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/hass_entity_availability.prom",
)
DB = os.environ.get("HASS_DB", "hass")

# Latest state per entity. See the module docstring for why this shape and not DISTINCT ON.
QUERY_UNAVAILABLE = """
SELECT sm.entity_id
FROM states s
JOIN states_meta sm ON sm.metadata_id = s.metadata_id
WHERE s.state_id IN (SELECT max(state_id) FROM states GROUP BY metadata_id)
  AND s.state IN ('unavailable', 'unknown');
"""
QUERY_TRACKED = "SELECT count(*) FROM states_meta;"

# Entities whose silence is itself a fault. Keep this list SHORT and justified: each entry
# adds a per-entity label, and a threshold is only defensible for an entity whose normal
# cadence has actually been measured (see the alert rule in alerts/hass-integrations.yaml).
#
# alarm_control_panel.panel -- the Alarm.com / ADT panel. Measured over 97 transitions in the
# 30-day recorder window: p50 4.9h, p90 13.8h, p95 15.1h, p99 47.1h, max 68.2h.
CRITICAL_ENTITIES = ("alarm_control_panel.panel",)

# max(last_updated_ts) per entity, restricted to the allowlist. This does NOT need the
# max(state_id) subquery the unavailable query uses: that one has to find the newest row for
# EVERY entity, whereas this filters to a handful by entity_id first, so it is an indexed
# lookup over a few thousand rows.
QUERY_CRITICAL_AGE = """
SELECT sm.entity_id, max(s.last_updated_ts)
FROM states s
JOIN states_meta sm ON sm.metadata_id = s.metadata_id
WHERE sm.entity_id IN ({placeholders})
GROUP BY sm.entity_id;
"""

# A numeric suffix is how HA disambiguates a re-registered entity, so `calendar.family_2`
# sitting alongside a live `calendar.family` is re-registration debris rather than a real
# outage. Distinguishing these is the whole point of the category split: without it the
# headline number conflates dead bookkeeping with genuinely broken devices.
TWIN = re.compile(r"_\d+$")
# Host-specific: the mail_and_packages integration derives its entity prefix from the IMAP
# host, which is imap.vulcan.lan here. Matching on that is why this stays a pattern rather
# than a proper integration lookup -- the recorder schema does not record which integration
# owns an entity, only the entity_id.
MAIL_PKG = "imap_vulcan_lan"

HELP = [
    ("hass_entity_unavailable_total",
     "Entities whose latest recorded state is unavailable or unknown", "gauge"),
    ("hass_entity_unavailable",
     "Unavailable entities split by cause category", "gauge"),
    ("hass_entity_unavailable_by_domain",
     "Unavailable entities per Home Assistant domain", "gauge"),
    ("hass_entity_tracked_total",
     "Entities the recorder database knows about", "gauge"),
    ("hass_entity_seconds_since_change",
     "Seconds since an allowlisted critical entity last changed state", "gauge"),
    ("hass_entity_present",
     "1 if an allowlisted critical entity exists in the recorder", "gauge"),
    ("hass_entity_exporter_success",
     "1 if this collector read the recorder database successfully", "gauge"),
    ("hass_entity_exporter_timestamp_seconds",
     "Unix time of the last collector run", "gauge"),
]


def _psql(sql: str) -> list:
    proc = subprocess.run(
        ["psql", "-d", DB, "-tAc", sql],
        capture_output=True, text=True, timeout=120, check=True,
    )
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _emit(lines: list) -> None:
    tmp = f"{OUT}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT)  # same directory, so rename(2): never a torn read
    # Counts, HA domains, and the CRITICAL_ENTITIES allowlist -- no secrets. The allowlist is
    # the only place entity names appear, which is why it is a fixed module constant rather
    # than anything derived from the database.
    os.chmod(OUT, 0o644)


def main() -> int:
    out = []
    for name, help_text, kind in HELP:
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} {kind}")

    try:
        entities = _psql(QUERY_UNAVAILABLE)
        tracked = int(_psql(QUERY_TRACKED)[0])
        # Quoting is safe by construction: CRITICAL_ENTITIES is a module constant of HA
        # entity_ids, never user input, and psql runs with -tAc so there is no shell layer.
        placeholders = ", ".join(f"'{e}'" for e in CRITICAL_ENTITIES)
        ages = {}
        for row in _psql(QUERY_CRITICAL_AGE.format(placeholders=placeholders)):
            entity, _, ts = row.partition("|")
            if ts:
                ages[entity] = float(ts)
    except Exception as exc:  # noqa: BLE001
        # Emit success=0 rather than nothing: an ABSENT metric set is indistinguishable from
        # a healthy system, which is the failure mode this whole effort exists to remove.
        print(f"hass-entity-availability-exporter: {type(exc).__name__}", file=sys.stderr)
        out.append("hass_entity_exporter_success 0")
        out.append(f"hass_entity_exporter_timestamp_seconds {time.time():.0f}")
        _emit(out)
        return 1

    cats = collections.Counter()
    domains = collections.Counter()
    for e in entities:
        domains[e.split(".", 1)[0]] += 1
        if MAIL_PKG in e:
            cats["mail_and_packages"] += 1
        elif TWIN.search(e):
            cats["duplicate_twin"] += 1
        else:
            cats["other"] += 1

    out.append(f"hass_entity_unavailable_total {len(entities)}")
    # Emit all three categories explicitly, including zeros. A category that vanishes when it
    # reaches zero looks identical to a collector that stopped reporting it.
    for cat in ("duplicate_twin", "mail_and_packages", "other"):
        out.append(f'hass_entity_unavailable{{category="{cat}"}} {cats[cat]}')
    for domain, n in sorted(domains.items()):
        out.append(f'hass_entity_unavailable_by_domain{{domain="{domain}"}} {n}')
    out.append(f"hass_entity_tracked_total {tracked}")

    # Emit a row for EVERY allowlisted entity, including ones the recorder has never heard of
    # (present=0). An entity that silently disappears from the registry would otherwise take
    # its own staleness metric with it, and a vanished series reads as healthy.
    now = time.time()
    for entity in CRITICAL_ENTITIES:
        age = ages.get(entity)
        present = 0 if age is None else 1
        out.append(f'hass_entity_present{{entity_id="{entity}"}} {present}')
        if age is not None:
            out.append(
                f'hass_entity_seconds_since_change{{entity_id="{entity}"}} {now - age:.0f}'
            )

    out.append("hass_entity_exporter_success 1")
    out.append(f"hass_entity_exporter_timestamp_seconds {time.time():.0f}")
    _emit(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
