"""Answer the question nothing else on this host asks: can the system still be DEPLOYED?

Packaged via pkgs.writers.writePython3Bin, which supplies the shebang -- do not add one
here or flake8 flags it as E265.

WHY THIS EXISTS (obr nixos-obc). On 2026-09-08 every nixos-rebuild on this host had been
blocked for up to four days and NOTHING alerted. Four orphaned nix-daemon workers -- dead
parent, zero CPU -- held a build lock on a path whose output already existed, dated Sep 4,
and every build queued behind it forever. It surfaced only because a switch was attempted
by hand and then strace'd.

The gap is structural, not an oversight. No unit fails (nixos-rebuild is run
interactively, not by a timer), no metric moves, and the machine keeps serving from its
last-good generation in perfect health. Everything here watches whether the system is
RUNNING; nothing watched whether it could still be CHANGED. A host that cannot deploy
looks fine right up until a patch has to go out.

TWO CHECKS, DELIBERATELY, because they catch disjoint failures and the obvious single
check catches the wrong one:

  1. PLAN. `nix build --dry-run` on the host's toplevel. Catches evaluation errors,
     broken or unbuildable flake inputs, and a config that cannot be instantiated. This
     would have caught the agent-cat-pi-extension breakage (obr nixos-4o4) on the day it
     appeared rather than when someone next tried to deploy.

  2. STALE HELD LOCKS. Candidate `.lock` files under /nix/store that are old AND still
     held open by a live process.

     The plan check ALONE WOULD NOT HAVE CAUGHT THE INCIDENT THIS EXISTS FOR. The hang
     happened during realisation -- nix had already finished evaluating and printed the
     derivations it intended to build before it blocked. `--dry-run` stops before
     realising, so it sails past a held lock without noticing. That is why this second
     check is here and not folded into the first.

WHAT COUNTS AS A STALE BUILD LOCK. Naively counting `*.lock` under /nix/store is WRONG:
the store legitimately contains ~26 `Cargo.lock` files as ordinary package CONTENTS. A
real nix build lock is zero-byte, root-owned, and carries a real mtime (store contents are
stamped at the epoch). All three together are what separate the two, and this was verified
against the live store before being encoded here.

A lock FILE lying around is harmless and normal -- nix leaves them behind. What blocks a
build is a lock still HELD by a process, so the file test alone would be a false-positive
generator. Holding is therefore confirmed by resolving /proc/<pid>/fd.

The holder scan is a single pass over /proc, testing each resolved fd for membership in
the candidate set. The obvious shape -- for each lock, scan every process -- is
O(locks x processes) and was measured taking over two minutes on this host during the
incident investigation; this is O(processes) and finishes in well under a second.
"""

import json
import os
import subprocess
import sys
import time

TEXTFILE_DIR = "/var/lib/prometheus-node-exporter-textfiles"
OUT = os.path.join(TEXTFILE_DIR, "deploy_canary.prom")

STORE = "/nix/store"

# A lock younger than this is very likely a build actually in progress -- including one
# started by a person a moment ago -- and flagging it would turn a normal rebuild into an
# alert. The incident's lock was four days old, so hours of grace costs no detection.
STALE_LOCK_AGE_S = 6 * 3600

# Bounds the plan check. Evaluating this configuration measured ~50s; 10 minutes leaves
# room for a cold eval cache without letting a genuinely wedged evaluation pin the unit.
# A timeout is reported as failure, which is correct: an evaluation that will not finish
# is an evaluation you cannot deploy from.
PLAN_TIMEOUT_S = 600


def stale_lock_candidates():
    """Zero-byte, root-owned, real-mtime .lock files older than the grace period."""
    now = time.time()
    out = {}
    try:
        it = os.scandir(STORE)
    except OSError:
        return out
    with it:
        for e in it:
            if not e.name.endswith(".lock"):
                continue
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            # size 0 + root-owned + a real (non-epoch) mtime. Cargo.lock and friends are
            # package contents: non-zero size and stamped at the epoch.
            if st.st_size != 0 or st.st_uid != 0:
                continue
            if st.st_mtime < 86400:
                continue
            if now - st.st_mtime < STALE_LOCK_AGE_S:
                continue
            out[e.path] = e.name[: -len(".lock")]
    return out


def held_locks(candidates):
    """Which candidates a live process still holds open. One pass over /proc."""
    if not candidates:
        return {}
    held = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        fddir = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(fddir)
        except OSError:
            continue  # process exited, or not ours to read
        for fd in fds:
            try:
                target = os.readlink(os.path.join(fddir, fd))
            except OSError:
                continue
            if target in candidates:
                held[target] = candidates[target]
    return held


def run_plan(flake_attr):
    """`nix build --dry-run` on the toplevel. Returns (ok, duration_s, to_build)."""
    started = time.monotonic()
    try:
        p = subprocess.run(
            [
                "nix", "build", "--dry-run", "--no-link",
                "--json", "--log-format", "raw", flake_attr,
            ],
            capture_output=True, text=True, timeout=PLAN_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return 0, time.monotonic() - started, -1
    except OSError:
        return 0, time.monotonic() - started, -1
    dur = time.monotonic() - started
    if p.returncode != 0:
        return 0, dur, -1
    # --json reports the derivations that would be realised. Its exact shape has moved
    # between nix versions, so a parse failure must not be read as "nothing to build":
    # report -1 (unknown) and let the success gauge carry the signal.
    try:
        data = json.loads(p.stdout or "[]")
        to_build = len(data) if isinstance(data, list) else -1
    except (ValueError, TypeError):
        to_build = -1
    return 1, dur, to_build


def main():
    flake_attr = sys.argv[1] if len(sys.argv) > 1 else None
    if not flake_attr:
        print("usage: deploy-canary-exporter <flake-attr>", file=sys.stderr)
        return 2

    candidates = stale_lock_candidates()
    held = held_locks(candidates)
    plan_ok, plan_dur, to_build = run_plan(flake_attr)

    lines = [
        "# HELP deploy_canary_plan_success 1 if `nix build --dry-run` on the system "
        "toplevel succeeded, 0 if it failed or timed out",
        "# TYPE deploy_canary_plan_success gauge",
        f"deploy_canary_plan_success {plan_ok}",
        "",
        "# HELP deploy_canary_plan_duration_seconds Wall time of the plan check",
        "# TYPE deploy_canary_plan_duration_seconds gauge",
        f"deploy_canary_plan_duration_seconds {plan_dur:.3f}",
        "",
        "# HELP deploy_canary_paths_to_build Derivations the next deploy would build "
        "(-1 = unknown; plan failed or its JSON could not be parsed)",
        "# TYPE deploy_canary_paths_to_build gauge",
        f"deploy_canary_paths_to_build {to_build}",
        "",
        "# HELP deploy_canary_stale_locks Old store build locks STILL HELD by a live "
        "process; any non-zero value blocks builds needing that path",
        "# TYPE deploy_canary_stale_locks gauge",
        f"deploy_canary_stale_locks {len(held)}",
        "",
        "# HELP deploy_canary_stale_lock_candidates Old build-lock FILES present; "
        "harmless on their own, context for the held count",
        "# TYPE deploy_canary_stale_lock_candidates gauge",
        f"deploy_canary_stale_lock_candidates {len(candidates)}",
        "",
        "# HELP deploy_canary_stale_lock 1 per held stale lock, labelled by derivation",
        "# TYPE deploy_canary_stale_lock gauge",
    ]
    for name in sorted(held.values()):
        safe = name.replace("\\", "").replace('"', "")
        lines.append(f'deploy_canary_stale_lock{{drv="{safe}"}} 1')
    lines += [
        "",
        "# HELP deploy_canary_run_timestamp_seconds Unix time of the last run "
        "(collector liveness)",
        "# TYPE deploy_canary_run_timestamp_seconds gauge",
        f"deploy_canary_run_timestamp_seconds {time.time():.0f}",
        "",
    ]

    tmp = f"{OUT}.{os.getpid()}"
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
