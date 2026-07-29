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

Metrics emitted:
  hass_entity_unavailable_total          entities whose latest state is unavailable/unknown
  hass_entity_unavailable{category=...}  duplicate_twin | mail_and_packages | other
  hass_entity_unavailable_by_domain{...} per HA domain (calendar, sensor, ...)
  hass_entity_tracked_total              all entities the recorder knows about
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
    os.chmod(OUT, 0o644)  # counts only, no entity names, no secrets


def main() -> int:
    out = []
    for name, help_text, kind in HELP:
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} {kind}")

    try:
        entities = _psql(QUERY_UNAVAILABLE)
        tracked = int(_psql(QUERY_TRACKED)[0])
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
    out.append("hass_entity_exporter_success 1")
    out.append(f"hass_entity_exporter_timestamp_seconds {time.time():.0f}")
    _emit(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
