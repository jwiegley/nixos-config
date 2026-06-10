#!/usr/bin/env python3
"""
Crown-jewel config-drift exporter.

Watches a small, named set of high-value *mutable* config artifacts that no
other signal covers (Home Assistant hand-edited YAML, Node-RED flows.json, the
SSH server config, the encrypted SOPS secrets file) and emits Prometheus
textfile metrics describing whether each one changed *outside a deploy window*.

Design (docs/MONITORING_DEFERRED_SPECS.md "Config-Drift Auditing", Option B):

  * For each watched file we compute a sha256 of its (optionally normalized)
    bytes and compare it against a stored baseline in
    /var/lib/config-drift/baselines.json.
  * A change is "approved by deploy" if the file's mtime sits within a grace
    window of that file's deploy anchor:
      - flows.json   -> mtime of /var/lib/node-red/.flows.json.backup
                        (Node-RED rewrites the backup in lockstep on every
                        deploy, so a real deploy re-baselines silently).
      - everything   -> system_current_generation_build_timestamp_seconds
        else            (mtime of the system profile link, emitted by
                        system-age-exporter.nix) — HA YAML + sshd_config +
                        secrets.yaml all change via a nixos-rebuild / sops edit
                        that the operator performed deliberately.
    When a change is approved-by-deploy the baseline is silently updated and
    config_file_drift stays 0. Otherwise config_file_drift = 1 and the alert
    can page.

SECURITY — counts / booleans / timestamps / file-NAME labels ONLY. The sha256
is stored locally in the root-0600 baseline store and is NEVER emitted. File
*contents* never leave the box, no diffs, no key paths. configuration.yaml is
sha-normalized by dropping the injected "  db_url:" line (mirrors
home-assistant.nix:1120) so per-rebuild db_url churn is invisible.
secrets.yaml is hashed in its ENCRYPTED form — sops is never invoked.

Stdlib-only, modeled on scripts/openclaw-config-drift-check.py.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time

TEXTFILE_DIR = "/var/lib/prometheus-node-exporter-textfiles"
METRIC_PATH = os.path.join(TEXTFILE_DIR, "config_drift.prom")
BASELINE_DIR = "/var/lib/config-drift"
BASELINE_PATH = os.path.join(BASELINE_DIR, "baselines.json")

# The system-age-exporter writes this; we read the generation build timestamp
# from it as the default deploy anchor. Parsed as plain text (no PromQL).
SYSTEM_AGE_PROM = os.path.join(TEXTFILE_DIR, "system_age.prom")

# Grace window (seconds) around a deploy anchor within which an mtime change is
# treated as approved-by-deploy. Generous, mirroring AIDE's 60s post-rebuild
# update delay plus the activation-ordering slop noted in the spec.
DEPLOY_GRACE_SECONDS = 900  # 15 min

# Node-RED writes this backup in lockstep with flows.json on every deploy.
NR_BACKUP_ANCHOR = "/var/lib/node-red/.flows.json.backup"

# Watched files. key = label emitted in the metric; path = file on disk.
# normalize: optional callable(bytes) -> bytes applied before hashing.
# anchor: "nodered" uses the NR backup mtime; default uses the generation ts.


def _normalize_ha_config(buf: bytes) -> bytes:
    """Drop the rebuild-injected '  db_url:' line so per-switch churn is
    invisible (mirrors home-assistant.nix:1120 `grep -v '^  db_url:'`)."""
    out = []
    for line in buf.split(b"\n"):
        if line.startswith(b"  db_url:"):
            continue
        out.append(line)
    return b"\n".join(out)


FILES = {
    "configuration.yaml": {
        "path": "/var/lib/hass/configuration.yaml",
        "normalize": _normalize_ha_config,
        "anchor": "generation",
    },
    "automations.yaml": {
        "path": "/var/lib/hass/automations.yaml",
        "normalize": None,
        "anchor": "generation",
    },
    "scripts.yaml": {
        "path": "/var/lib/hass/scripts.yaml",
        "normalize": None,
        "anchor": "generation",
    },
    "scenes.yaml": {
        "path": "/var/lib/hass/scenes.yaml",
        "normalize": None,
        "anchor": "generation",
    },
    "flows.json": {
        "path": "/var/lib/node-red/flows.json",
        "normalize": None,
        "anchor": "nodered",
    },
    "sshd_config": {
        "path": "/etc/ssh/sshd_config",
        "normalize": None,
        "anchor": "generation",
    },
    # The ENCRYPTED SOPS file. We sha the ciphertext bytes; sops is never run.
    "secrets.yaml": {
        "path": "/etc/nixos/secrets/secrets.yaml",
        "normalize": None,
        "anchor": "generation",
    },
}


def _sha256(path: str, normalize) -> str | None:
    """Return hex sha256 of the (optionally normalized) file bytes, or None if
    the file is absent / unreadable."""
    try:
        with open(path, "rb") as f:
            buf = f.read()
    except OSError:
        return None
    if normalize is not None:
        buf = normalize(buf)
    return hashlib.sha256(buf).hexdigest()


def _mtime(path: str) -> float | None:
    """mtime of the path itself (lstat — the symlink's own mtime, not the
    target's). For an /etc store-symlink this is the rebuild repoint time, which
    is the meaningful "when did this go live" signal; the store target carries a
    useless epoch-1 mtime."""
    try:
        return os.lstat(path).st_mtime
    except OSError:
        return None


def _is_store_backed(path: str) -> bool:
    """True if the path resolves into the read-only Nix store. Such files cannot
    be edited out of band (the store is immutable + a rebuild repoints the
    symlink), so 'drift outside a deploy' is structurally impossible — we track
    presence + mtime but never flag drift for them."""
    try:
        return os.path.realpath(path).startswith("/nix/store/")
    except OSError:
        return False


def _generation_anchor() -> float | None:
    """Read system_current_generation_build_timestamp_seconds from
    system_age.prom (plain-text parse, no network)."""
    try:
        with open(SYSTEM_AGE_PROM, "r") as f:
            for line in f:
                if line.startswith("#"):
                    continue
                parts = line.split()
                if (
                    len(parts) == 2
                    and parts[0]
                    == "system_current_generation_build_timestamp_seconds"
                ):
                    return float(parts[1])
    except (OSError, ValueError):
        return None
    return None


def _anchor_for(name: str, generation_ts: float | None) -> float | None:
    spec = FILES[name]
    if spec["anchor"] == "nodered":
        return _mtime(NR_BACKUP_ANCHOR)
    return generation_ts


def _load_baselines() -> dict:
    try:
        with open(BASELINE_PATH, "r") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {}
        return data
    except (OSError, json.JSONDecodeError):
        # Missing / corrupt => first-run; baseline everything, drift=0.
        return {}


def _save_baselines(baselines: dict) -> None:
    os.makedirs(BASELINE_DIR, mode=0o700, exist_ok=True)
    tmp = BASELINE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(baselines, f, indent=1, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.rename(tmp, BASELINE_PATH)


def write_metrics(rows: list[dict], run_ts: float, git_dirty: int) -> None:
    lines = [
        "# HELP config_file_present 1 if the watched config file exists",
        "# TYPE config_file_present gauge",
    ]
    for r in rows:
        lines.append(
            f'config_file_present{{file="{r["file"]}"}} {r["present"]}'
        )
    lines += [
        "# HELP config_file_mtime_seconds Unix mtime of the watched config file",
        "# TYPE config_file_mtime_seconds gauge",
    ]
    for r in rows:
        lines.append(
            f'config_file_mtime_seconds{{file="{r["file"]}"}} {r["mtime"]}'
        )
    lines += [
        "# HELP config_file_drift 1 if sha changed AND the change is outside the deploy window",
        "# TYPE config_file_drift gauge",
    ]
    for r in rows:
        lines.append(
            f'config_file_drift{{file="{r["file"]}"}} {r["drift"]}'
        )
    lines += [
        "# HELP nixos_config_uncommitted_changes Count of uncommitted/untracked files in /etc/nixos (excluding the build lock)",
        "# TYPE nixos_config_uncommitted_changes gauge",
        f"nixos_config_uncommitted_changes {git_dirty}",
        "# HELP config_drift_last_run_timestamp_seconds When the config-drift exporter last ran",
        "# TYPE config_drift_last_run_timestamp_seconds gauge",
        f"config_drift_last_run_timestamp_seconds {run_ts}",
        "",
    ]
    os.makedirs(TEXTFILE_DIR, exist_ok=True)
    tmp = METRIC_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.chmod(tmp, 0o644)
    os.rename(tmp, METRIC_PATH)


def _git_dirty_count() -> int:
    """Count uncommitted/untracked files in /etc/nixos, ignoring the gitignored
    .nixos-build lock. Uses subprocess git; returns 0 on any error (the
    exporter-stale alert covers a dead collector)."""
    import subprocess

    try:
        out = subprocess.run(
            [
                "git",
                "-C",
                "/etc/nixos",
                "status",
                "--porcelain",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return 0
    count = 0
    for line in out.splitlines():
        if not line.strip():
            continue
        if ".nixos-build" in line:
            continue
        count += 1
    return count


def main() -> int:
    rebaseline = "--rebaseline" in sys.argv[1:]

    baselines = _load_baselines()
    first_run = len(baselines) == 0
    generation_ts = _generation_anchor()
    now = time.time()

    rows = []
    new_baselines = dict(baselines)

    for name in FILES:
        spec = FILES[name]
        path = spec["path"]
        sha = _sha256(path, spec["normalize"])
        mtime = _mtime(path)
        present = 1 if sha is not None else 0

        if sha is None:
            # File absent/unreadable. present=0 drives CrownJewelFileMissing.
            # Leave any existing baseline in place (a transient read failure
            # shouldn't wipe the known-good sha).
            rows.append(
                {"file": name, "present": 0, "mtime": 0, "drift": 0}
            )
            continue

        prior = baselines.get(name, {})
        prior_sha = prior.get("sha256")
        anchor = _anchor_for(name, generation_ts)
        store_backed = _is_store_backed(path)

        drift = 0
        if rebaseline or first_run or prior_sha is None:
            # Operator-approved re-baseline, or first observation: record,
            # never alert.
            new_baselines[name] = {"sha256": sha, "baselined_at": now}
        elif sha == prior_sha:
            # Unchanged. Keep baseline as-is.
            new_baselines[name] = prior
        elif store_backed:
            # Content changed but the file lives in the immutable Nix store
            # (e.g. sshd_config -> /etc/static -> /nix/store). It can ONLY have
            # changed via a rebuild, never out of band, so re-baseline silently
            # and never flag drift — its mtime is unreliable vs the generation
            # anchor (the /etc symlink repoints on a different schedule than the
            # system-profile link).
            new_baselines[name] = {"sha256": sha, "baselined_at": now}
        else:
            # sha changed. Approved-by-deploy iff mtime within grace of anchor.
            approved = (
                anchor is not None
                and mtime is not None
                and (mtime - anchor) <= DEPLOY_GRACE_SECONDS
                and (mtime - anchor) >= -DEPLOY_GRACE_SECONDS
            )
            if approved:
                # Legitimate deploy churn — silently re-baseline.
                new_baselines[name] = {"sha256": sha, "baselined_at": now}
            else:
                # Out-of-band change. Flag drift; KEEP the old baseline so the
                # flag persists across runs until approved (rebuild re-anchors
                # the mtime, or `--rebaseline`).
                drift = 1
                new_baselines[name] = prior
                # Log the file NAME only (never path internals, never contents)
                # so an operator sees WHICH crown jewel drifted in the journal.
                print(
                    f"config-drift: {name} sha changed outside deploy window "
                    "(contents not logged)",
                    file=sys.stderr,
                )

        rows.append(
            {
                "file": name,
                "present": present,
                "mtime": int(mtime) if mtime is not None else 0,
                "drift": drift,
            }
        )

    _save_baselines(new_baselines)
    git_dirty = _git_dirty_count()
    write_metrics(rows, now, git_dirty)
    return 0


if __name__ == "__main__":
    sys.exit(main())
