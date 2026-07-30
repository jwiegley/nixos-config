"""Export per-cgroup PSI (pressure stall information) as node-exporter textfile metrics.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add one
here or flake8 flags it as E265.

WHY THIS EXISTS
---------------
This host has repeatedly been unable to distinguish "service is slow" from "service is
starved". Verified live 2026-07-30 against the running Prometheus:

  * a full `__name__` census returns ZERO metric names matching `cgroup` -- nothing on this
    host exports per-cgroup accounting of any kind;
  * `node_pressure_*` DOES exist, but it is HOST-WIDE: exactly 1 series per name, read from
    /proc/pressure, with no unit/cgroup label. It can tell you the machine stalled. It
    cannot tell you WHICH service stalled, which is the entire question;
  * `microvm_memory_pressure_{some,full}_avg300` exists but covers only the two microvm@*
    units, only memory, and only as an avg300 gauge (not a monotonic total).

So this collector is additive, not a duplicate: same PSI concept, per-cgroup granularity,
for the six system.slice units that carry memory ceilings.

CALIBRATION -- READ THIS BEFORE SIZING ANY THRESHOLD
----------------------------------------------------
`memory.pressure` UNDERSTATES cache-eviction cost, and this host has the measurement to
prove it. Sampled 2026-07-30 on postgresql.service:

    memory.events high      = 3,932,353   (lifetime reclaim events)
    memory.pressure full    avg10=0.00 avg60=0.00 avg300=0.00

Nearly four million reclaim events and PSI reads a flat zero. That is not a bug. Evicting
clean page cache is not a stall -- the kernel drops the page and returns immediately. The
cost is deferred and reappears LATER as a disk read, i.e. in io.pressure, in query latency,
or in the ZFS/ext4 read path -- never in memory.pressure at eviction time.

Consequences, both of which are load-bearing:

  1. NEVER conclude "memory is fine" from low memory.pressure. A cgroup pinned at its
     memory.high ceiling, thrashing its page cache, shows a low memory PSI and a huge
     memory.events counter. That is precisely the state postgresql was in before the
     2026-07-29 ceiling raise (99.8% of a 3.5G memory.high with a continuous ~0.05
     events/sec reclaim floor).
  2. That is why this collector emits memory.events ALONGSIDE the PSI totals. The event
     counter is the cache-thrash detector; the PSI total is the genuine-stall detector.
     They answer different questions and neither substitutes for the other. io.pressure is
     where deferred cache cost actually lands, which is why io is collected too.

NO ALERT RULES SHIP WITH THIS
-----------------------------
Deliberate. There is no baseline yet for any of these series, and this repo has already
accumulated ~120 rules that could never fire, several of them from thresholds fitted on day
one to a number nobody had watched over time. Land the metric, let a baseline accumulate,
then threshold -- and size it off the FULL history, not a convenient window.

One further reason to wait: the 2026-07-29 ceiling raise (modules/core/memory-limits.nix)
just changed the thing being measured. Verified 2026-07-30, postgresql sits at 56% of its
new 10G memory.high and its memory.events `high` counter read 3,932,353 UNCHANGED across
three samples 20s apart -- the old continuous reclaim floor has stopped. Any threshold set
today would be fitted to a regime three days old.

WHY THE UNIT LIST IS HARDCODED
------------------------------
DO NOT replace UNITS with a glob over /sys/fs/cgroup/system.slice. This host has ~1000
units; a glob is how the timer collector reached 1047 series before being relabelled back
down to 94. The six listed units are exactly those carrying an explicit MemoryHigh/MemoryMax
in modules/core/memory-limits.nix -- i.e. the only ones where a cgroup ceiling can starve a
service. Measured output 2026-07-30: 6 units x 15 series + 2 = 92 series, 108 lines,
`promtool check metrics` exit 0.

The cgroup path is resolved per unit from `systemctl show -p ControlGroup`, never assembled
by string-concatenating "system.slice", because that assumption breaks for slices, templated
units, and anything reparented.

SECURITY: every emitted value is an integer or a float count (microseconds of stall, event
counts, byte counts). Nothing is read except /sys/fs/cgroup/<cg>/{memory,io,cpu}.pressure,
memory.events and memory.{current,high,max}, all of which are world-readable and contain no
names, paths, or credentials. `systemctl show` is field-targeted to ControlGroup only.

Metrics emitted:
  cgroup_pressure_stall_seconds_total{unit,resource,scope}  PSI total= (us -> s), counter
  cgroup_memory_events_total{unit,event}                    memory.events, counter
  cgroup_memory_current_bytes{unit}                         memory.current
  cgroup_memory_high_bytes{unit}                            memory.high  (+Inf if unset)
  cgroup_memory_max_bytes{unit}                             memory.max   (+Inf if unset)
  cgroup_pressure_unit_present{unit}                         1 if the cgroup was readable
  cgroup_pressure_exporter_success                           0 if the run failed outright
  cgroup_pressure_exporter_timestamp_seconds                 staleness anchor
"""

import os
import subprocess
import sys
import time

OUT = os.environ.get(
    "TEXTFILE_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/cgroup_pressure.prom",
)

# HARDCODED ON PURPOSE -- see "WHY THE UNIT LIST IS HARDCODED" above. These are the six
# units with an explicit memory ceiling in modules/core/memory-limits.nix. Adding a unit
# here costs 13 series; globbing costs ~1000. Do not glob.
UNITS = [
    "postgresql",
    "loki",
    "home-assistant",
    "victoriametrics",
    "grafana",
    "jellyfin",
]

# cgroup-v2 PSI files. cpu.pressure reports a `full` line for non-root cgroups (verified
# non-zero live), so all three resources are read with both scopes rather than special-casing
# cpu. A missing scope line is simply skipped.
RESOURCES = ["memory", "io", "cpu"]
SCOPES = ["some", "full"]

# memory.events keys worth a counter. `low` and `high` are reclaim pressure; `max`/`oom`/
# `oom_kill` are the hard-limit path. All are monotonic for the life of the cgroup, so they
# reset on unit restart -- which is correct counter semantics and why rate()/increase() over
# them is meaningful while a raw value is not.
MEMORY_EVENTS = ["low", "high", "max", "oom", "oom_kill"]

HELP = [
    ("cgroup_pressure_stall_seconds_total",
     "Cumulative PSI stall time for this cgroup (total= from <resource>.pressure, "
     "microseconds converted to seconds). scope=some: at least one task stalled; "
     "scope=full: all tasks stalled",
     "counter"),
    ("cgroup_memory_events_total",
     "cgroup memory.events counters. high/low count RECLAIM events, which a low "
     "memory.pressure does NOT reflect because evicting clean page cache is not a stall",
     "counter"),
    ("cgroup_memory_current_bytes",
     "cgroup memory.current (includes reclaimable page cache, so a high value is not "
     "itself evidence of memory shortage)", "gauge"),
    ("cgroup_memory_high_bytes",
     "cgroup memory.high soft ceiling; +Inf when unset", "gauge"),
    ("cgroup_memory_max_bytes",
     "cgroup memory.max hard ceiling; +Inf when unset", "gauge"),
    ("cgroup_pressure_unit_present",
     "1 if the unit's cgroup was resolved and its PSI files were readable, else 0. An "
     "absent unit label would be indistinguishable from a healthy one", "gauge"),
    ("cgroup_pressure_exporter_success",
     "1 if this collector completed its run", "gauge"),
    ("cgroup_pressure_exporter_timestamp_seconds",
     "Unix time of the last collector run", "gauge"),
]


def _control_group(unit: str) -> str:
    """Resolve the unit's cgroup path. Field-targeted to ControlGroup, never Environment."""
    proc = subprocess.run(
        ["systemctl", "show", f"{unit}.service", "-p", "ControlGroup", "--value"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    return proc.stdout.strip()


def _read(path: str):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return None


def _psi_totals(text: str) -> dict:
    """Parse a PSI file into {scope: total_microseconds}."""
    out = {}
    for line in text.splitlines():
        fields = line.split()
        if not fields or fields[0] not in SCOPES:
            continue
        for field in fields[1:]:
            key, _, value = field.partition("=")
            if key == "total":
                try:
                    out[fields[0]] = int(value)
                except ValueError:
                    pass
    return out


def _limit(text) -> str | None:
    """memory.high / memory.max: the literal string 'max' means no ceiling -> +Inf."""
    if text is None:
        return None
    value = text.strip()
    if value == "max":
        return "+Inf"
    return value if value.isdigit() else None


def collect(unit: str, out: list) -> None:
    cgroup = _control_group(unit)
    base = f"/sys/fs/cgroup{cgroup}" if cgroup else None

    # PSI is the presence test: a stopped unit has no cgroup, and a cgroup without
    # accounting has no pressure file. Either way present=0 and the unit still appears in
    # the output, so "unit vanished" never reads as "unit healthy".
    psi = {}
    for resource in RESOURCES:
        text = _read(f"{base}/{resource}.pressure") if base else None
        if text is not None:
            psi[resource] = _psi_totals(text)

    out.append(f'cgroup_pressure_unit_present{{unit="{unit}"}} {1 if psi else 0}')
    if not psi:
        return

    for resource, totals in psi.items():
        for scope, micros in sorted(totals.items()):
            out.append(
                f'cgroup_pressure_stall_seconds_total{{unit="{unit}",'
                f'resource="{resource}",scope="{scope}"}} {micros / 1e6:.6f}'
            )

    events_text = _read(f"{base}/memory.events")
    if events_text is not None:
        seen = {}
        for line in events_text.splitlines():
            fields = line.split()
            if len(fields) == 2 and fields[1].isdigit():
                seen[fields[0]] = fields[1]
        # Emit every key explicitly, including zeros: a series that disappears at zero is
        # indistinguishable from a collector that stopped reporting it.
        for key in MEMORY_EVENTS:
            out.append(
                f'cgroup_memory_events_total{{unit="{unit}",event="{key}"}} '
                f'{seen.get(key, "0")}'
            )

    for metric, filename in (
        ("cgroup_memory_current_bytes", "memory.current"),
        ("cgroup_memory_high_bytes", "memory.high"),
        ("cgroup_memory_max_bytes", "memory.max"),
    ):
        value = _limit(_read(f"{base}/{filename}"))
        if value is not None:
            out.append(f'{metric}{{unit="{unit}"}} {value}')


def _emit(lines: list) -> None:
    tmp = f"{OUT}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT)  # same directory, so rename(2): never a torn read
    os.chmod(OUT, 0o644)  # counts only, no names, no secrets


def main() -> int:
    out = []
    for name, help_text, kind in HELP:
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} {kind}")

    try:
        for unit in UNITS:
            collect(unit, out)
    except Exception as exc:  # noqa: BLE001
        # Emit success=0 rather than nothing: an ABSENT metric set is indistinguishable
        # from a healthy system, which is the failure mode this effort exists to remove.
        print(f"cgroup-pressure-exporter: {type(exc).__name__}", file=sys.stderr)
        out.append("cgroup_pressure_exporter_success 0")
        out.append(f"cgroup_pressure_exporter_timestamp_seconds {time.time():.0f}")
        _emit(out)
        return 1

    out.append("cgroup_pressure_exporter_success 1")
    out.append(f"cgroup_pressure_exporter_timestamp_seconds {time.time():.0f}")
    _emit(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
