"""Detect system services running binaries from an abandoned generation.

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add
one here or flake8 flags it as E265.

WHAT THIS CATCHES, and why nothing else does.

switch-to-configuration decides what to restart by diffing the OUTGOING generation
against the incoming one. It never compares declared state against RUNNING state. So
a switch that dies partway can leave a unit executing a binary from a generation that
is then abandoned, and because every later generation agrees with its predecessor, no
subsequent switch ever sees a change to trigger the restart. The drift is permanent
and silent.

That is not hypothetical. On 2026-08-31 a failed switch (exit 4) restarted PostgreSQL
onto generation 2611's postgresql-17.11/glibc-2.42 at 20:58:10 and then aborted;
/run/current-system never advanced, so the rollback diffed 2610-against-2610 and left
it there. The server ran the wrong binary for ~24h across roughly eight subsequent
switches, reporting a collation-version mismatch on all 23 databases the whole time.

No liveness check can see this. The unit is active, healthy, accepting connections and
passing every probe -- it is simply running the wrong code. It was found by accident,
while chasing unrelated pg_dump warnings.

METHOD. Take the set of store paths reachable from /run/current-system, then resolve
/proc/<MainPID>/exe for every running system service and report any whose store path is
absent from that set. Both halves are cheap: the closure query is a store-DB read
(~0.2s for ~5850 paths) and the rest is two systemctl calls plus a readlink per unit.

SCOPE, deliberately. Only systemd SYSTEM services are inspected. User-profile binaries
(emacs, claude-code, home-manager generations) are legitimately outside the system
closure and would otherwise be a permanent false positive; iterating system units
excludes them by construction rather than by an exclusion list that would rot.

KNOWN BLIND SPOT, stated so nobody mistakes a green metric for a strong guarantee: only
MainPID's exe is examined. A service whose main process is an interpreter (python, node)
shows drift only if the interpreter's own store path changed, not if a library beneath
it did. This would still have caught the incident above, and most like it, but it is a
floor rather than a proof.
"""

import os
import re
import subprocess
import time

OUT = os.environ.get(
    "TEXTFILE_PATH",
    "/var/lib/prometheus-node-exporter-textfiles/closure_drift.prom",
)

CURRENT_SYSTEM = "/run/current-system"

# /nix/store/<32-char base32 hash>-<name>, with no trailing path components.
STORE_PATH_RE = re.compile(r"^(/nix/store/[a-z0-9]{32}-[^/]+)")

HELP = {
    "closure_drift_stale_units": (
        "Number of running system services whose main process executes a store path "
        "absent from the current system closure",
        "gauge",
    ),
    "closure_drift_stale_unit": (
        "1 for each running system service executing a store path outside the current "
        "system closure",
        "gauge",
    ),
    "closure_drift_units_checked": (
        "Number of running system services whose main process was successfully inspected",
        "gauge",
    ),
    "closure_drift_closure_paths": (
        "Number of store paths in the closure of /run/current-system",
        "gauge",
    ),
    "closure_drift_exporter_success": (
        "1 if the collector completed, 0 if it could not determine drift",
        "gauge",
    ),
    "closure_drift_exporter_run_timestamp_seconds": (
        "Unix timestamp of the last completed collector run",
        "gauge",
    ),
}


def _run(argv, timeout=120):
    return subprocess.run(
        argv, capture_output=True, text=True, timeout=timeout, check=False
    )


def system_closure():
    """Store paths reachable from /run/current-system, as a set.

    nix-store -q --requisites reads the store database directly. It is used rather than
    `nix path-info -r` because it needs no flake evaluation and no daemon round-trip.
    """
    proc = _run(["nix-store", "-q", "--requisites", CURRENT_SYSTEM])
    if proc.returncode != 0:
        return None
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}


def running_services():
    """(unit, main_pid) for every running system service, in two subprocess calls."""
    listed = _run(
        [
            "systemctl", "list-units", "--type=service", "--state=running",
            "--no-legend", "--plain", "--no-pager",
        ]
    )
    if listed.returncode != 0:
        return None
    units = [ln.split()[0] for ln in listed.stdout.splitlines() if ln.split()]
    if not units:
        return []

    shown = _run(["systemctl", "show", "--property=Id,MainPID", "--no-pager"] + units)
    if shown.returncode != 0:
        return None

    out, cur = [], {}
    for line in shown.stdout.splitlines():
        if not line.strip():
            if cur.get("Id"):
                out.append((cur["Id"], int(cur.get("MainPID", "0") or 0)))
            cur = {}
            continue
        key, _, value = line.partition("=")
        cur[key] = value
    if cur.get("Id"):
        out.append((cur["Id"], int(cur.get("MainPID", "0") or 0)))
    return out


def exe_store_path(pid):
    """Store path of the process's executable, or None if it is not in the store.

    A process can exit between listing and readlink; that is ordinary, not an error,
    so it is reported as unknown rather than as drift. Guessing 'drifted' on a race
    would page someone about a process that no longer exists.
    """
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
        return None
    match = STORE_PATH_RE.match(os.path.realpath(exe))
    return match.group(1) if match else None


def render(stale, checked, closure_size, success):
    lines = []
    emitted = set()

    def header(name):
        if name not in emitted:
            text, kind = HELP[name]
            lines.append(f"# HELP {name} {text}")
            lines.append(f"# TYPE {name} {kind}")
            emitted.add(name)

    header("closure_drift_stale_units")
    lines.append(f"closure_drift_stale_units {len(stale)}")

    # Per-unit series exist only while a unit is actually drifted, so this set is
    # normally empty and its cardinality is bounded by the number of broken units.
    header("closure_drift_stale_unit")
    for unit, store_path in sorted(stale):
        package = os.path.basename(store_path)[33:]
        lines.append(
            f'closure_drift_stale_unit{{unit="{unit}",package="{package}"}} 1'
        )

    # Work-floor counters. closure_drift_exporter_success only says the collector ran;
    # these say it actually inspected something. If either collapses to 0 the run was
    # vacuous, which a success flag alone would happily report as healthy.
    header("closure_drift_units_checked")
    lines.append(f"closure_drift_units_checked {checked}")
    header("closure_drift_closure_paths")
    lines.append(f"closure_drift_closure_paths {closure_size}")

    header("closure_drift_exporter_success")
    lines.append(f"closure_drift_exporter_success {1 if success else 0}")
    header("closure_drift_exporter_run_timestamp_seconds")
    lines.append(
        f"closure_drift_exporter_run_timestamp_seconds {int(time.time())}"
    )
    return "\n".join(lines) + "\n"


def publish(body):
    # Same-directory temp + rename, so the rename is atomic and node-exporter can never
    # read a half-written file. The textfile dir is mode 1777 (sticky), which is also
    # why this unit must not use DynamicUser: a rotating uid cannot rename(2) over a
    # .prom left by a previous run.
    tmp = f"{OUT}.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.replace(tmp, OUT)
    os.chmod(OUT, 0o644)  # health metrics only, no secrets


def main():
    closure = system_closure()
    services = running_services()

    # Emit success=0 rather than nothing. An ABSENT metric set is indistinguishable
    # from "no drift", which is precisely the failure mode this collector exists to
    # remove, so a broken collector must be loud rather than silently reassuring.
    if closure is None or services is None:
        publish(render(set(), 0, len(closure or ()), False))
        return 1

    stale, checked = set(), 0
    for unit, pid in services:
        if pid <= 0:
            continue
        store_path = exe_store_path(pid)
        if store_path is None:
            continue
        checked += 1
        if store_path not in closure:
            stale.add((unit, store_path))

    publish(render(stale, checked, len(closure), True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
