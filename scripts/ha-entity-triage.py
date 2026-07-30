#!/usr/bin/env python3
"""Group unavailable Home Assistant entities by ROOT CAUSE, not by entity.

WHY THIS EXISTS
---------------
The availability exporter (scripts/hass-entity-availability-exporter.py) answers "how many
entities are unavailable" -- a number, currently in the low 200s. Read literally that looks
like 200 manual actions, and the operator reasonably asked why any of it should be manual.
It is not 200 actions. Measured on the live recorder database on 2026-07-30, the whole set
collapses into a handful of root causes: one broken integration accounts for 26 entities,
re-registration debris for another 15, and the rest cluster into ~8 device families where
the single question is "is that device powered off?" -- for which the correct action is
usually NOTHING, because an off device reporting unavailable is right.

This script prints that decomposition, and for each group states the ONE action that
resolves it and how many entities it clears.

THE THING NEITHER THE OPERATOR NOR THE EXPORTER HAD
---------------------------------------------------
Per family: has this entity EVER reported a real state, and when did it last do so?
  * last reported on a datable day  -> a REGRESSION. Something changed then. Investigate.
  * never reported at all           -> a MISCONFIGURATION. It was never wired up.
Those two need opposite responses, and the count alone cannot tell them apart.

ONSET TIME IS A TRAP (measured, not assumed)
--------------------------------------------
The obvious "when did it break" signal is the timestamp of the unavailable state itself.
It is worthless here. On 2026-07-30, 169 of 251 unavailable entities (67%) carried a
timestamp inside the same ten-minute bucket, which lines up with the Home Assistant restart
recorded in recorder_runs (run 328, 2026-07-29 18:27 UTC). A restart marks every entity
unavailable at once, so that timestamp dates the restart, not the fault. The honest signal
is the last NON-unavailable state, which is what this script reports. The script detects
this correlation itself and says so, so nobody chases 169 phantom incidents at one minute.

TWO HISTORY HORIZONS, AND WHY BOTH ARE NEEDED
---------------------------------------------
`recorder.purge_keep_days = 30` (modules/services/home-assistant.nix), so the `states`
table only reaches back 30 days -- verified: earliest row 2026-06-30. "Never reported in
states" therefore does NOT mean never reported. The `statistics` table is not purged and
reaches back to 2023-06-09, ~3 years. Checked against live data: of 103 entities with no
good state in the 30-day window, 4 DO have long-term statistics, last written 2026-06-09 --
i.e. datable regressions that the 30-day window alone would have mislabelled as "never
configured". So both horizons are consulted.

Statistics exist only for entities that declare a state_class, so for a non-numeric entity
(calendar, switch, camera, ...) the ABSENCE of statistics is not evidence of anything. The
report distinguishes "no long-term history" from "long-term history is not possible here",
because collapsing those two is how a confident false negative gets manufactured.

WHY THE RECORDER DATABASE AND NOT THE HA API
--------------------------------------------
The REST/WebSocket API needs a long-lived token. The recorder database is on this host and
readable with peer auth as the postgres user, so this needs no credential at all, and it
never goes near /var/lib/hass/.storage (OAuth tokens). Read-only SELECTs only: this script
deletes nothing and calls no HA service. Acting on its output is the operator's decision.

WHY max()/GROUP BY AND NOT DISTINCT ON
--------------------------------------
`state_id IN (SELECT max(state_id) FROM states GROUP BY metadata_id)` is ~11.5x faster than
the equivalent `DISTINCT ON (metadata_id) ... ORDER BY state_id DESC` on this table (both
timed twice in each order, steady-state, by the sibling exporter). state_id is an IDENTITY
bigint so it rises with insertion order, which is why max(state_id) is the newest row. The
full query here, including both history joins, was timed at 0.59 s on two consecutive runs
against the live 3.8M-row table. Do not "optimise" it into DISTINCT ON.

Usage:
    sudo -u postgres python3 scripts/ha-entity-triage.py [--list] [--json]

    --list  print entity ids inside each group (default prints counts and prefixes only,
            because entity ids are mildly private device names)
    --json  machine-readable output instead of the report
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time

DB = os.environ.get("HASS_DB", "hass")

# A numeric suffix is how HA disambiguates a re-registered entity. It is only EVIDENCE of
# re-registration if the un-suffixed sibling exists and is currently healthy -- otherwise
# `sensor.zone_2` is just an entity that happens to end in a digit. base_state below is what
# separates those. This distinction matters: on 2026-07-30, 33 entities matched the suffix
# pattern but only 15 had a live base, so treating all 33 as deletable debris would have
# proposed deleting 18 entities on no evidence.
SUFFIX = re.compile(r"_\d+$")

# The recorder schema does NOT record which integration owns an entity -- only entity_id.
# So a single-integration cluster can only be recognised by a prefix known to belong to one
# integration. Keep this table to cases actually verified on this host; guessing here would
# invent root causes. mail_and_packages derives its entity prefix from the IMAP host.
INTEGRATION_PREFIXES = {
    "imap_vulcan_lan": (
        "mail_and_packages",
        "Repair or remove the mail_and_packages IMAP integration "
        "(Settings > Devices & Services). Every entity below comes from that one config "
        "entry, so one fix clears them all.",
    ),
}

# Domains where 'unknown' is the correct resting state, not a fault: a button/scene holds
# the timestamp of its last press, and a conversation/stt/tts entity has no state at all.
# Listing these prevents the report proposing action on entities that are behaving.
STATELESS_UNKNOWN_DOMAINS = {"button", "scene", "conversation", "stt", "tts", "image"}

QUERY = """
WITH latest AS (
  SELECT s.metadata_id, sm.entity_id, s.state, s.last_updated_ts
  FROM states s JOIN states_meta sm ON sm.metadata_id = s.metadata_id
  WHERE s.state_id IN (SELECT max(state_id) FROM states GROUP BY metadata_id)
), good AS (
  SELECT metadata_id, max(last_updated_ts) AS last_good_ts
  FROM states WHERE state NOT IN ('unavailable', 'unknown') GROUP BY metadata_id
), stat AS (
  SELECT sm.statistic_id,
         max(st.start_ts) AS last_stat_ts,
         min(st.start_ts) AS first_stat_ts
  FROM statistics st JOIN statistics_meta sm ON sm.id = st.metadata_id
  GROUP BY 1
)
SELECT l.entity_id, l.state, l.last_updated_ts,
       g.last_good_ts, stat.last_stat_ts, stat.first_stat_ts,
       (sms.id IS NOT NULL) AS lts_possible,
       (SELECT b.state FROM latest b
        WHERE b.entity_id = regexp_replace(l.entity_id, '_[0-9]+$', '')) AS base_state
FROM latest l
LEFT JOIN good g ON g.metadata_id = l.metadata_id
LEFT JOIN stat ON stat.statistic_id = l.entity_id
LEFT JOIN statistics_meta sms ON sms.statistic_id = l.entity_id
WHERE l.state IN ('unavailable', 'unknown')
ORDER BY l.entity_id;
"""

QUERY_CONTEXT = """
SELECT (SELECT count(*) FROM states_meta),
       (SELECT min(last_updated_ts) FROM states),
       (SELECT max(last_updated_ts) FROM states),
       (SELECT min(start_ts) FROM statistics),
       (SELECT extract(epoch FROM max(start)) FROM recorder_runs),
       (SELECT max(run_id) FROM recorder_runs);
"""

SEP = "|"
NULL = "\\N"  # psql -tA prints NULL as the empty string by default; -P null= makes it explicit


def psql(sql):
    """Run one read-only query. Rows come back as lists of str-or-None."""
    proc = subprocess.run(
        ["psql", "-d", DB, "-tA", "-F", SEP, "-P", f"null={NULL}", "-c", sql],
        capture_output=True, text=True, timeout=300, check=True,
    )
    rows = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        rows.append([None if f == NULL else f for f in line.split(SEP)])
    return rows


def fnum(v):
    return None if v is None else float(v)


def day(ts):
    return "never" if ts is None else time.strftime("%Y-%m-%d", time.localtime(ts))


def family_of(entity_id):
    """Device family = domain + first token of the object id.

    sensor.water_sensor_1 -> sensor.water ; switch.dreamebot_a -> switch.dreamebot.
    Crude on purpose: it is the same grouping the operator arrived at by eye, and it needs
    no knowledge of device registries the recorder does not have.
    """
    domain, _, obj = entity_id.partition(".")
    return f"{domain}.{obj.split('_')[0]}"


def classify(rows):
    """Assign each entity exactly one root-cause group, most specific cause first.

    Integration clusters come before suffix debris: if a re-registered twin belongs to a
    broken integration, the integration is the cause and deleting the twin would not fix
    anything. (Verified disjoint on 2026-07-30 -- zero entities matched both -- but the
    precedence is what makes the report correct if that changes.)
    """
    out = []
    for r in rows:
        eid, state, last_ts, good_ts, stat_ts, stat_first, lts_possible, base_state = r
        e = {
            "entity_id": eid,
            "state": state,
            "went_unavailable_ts": fnum(last_ts),
            "last_good_states_ts": fnum(good_ts),
            "last_good_stats_ts": fnum(stat_ts),
            "first_stats_ts": fnum(stat_first),
            "lts_possible": lts_possible == "t",
            "family": family_of(eid),
        }
        # Prefer whichever horizon saw it alive most recently.
        cands = [t for t in (e["last_good_states_ts"], e["last_good_stats_ts"]) if t]
        e["last_good_ts"] = max(cands) if cands else None
        e["ever_good"] = e["last_good_ts"] is not None

        domain = eid.split(".", 1)[0]
        if state == "unknown" and domain in STATELESS_UNKNOWN_DOMAINS:
            e["group"] = "stateless_by_design"
        else:
            e["group"] = None
            for prefix, (name, _action) in INTEGRATION_PREFIXES.items():
                if prefix in eid:
                    e["group"] = f"integration:{name}"
                    break
            if e["group"] is None:
                if SUFFIX.search(eid):
                    if base_state is None:
                        e["group"] = "suffix_no_base"
                    elif base_state in ("unavailable", "unknown"):
                        e["group"] = "suffix_base_also_dead"
                    else:
                        e["group"] = "reregistration_twin"
                else:
                    e["group"] = "device_family"
        out.append(e)
    return out


def history_line(members):
    """One-line history verdict for a group: regression, misconfiguration, or unprovable."""
    ever = [m for m in members if m["ever_good"]]
    never_provable = [m for m in members if not m["ever_good"] and m["lts_possible"]]
    never_unprovable = [m for m in members if not m["ever_good"] and not m["lts_possible"]]
    bits = []
    if ever:
        newest = day(max(m["last_good_ts"] for m in ever))
        bits.append(
            f"{len(ever)} reported real values, most recently {newest}"
            " -> REGRESSION, datable"
        )
    if never_provable:
        bits.append(
            f"{len(never_provable)} never reported in 30d of states nor in long-term stats"
            " -> MISCONFIGURATION"
        )
    if never_unprovable:
        bits.append(
            f"{len(never_unprovable)} never reported in 30d of states; non-numeric so"
            " long-term stats cannot confirm -> UNPROVEN, needs a look"
        )
    return "; ".join(bits) or "no history"


GROUP_ACTIONS = {
    "reregistration_twin": (
        "Delete these entities in Settings > Entities. Each has a live un-suffixed twin, so "
        "the suffixed one is re-registration debris and nothing consumes it.",
        "SAFE TO DELETE",
    ),
    "suffix_no_base": (
        "Do NOT bulk-delete. These end in a digit but have NO un-suffixed sibling, so the "
        "suffix may be part of the real name (zone_2, channel_3). Inspect individually.",
        "LOOKS LIKE DEBRIS, IS NOT PROVEN",
    ),
    "suffix_base_also_dead": (
        "Fix the device/integration first. Both the suffixed entity and its base are "
        "unavailable, so this is a live fault, not leftover bookkeeping -- deleting the "
        "twin would hide it.",
        "LOOKS LIKE DEBRIS, IS NOT PROVEN",
    ),
    "stateless_by_design": (
        "No action. 'unknown' is the resting state for these domains (a button holds its "
        "last-press time; a conversation/stt entity has no state).",
        "NO ACTION -- CORRECT BEHAVIOUR",
    ),
}


def report(entities, ctx, show_list):
    tracked, states_first, states_last, stats_first, last_run_ts, last_run_id = ctx
    n = len(entities)
    unavail = sum(1 for e in entities if e["state"] == "unavailable")
    print("Home Assistant unavailable-entity triage")
    print(f"generated {time.strftime('%Y-%m-%d %H:%M:%S %Z')}   database: {DB} (read-only)")
    print(f"states window {day(states_first)} .. {day(states_last)} "
          f"({(states_last - states_first) / 86400:.0f}d, recorder.purge_keep_days)   "
          f"long-term statistics from {day(stats_first)}")
    print(f"entities tracked {tracked}   unavailable/unknown now {n} "
          f"({unavail} unavailable, {n - unavail} unknown)")

    # Onset correlation with the last HA restart. Without this the report invites 169
    # simultaneous "it broke at 11:27" investigations of a single restart.
    if last_run_ts:
        near = sum(1 for e in entities
                   if e["went_unavailable_ts"]
                   and abs(e["went_unavailable_ts"] - last_run_ts) < 600)
        if near:
            print()
            print("ONSET TIMES ARE NOT EVIDENCE")
            print(f"  {near}/{n} went unavailable within 10 min of the HA start at "
                  f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(last_run_ts))} "
                  f"(recorder run {last_run_id}).")
            print("  A restart marks everything unavailable at once, so that timestamp "
                  "dates the restart, not")
            print("  the fault. The 'last reported real values' dates below are the "
                  "honest signal.")

    groups = collections.defaultdict(list)
    for e in entities:
        groups[e["group"]].append(e)

    print()
    print("ROOT-CAUSE GROUPS -- one action per group")
    print()
    ordered = sorted(groups.items(), key=lambda kv: -len(kv[1]))
    idx = 0
    for gname, members in ordered:
        if gname == "device_family":
            continue
        idx += 1
        if gname.startswith("integration:"):
            iname = gname.split(":", 1)[1]
            action = next(a for p, (nm, a) in INTEGRATION_PREFIXES.items() if nm == iname)
            title = f"broken integration: {iname}"
            verdict = "ONE FIX CLEARS ALL"
        else:
            action, verdict = GROUP_ACTIONS[gname]
            title = gname.replace("_", " ")
        print(f"{idx}. {title} -- {len(members)} entities   [{verdict}]")
        print(f"   ACTION: {action}")
        print(f"   CLEARS: {len(members)} of {n}")
        print(f"   HISTORY: {history_line(members)}")
        if show_list:
            for m in sorted(members, key=lambda m: m["entity_id"]):
                print(f"     {m['entity_id']:<58} last real value {day(m['last_good_ts'])}")
        print()

    fam_members = groups.get("device_family", [])
    if fam_members:
        fams = collections.defaultdict(list)
        for e in fam_members:
            fams[e["family"]].append(e)
        big = {f: m for f, m in fams.items() if len(m) >= 3}
        small = [e for f, m in fams.items() if len(m) < 3 for e in m]
        idx += 1
        print(f"{idx}. device families -- {len(fam_members)} entities   "
              f"[USUALLY NO ACTION: an off device reporting unavailable is CORRECT]")
        print("   ACTION per family: check whether that one device is powered off / off the "
              "network. If it is")
        print("           off on purpose, nothing needs doing. Only a family whose entities "
              "reported real")
        print("           values until a datable day is a regression worth chasing.")
        print(f"   CLEARS: {len(fam_members)} of {n}, across {len(fams)} families "
              f"({len(big)} with 3+ entities)")
        print()
        print(f"   {'family':<26} {'n':>3}  {'ever ok':>7}  {'last real value':<15} verdict")
        for fam, m in sorted(big.items(), key=lambda kv: -len(kv[1])):
            ever = [x for x in m if x["ever_good"]]
            last = day(max((x["last_good_ts"] for x in ever), default=None))
            if not ever:
                # Only entities that COULD have long-term statistics let us say "never".
                # For the rest, 30 days of silence is all we know -- say exactly that.
                blind = sum(1 for x in m if not x["lts_possible"])
                if blind == 0:
                    v = "MISCONFIGURED (never reported; long-term stats agree)"
                elif blind == len(m):
                    v = "UNPROVEN (never in 30d; no long-term stats possible)"
                else:
                    v = f"UNPROVEN for {blind}/{len(m)} (no LTS); rest MISCONFIGURED"
            elif len(ever) == len(m):
                v = f"REGRESSION on {last} -- investigate that day"
            else:
                v = f"MIXED: {len(ever)}/{len(m)} were alive -- partial device loss"
            print(f"   {fam:<26} {len(m):>3}  {len(ever):>3}/{len(m):<3}  {last:<15} {v}")
        if small:
            print(f"   {'(singletons, <3 each)':<26} {len(small):>3}  "
                  f"{sum(1 for x in small if x['ever_good']):>3}/{len(small):<3}"
                  f"  {'-':<15} one-offs, triage by hand")
        if show_list:
            print()
            for fam, m in sorted(big.items(), key=lambda kv: -len(kv[1])):
                print(f"   [{fam}]")
                for x in sorted(m, key=lambda x: x["entity_id"]):
                    print(f"     {x['entity_id']:<58} last real value {day(x['last_good_ts'])}")

    print()
    decisive = [g for g in groups
                if g.startswith("integration:") or g == "reregistration_twin"]
    actionable = sum(len(groups[g]) for g in decisive)
    print(f"BOTTOM LINE: {n} unavailable entities, but only "
          f"{idx} root-cause groups. {actionable} entities clear from "
          f"{len(decisive)} decisive action(s);")
    print("             the device families are mostly 'that device is off', which needs "
          "no action at all.")


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    ap.add_argument("--list", action="store_true", help="print entity ids in each group")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    try:
        rows = psql(QUERY)
        craw = psql(QUERY_CONTEXT)[0]
    except subprocess.CalledProcessError as exc:
        print(f"ha-entity-triage: psql failed (rc={exc.returncode}). Run as the postgres "
              f"user: sudo -u postgres python3 {sys.argv[0]}", file=sys.stderr)
        return 1
    except (subprocess.TimeoutExpired, FileNotFoundError, IndexError) as exc:
        print(f"ha-entity-triage: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    ctx = (int(craw[0]), fnum(craw[1]), fnum(craw[2]), fnum(craw[3]),
           fnum(craw[4]), craw[5])
    entities = classify(rows)

    if args.json:
        json.dump({"generated": time.time(), "tracked": ctx[0],
                   "unavailable_total": len(entities), "entities": entities},
                  sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        report(entities, ctx, args.list)
    return 0


if __name__ == "__main__":
    sys.exit(main())
