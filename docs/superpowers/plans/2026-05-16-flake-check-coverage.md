# Flake-check Coverage Implementation Plan

> **Archival — 2026-05-16.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `tests/openclaw/check-schema.nix`, `tests/openclaw/expected-keys.txt`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire three improvements into `nix flake check`: (A) snapshot schema check on `pkgs.openclaw-config-template`, (B) runtime schema-drift detector emitting Prometheus textfile metrics, (C) three new flake checks running the existing pytest suites.

**Spec:** [`/etc/nixos/docs/superpowers/specs/2026-05-16-flake-check-coverage-design.md`](../specs/2026-05-16-flake-check-coverage-design.md)

**Security invariants:**
- No new secrets — Deliverable B reuses `openclaw/probe-ssh-private-key` already in sops via `LoadCredential`.
- Drift detector pre-strips secret-named keys with the canonical regex before any byte reaches stdout.
- Snapshot file (`tests/openclaw/expected-keys.txt`) contains only structural key names — no values.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `/etc/nixos/scripts/openclaw-self-heal/tests/test_daemon.py` | **modify** | Fix stale `ACTION_ALLOWLIST` assertion (pre-req gate) |
| `/etc/nixos/tests/openclaw/expected-keys.txt` | **create** | Committed snapshot of template keys |
| `/etc/nixos/tests/openclaw/check-schema.nix` | **create** | Standalone Nix derivation for the schema flake check |
| `/etc/nixos/flake.nix` | **modify** | Add four new entries to `checks.aarch64-linux` |
| `/etc/nixos/scripts/openclaw-config-drift-check.py` | **create** | Runtime drift detector (Python stdlib only) |
| `/etc/nixos/modules/monitoring/services/openclaw-config-drift-check.nix` | **create** | NixOS module (service + timer + sops glue) |
| `/etc/nixos/modules/monitoring/alerts/openclaw.yaml` | **modify** | Add `OpenClawConfigDrift` alert rule |
| `/etc/nixos/hosts/vulcan/default.nix` | **modify** | Import the new module |

---

## Task 1: Fix the failing test (Deliverable C prerequisite)

**Files:** `/etc/nixos/scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Update `test_allowlist_is_exactly_the_authorized_actions`**

Use Edit to replace:
```python
def test_allowlist_is_exactly_the_authorized_actions():
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm",
        "doctor_fix",
        "prune_stale_plugin_deps",
        "restage_secrets",
    )
```
with:
```python
def test_allowlist_is_exactly_the_authorized_actions():
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm",
        "doctor_fix",
        "prune_stale_plugin_deps",
        "restage_secrets",
        "restart_canary",
        "restart_mcporter_check",
    )
```

- [ ] **Step 2: Run the suite to confirm all 25 pass**

```bash
nix-shell -p python312 python312Packages.pytest --run 'python3 -m pytest scripts/openclaw-self-heal/tests/ -v 2>&1 | tail -5'
```

Expected: `25 passed`.

- [ ] **Step 3: Commit**

```bash
git add scripts/openclaw-self-heal/tests/test_daemon.py
git commit -m "test(openclaw-self-heal): include restart_canary + restart_mcporter_check in allowlist assertion"
```

---

## Task 2: Generate the initial schema snapshot (Deliverable A scaffolding)

**Files:**
- Create: `/etc/nixos/tests/openclaw/expected-keys.txt`
- Create: `/etc/nixos/tests/openclaw/.gitkeep` (probably not needed since expected-keys.txt is created)

- [ ] **Step 1: Build the template and extract the sorted key set**

```bash
mkdir -p /etc/nixos/tests/openclaw
TPL=$(nix build --no-link --print-out-paths '/etc/nixos#nixosConfigurations.vulcan.pkgs.openclaw-config-template')
echo "Template: $TPL"
jq -r 'paths | map(tostring) | join(".")' "$TPL" | sort > /etc/nixos/tests/openclaw/expected-keys.txt
echo "Captured $(wc -l < /etc/nixos/tests/openclaw/expected-keys.txt) keys"
```

Expected: a file containing 200+ dotted-path key names, one per line, sorted.

- [ ] **Step 2: Sanity check — should have all 13 top-level keys**

```bash
awk -F. '{print $1}' /etc/nixos/tests/openclaw/expected-keys.txt | sort -u
```

Expected output: `acp`, `agents`, `auth`, `channels`, `commands`, `gateway`, `messages`, `meta`, `models`, `plugins`, `skills`, `tools`, `wizard` (13 lines).

- [ ] **Step 3: Commit**

```bash
git add /etc/nixos/tests/openclaw/expected-keys.txt
git commit -m "test(openclaw): snapshot template key set as flake-check baseline"
```

---

## Task 3: Schema-check Nix derivation (Deliverable A)

**Files:** Create `/etc/nixos/tests/openclaw/check-schema.nix`

- [ ] **Step 1: Write the derivation**

Create `/etc/nixos/tests/openclaw/check-schema.nix`:
```nix
# Standalone derivation that diffs the rendered openclaw-config-template's
# key set against the committed snapshot at expected-keys.txt.
# Imported from flake.nix as checks.<system>.openclaw-config-schema.
{
  pkgs,
  openclaw-config-template,
}:
pkgs.runCommand "openclaw-config-schema-check"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.diffutils
    ];
    expectedKeys = ./expected-keys.txt;
    template = openclaw-config-template;
  }
  ''
    set -euo pipefail
    actual=$(mktemp)
    trap 'rm -f "$actual"' EXIT

    jq -r 'paths | map(tostring) | join(".")' "$template" | sort > "$actual"

    if ! diff -u "$expectedKeys" "$actual"; then
      echo ""
      echo "openclaw-config-template's key set does not match the committed snapshot."
      echo ""
      echo "If this is a deliberate template change, regenerate the snapshot:"
      echo ""
      echo "  TPL=\$(nix build --no-link --print-out-paths '/etc/nixos#nixosConfigurations.vulcan.pkgs.openclaw-config-template')"
      echo "  jq -r 'paths | map(tostring) | join(\".\")' \"\$TPL\" | sort > tests/openclaw/expected-keys.txt"
      echo "  git add tests/openclaw/expected-keys.txt"
      echo ""
      echo "Then commit with a message describing why."
      exit 1
    fi

    touch "$out"
  ''
```

- [ ] **Step 2: No commit yet — wired in Task 5**

---

## Task 4: Pytest-check derivations (Deliverable C)

**Files:** Create `/etc/nixos/tests/checks.nix`

- [ ] **Step 1: Write the shared pytest helper**

Create `/etc/nixos/tests/checks.nix`:
```nix
# Helpers for repo-local flake checks.
# Each function returns a derivation that runs a pytest suite in the
# Nix sandbox; failure of pytest fails the flake check.
{ pkgs }:
let
  pytestPython = pkgs.python312.withPackages (ps: [ ps.pytest ]);

  mkPytestCheck = { name, src }:
    pkgs.runCommand "${name}-check"
      {
        nativeBuildInputs = [ pytestPython ];
        inherit src;
      }
      ''
        set -euo pipefail
        # Pytest is happier with a writable cwd.
        cp -r "$src" suite
        chmod -R +w suite
        cd suite
        ${pytestPython}/bin/pytest -v
        touch "$out"
      '';
in
{
  inherit mkPytestCheck;
}
```

- [ ] **Step 2: No commit yet — wired in Task 5**

---

## Task 5: Wire the four new checks into flake.nix

**Files:** Modify `/etc/nixos/flake.nix`

- [ ] **Step 1: Find the `outputs` and existing `checks` (if any)**

```bash
grep -nE 'checks\b|outputs\s*=' /etc/nixos/flake.nix | head -10
```

Two cases to handle: there's already a `checks.<system>` block (extend it) or there isn't (create it).

- [ ] **Step 2: Add the checks block to `outputs`**

Inside the existing `outputs = { ... }: { ... };` body, add (or extend) a `checks` attribute. Use Edit with a unique anchor; if the file already has `checks = { ... }`, just append the four new entries inside it.

The block to add (assuming aarch64-linux only — vulcan is the only consumer):

```nix
    checks.aarch64-linux = let
      pkgsForChecks = nixpkgs.legacyPackages.aarch64-linux;
      cfg = self.nixosConfigurations.vulcan;
      helpers = import ./tests/checks.nix { pkgs = pkgsForChecks; };
    in {
      openclaw-config-schema = import ./tests/openclaw/check-schema.nix {
        pkgs = pkgsForChecks;
        openclaw-config-template = cfg.pkgs.openclaw-config-template;
      };

      openclaw-self-heal-tests = helpers.mkPytestCheck {
        name = "openclaw-self-heal-tests";
        src = ./scripts/openclaw-self-heal;
      };

      openclaw-hermes-smoke-tests = helpers.mkPytestCheck {
        name = "openclaw-hermes-smoke-tests";
        src = ./scripts;
      };

      openclaw-nightly-report-tests = helpers.mkPytestCheck {
        name = "openclaw-nightly-report-tests";
        src = ./scripts;
      };
    };
```

Notes:
- `openclaw-hermes-smoke-tests` and `openclaw-nightly-report-tests` both use `./scripts` as the `src` because the pytest helper needs `conftest.py` (which is in `scripts/openclaw-hermes-smoke-tests/`) AND the script being imported (`scripts/openclaw_hermes_smoke.py`). The `mkPytestCheck` helper's `cd suite; pytest -v` will let pytest auto-discover tests under both `openclaw-hermes-smoke-tests/` and `openclaw-nightly-report-tests/` if `src` is `./scripts` — but they'd run as one combined suite. To keep them separate, make each `src` the suite directory and provide a `conftest.py` in each that handles the import path.

Re-examining: simplest is to set `src = ./scripts` for all three but rely on per-suite `pytest <suite-dir>` invocation. Update the helper:

```nix
  mkPytestCheck = { name, src, suiteDir }:
    pkgs.runCommand "${name}-check"
      {
        nativeBuildInputs = [ pytestPython ];
        inherit src;
      }
      ''
        set -euo pipefail
        cp -r "$src" suite
        chmod -R +w suite
        cd suite
        ${pytestPython}/bin/pytest ${suiteDir} -v
        touch "$out"
      '';
```

And the flake.nix block becomes:
```nix
      openclaw-self-heal-tests = helpers.mkPytestCheck {
        name = "openclaw-self-heal-tests";
        src = ./scripts/openclaw-self-heal;
        suiteDir = "tests";
      };

      openclaw-hermes-smoke-tests = helpers.mkPytestCheck {
        name = "openclaw-hermes-smoke-tests";
        src = ./scripts;
        suiteDir = "openclaw-hermes-smoke-tests";
      };

      openclaw-nightly-report-tests = helpers.mkPytestCheck {
        name = "openclaw-nightly-report-tests";
        src = ./scripts;
        suiteDir = "openclaw-nightly-report-tests";
      };
```

(The first one needs `src = ./scripts/openclaw-self-heal` because `test_daemon.py` imports `daemon` directly without going through a conftest sys.path hack.)

- [ ] **Step 3: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/flake.nix /etc/nixos/tests/checks.nix /etc/nixos/tests/openclaw/check-schema.nix'
```

- [ ] **Step 4: Run all four checks**

```bash
nix flake check /etc/nixos 2>&1 | tail -15
```

Expected: four lines like `building '/nix/store/...-openclaw-config-schema-check.drv'...` and then `success`. If any pytest suite fails, fix the test (not the wiring).

- [ ] **Step 5: Commit**

```bash
git add flake.nix tests/checks.nix tests/openclaw/check-schema.nix
git commit -m "$(cat <<'EOF'
feat(flake): wire schema + pytest checks into nix flake check

Four new checks under checks.aarch64-linux:

- openclaw-config-schema: diffs pkgs.openclaw-config-template's key
  set against tests/openclaw/expected-keys.txt. Failure mode includes
  the regeneration recipe in the error message.
- openclaw-self-heal-tests: runs the existing pytest suite at
  scripts/openclaw-self-heal/tests/.
- openclaw-hermes-smoke-tests: runs scripts/openclaw-hermes-smoke-tests/.
- openclaw-nightly-report-tests: runs scripts/openclaw-nightly-report-tests/.

Each is a pkgs.runCommand derivation invoking pytest in the Nix
sandbox; loopback fake servers work fine in-sandbox.
EOF
)"
```

---

## Task 6: Negative verification — break the template, see the schema check fail

**Files:** none (transient)

- [ ] **Step 1: Inject a deliberate breakage**

Temporarily comment out a key in `modules/services/openclaw-config.nix`. Pick something distinctive like `lastTouchedAt` under `.meta`. Re-run `nix flake check`:

```bash
# Edit modules/services/openclaw-config.nix to comment out a leaf key
nix flake check /etc/nixos 2>&1 | grep -A20 'openclaw-config-schema'
```

Expected: the check fails with output showing `-meta.lastTouchedAt` (removed) and the regeneration recipe.

- [ ] **Step 2: Revert the breakage**

Restore the commented-out line. Run `nix flake check` again — expect success.

- [ ] **Step 3: No commit (verification only)**

---

## Task 7: Drift-check Python script (Deliverable B core)

**Files:** Create `/etc/nixos/scripts/openclaw-config-drift-check.py`

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""
OpenClaw config schema-drift detector.

Compares the live openclaw.json key set (read from the guest VM via
SSH) against the in-store openclaw-config-template's key set. Emits
Prometheus textfile metrics. Stdlib-only.

Pre-strips secret-named keys with the canonical regex before any byte
reaches stdout. The metric file contains only integer counts plus the
probe-up gauge — no key names, no values.
"""
from __future__ import annotations
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from typing import Optional

SECRET_RE = re.compile(
    r"([Aa]pi[Kk]ey|[Tt]oken|[Pp]assword|[Pp]assphrase"
    r"|[Ss]ecret|[Ss]ecretKey|[Pp]sk|[Bb]earer)"
)

GUEST_USER = "openclaw"
GUEST_ADDR = "10.99.0.2"
GUEST_CONFIG_PATH = "/var/lib/openclaw/.openclaw/openclaw.json"
TEMPLATE_PATH_ENV = "OPENCLAW_TEMPLATE_PATH"  # injected by the unit
SSH_KEY_PATH_ENV = "OPENCLAW_PROBE_SSH_KEY"   # LoadCredential resolution
METRIC_PATH = (
    "/var/lib/prometheus-node-exporter-textfiles/"
    "openclaw_config_drift.prom"
)


def _strip_paths(buf: bytes) -> set[str]:
    """Walk JSON, return set of dotted paths with secret-named keys removed."""
    obj = json.loads(buf)

    def walk(o, prefix=""):
        if isinstance(o, dict):
            for k, v in o.items():
                if SECRET_RE.search(k):
                    continue
                path = f"{prefix}.{k}" if prefix else k
                yield path
                yield from walk(v, path)
        elif isinstance(o, list):
            for i, v in enumerate(o):
                path = f"{prefix}.{i}"
                yield path
                yield from walk(v, path)

    return set(walk(obj))


def _read_template_keys() -> set[str]:
    path = os.environ.get(TEMPLATE_PATH_ENV)
    if not path:
        raise RuntimeError(f"{TEMPLATE_PATH_ENV} not set")
    with open(path, "rb") as f:
        return _strip_paths(f.read())


def _read_live_keys() -> Optional[set[str]]:
    """Returns None if SSH probe fails."""
    ssh_key = os.environ.get(SSH_KEY_PATH_ENV)
    if not ssh_key:
        print("OPENCLAW_PROBE_SSH_KEY not set", file=sys.stderr)
        return None
    try:
        result = subprocess.run(
            [
                "ssh", "-i", ssh_key,
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=10",
                f"{GUEST_USER}@{GUEST_ADDR}",
                f"cat {GUEST_CONFIG_PATH}",
            ],
            capture_output=True, timeout=30, check=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"SSH probe failed: {e}", file=sys.stderr)
        return None
    return _strip_paths(result.stdout)


def write_metrics(probe_up: bool, added: int, removed: int) -> None:
    lines = [
        "# HELP openclaw_config_drift_probe_up 1 if the SSH probe succeeded",
        "# TYPE openclaw_config_drift_probe_up gauge",
        f"openclaw_config_drift_probe_up {1 if probe_up else 0}",
        "# HELP openclaw_config_drift_keys_added Number of keys present in live config but not in Nix template",
        "# TYPE openclaw_config_drift_keys_added gauge",
        f"openclaw_config_drift_keys_added {added}",
        "# HELP openclaw_config_drift_keys_removed Number of keys present in Nix template but not in live config",
        "# TYPE openclaw_config_drift_keys_removed gauge",
        f"openclaw_config_drift_keys_removed {removed}",
        "# HELP openclaw_config_drift_last_run_timestamp_seconds When the drift check last ran",
        "# TYPE openclaw_config_drift_last_run_timestamp_seconds gauge",
        f"openclaw_config_drift_last_run_timestamp_seconds {time.time()}",
        "",
    ]
    tmp = METRIC_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.rename(tmp, METRIC_PATH)


def main() -> int:
    try:
        template_keys = _read_template_keys()
    except (FileNotFoundError, json.JSONDecodeError, RuntimeError) as e:
        print(f"template read failed: {e}", file=sys.stderr)
        write_metrics(probe_up=False, added=0, removed=0)
        return 0  # exit 0 so the unit goes 'active (exited)'; the metric tells the story

    live_keys = _read_live_keys()
    if live_keys is None:
        # Don't overwrite previous added/removed counts — emit probe_up=0
        # and leave the gauges at their prior values via partial update.
        # Easiest: re-emit the file with current template-only computation
        # so the dashboard always shows a coherent snapshot.
        write_metrics(probe_up=False, added=0, removed=0)
        return 0

    added = len(live_keys - template_keys)
    removed = len(template_keys - live_keys)
    write_metrics(probe_up=True, added=added, removed=removed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Smoke-test locally**

```bash
TPL=$(nix build --no-link --print-out-paths '/etc/nixos#nixosConfigurations.vulcan.pkgs.openclaw-config-template')
OPENCLAW_TEMPLATE_PATH="$TPL" OPENCLAW_PROBE_SSH_KEY=/root/.ssh/openclaw-probe \
  sudo python3 /etc/nixos/scripts/openclaw-config-drift-check.py
cat /tmp/openclaw_config_drift.prom 2>/dev/null  # may need temp path override for non-root test
```

If running as a normal user, override `METRIC_PATH` via a quick `os.environ` getter — but for the planned production path, the systemd unit runs as openclaw-heal which can write to the textfile dir (mode 1777). Smoke-test in-place once the unit is wired (Task 8).

- [ ] **Step 3: Commit**

```bash
git add scripts/openclaw-config-drift-check.py
git commit -m "feat(openclaw): stdlib drift-check script (template vs live config key sets)"
```

---

## Task 8: NixOS module for the drift check (Deliverable B wiring)

**Files:** Create `/etc/nixos/modules/monitoring/services/openclaw-config-drift-check.nix`

- [ ] **Step 1: Write the module**

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openclawConfigDriftCheck;

  driftScript = pkgs.writers.writePython3Bin "openclaw-config-drift-check" {
    flakeIgnore = [ "E501" "W503" "E265" "E203" ];
  } (builtins.readFile ../../../scripts/openclaw-config-drift-check.py);
in
{
  options.services.openclawConfigDriftCheck = {
    enable = lib.mkEnableOption "OpenClaw config schema-drift detector";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.openclaw-config-drift-check = {
      description = "Compare live openclaw.json key set against Nix template";
      after = [
        "openclaw-prepare-secrets.service"
        "microvm@openclaw.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      environment = {
        OPENCLAW_TEMPLATE_PATH = "${pkgs.openclaw-config-template}";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "openclaw-heal";
        Group = "openclaw-heal";
        ExecStart = "${driftScript}/bin/openclaw-config-drift-check";
        LoadCredential = [
          "probe-ssh-key:${config.sops.secrets."openclaw/probe-ssh-private-key".path}"
        ];
        # The python script reads OPENCLAW_PROBE_SSH_KEY for the path.
        # systemd LoadCredential exposes it under %d (CREDENTIALS_DIRECTORY).
        Environment = [
          "OPENCLAW_PROBE_SSH_KEY=%d/probe-ssh-key"
        ];
        RuntimeMaxSec = "120s";
        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
      };
    };

    systemd.timers.openclaw-config-drift-check = {
      description = "Daily OpenClaw config schema-drift check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        RandomizedDelaySec = "20m";
        Persistent = true;
        Unit = "openclaw-config-drift-check.service";
      };
    };
  };
}
```

Notes on `LoadCredential`:
- The sops secret `openclaw/probe-ssh-private-key` is owned `root:root 0400` (already declared in `openclaw-nightly-report.nix`).
- `LoadCredential` copies the file into the unit's per-invocation `$CREDENTIALS_DIRECTORY` with mode 400 owned by the unit's User. The openclaw-heal user gets read access via systemd's machinery without being granted direct fs access to `/run/secrets/openclaw/probe-ssh-private-key`.
- The systemd `%d` specifier expands to `$CREDENTIALS_DIRECTORY`.

- [ ] **Step 2: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/modules/monitoring/services/openclaw-config-drift-check.nix'
```

- [ ] **Step 3: Commit (module only; not wired into host yet)**

```bash
git add modules/monitoring/services/openclaw-config-drift-check.nix
git commit -m "feat(monitoring): NixOS module for openclaw config drift detector"
```

---

## Task 9: Alert rule + host wiring (Deliverable B finalization)

**Files:**
- Modify `/etc/nixos/modules/monitoring/alerts/openclaw.yaml`
- Modify `/etc/nixos/hosts/vulcan/default.nix`

- [ ] **Step 1: Add the alert rule**

In `/etc/nixos/modules/monitoring/alerts/openclaw.yaml`, append a new rule at the end of the existing `groups[0].rules` list:

```yaml
      - alert: OpenClawConfigDrift
        expr: openclaw_config_drift_probe_up == 1 and (openclaw_config_drift_keys_added > 0 or openclaw_config_drift_keys_removed > 0)
        for: 24h
        labels:
          severity: warning
        annotations:
          summary: "OpenClaw config schema-drift detected for 24 hours"
          description: |
            The live openclaw.json key set differs from the Nix-rendered template.
            added={{ $value | printf "%.0f" }} (live-only keys), removed=(see _removed metric).
            Investigate: fetch live config, diff against template, decide whether
            to update template (modules/services/openclaw-config.nix) or update
            the snapshot (tests/openclaw/expected-keys.txt).
```

- [ ] **Step 2: Wire the module into vulcan**

In `/etc/nixos/hosts/vulcan/default.nix`, add the import and enable:

Import (place near the other monitoring module imports):
```nix
    ../../modules/monitoring/services/openclaw-config-drift-check.nix
```

Enable (near other `services.openclaw*` enables):
```nix
  services.openclawConfigDriftCheck.enable = true;
```

- [ ] **Step 3: Format + eval-check**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/hosts/vulcan/default.nix'
nix flake check --no-build /etc/nixos 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add hosts/vulcan/default.nix modules/monitoring/alerts/openclaw.yaml
git commit -m "chore(vulcan): enable openclaw-config-drift-check + OpenClawConfigDrift alert"
```

---

## Task 10: Build + switch + run-and-verify

**Files:** none

- [ ] **Step 1: Take build lock**

```bash
touch /etc/nixos/.nixos-build
trap 'rm -f /etc/nixos/.nixos-build' EXIT
```

- [ ] **Step 2: Switch**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -8
```

- [ ] **Step 3: Trigger the drift-check manually**

```bash
sudo systemctl start openclaw-config-drift-check.service
sleep 5
systemctl status openclaw-config-drift-check.service --no-pager | head -10
```

Expected: exit 0/SUCCESS, no errors.

- [ ] **Step 4: Verify the metric file**

```bash
cat /var/lib/prometheus-node-exporter-textfiles/openclaw_config_drift.prom
```

Expected: four metrics, `openclaw_config_drift_probe_up 1`, `_keys_added 0`, `_keys_removed 0` (template should perfectly match the live config since they came from the same upstream).

If `_added` or `_removed` is non-zero on day one, the template and live config DO disagree — investigate before treating as a deploy success.

- [ ] **Step 5: Verify timer is scheduled**

```bash
systemctl list-timers openclaw-config-drift-check.timer --no-pager
```

Expected: next fire around 04:00 + random 20m.

- [ ] **Step 6: Release lock**

```bash
rm -f /etc/nixos/.nixos-build
```

- [ ] **Step 7: No commit (runtime state only)**

---

## Task 11: Final pass — flake check, memory note

- [ ] **Step 1: Run all flake checks (now four of them) one final time**

```bash
nix flake check /etc/nixos 2>&1 | tail -15
```

Expected: all four checks succeed.

- [ ] **Step 2: Append to memory**

Add to `/home/johnw/.claude/projects/-etc-nixos/memory/project_hermes_agent.md`:

```markdown

## 2026-05-16 — flake-check coverage hardening

- `nix flake check` now runs four checks: openclaw-config-schema (template
  vs tests/openclaw/expected-keys.txt), openclaw-self-heal-tests,
  openclaw-hermes-smoke-tests, openclaw-nightly-report-tests.
- A regression that drops a key from openclaw-config.nix fails the build.
- A pytest regression in any of the three suites fails the build.
- New runtime check: openclaw-config-drift-check.service runs daily,
  compares live openclaw.json from the guest against the in-store
  template, emits openclaw_config_drift_{probe_up,keys_added,keys_removed,last_run_timestamp_seconds}.prom.
- New alert: OpenClawConfigDrift (warning, 24h gate) catches upstream
  schema additions in production.
- Schema regeneration recipe (when openclaw bumps add keys):
  TPL=$(nix build --no-link --print-out-paths '/etc/nixos#nixosConfigurations.vulcan.pkgs.openclaw-config-template')
  jq -r 'paths | map(tostring) | join(".")' "$TPL" | sort > tests/openclaw/expected-keys.txt
```

- [ ] **Step 3: No commit on memory** (memory lives outside the repo).

---

## What this plan deliberately does NOT do

- **No VM-based integration test booting full openclaw.** Out of scope per spec.
- **No coverage reporting.** Out of scope per spec.
- **No shared SECRET_RE helper.** Each consumer inlines the regex; refactoring to a shared aux is a separate work item.
- **No restart_drift_check action.** Daily cadence + systemd Restart=on-failure is sufficient.

## Rollback

If anything misbehaves:
1. `sudo nixos-rebuild switch --rollback` reverts the module enable + alert rule.
2. Revert the flake.nix commit if the checks themselves are problematic.
3. The new `tests/` directory is harmless to leave in place if everything else rolls back.
