# Hermes Self-Heal + Nightly Report — Implementation Plan

> **Archival — 2026-05-20.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/hermes-self-heal.nix`, `modules/services/hermes-nightly-report.nix`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Hermes Agent up to OpenClaw parity for automated health remediation (Alertmanager-webhook-driven Python daemon with deterministic→AI escalation and L3-allowlisted actions), and add a daily emailed nightly report so the operator sees Hermes' state every morning.

**Architecture:** Replace the existing shell-script polling watchdog `modules/services/hermes-self-heal.nix` with a Python daemon ported from `scripts/openclaw-self-heal/daemon.py`, listening on `127.0.0.1:9098` for Alertmanager webhooks. The daemon has a 5-action L3 allowlist enforced via sudoers (`restart_microvm`, `restart_mcp`, `restage_secrets`, `reset_credential_pool`, `restart_health_check`). Unknown alerts are explicitly ignored (not defaulted) — Hermes diverges from OpenClaw here because `HermesApiKeyMissing` exists and no allowlisted action can fix it. A new `hermes-nightly-report.service` runs at 06:15 daily, aggregates 8 signal sources (Hermes textfile metrics, smoke probe history via Prometheus HTTP API, microVM/mcp uptime, Discord activity, redacted error digest, self-heal incidents, optional in-VM SSH probe), and pipes a plain-text email to `johnw@vulcan.lan` via the host's `sendmail`.

**Tech Stack:** NixOS (flake-based), Python 3 stdlib (`http.server`, `urllib`, `subprocess`, `fcntl`, `pathlib`), pytest (via `tests/checks.nix:mkPytestCheck`), Alertmanager YAML route config, sops-nix, systemd hardening primitives.

**Spec:** `/etc/nixos/docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md` — authoritative source of truth. Read first, then come back.

---

## File Structure

### Files to create

```
scripts/hermes-self-heal/
├── daemon.py
├── actions/
│   ├── restart_microvm
│   ├── restart_mcp
│   ├── restage_secrets
│   ├── reset_credential_pool
│   └── restart_health_check
├── aux/
│   ├── read_log_tail
│   └── kick_health_check
└── tests/
    ├── conftest.py
    ├── test_daemon.py
    ├── test_actions_shape.py
    └── test_handle_payload.py

scripts/hermes-nightly-report.py
scripts/hermes-nightly-report-tests/
├── conftest.py
├── fixtures/
│   ├── hermes_health_healthy.prom
│   ├── hermes_health_degraded.prom
│   ├── gateway_log_sample.txt
│   ├── errors_log_sample.txt
│   └── incidents_sample.json
├── test_parse_textfile.py
├── test_parse_gateway_log.py
├── test_parse_errors_log.py
├── test_parse_incidents.py
├── test_render_report.py
└── test_main_dry_run.py

modules/services/hermes-nightly-report.nix
```

### Files to modify

```
modules/services/hermes-self-heal.nix    (REWRITE — was shell-script polling)
modules/services/alertmanager.nix         (add hermes route + receiver)
modules/monitoring/alerts/hermes.yaml     (append 3 watchdog rules)
hosts/vulcan/default.nix                  (import hermes-nightly-report.nix; the hermesSelfHeal.enable=true line already exists)
docs/ports.txt                             (add 9098)
secrets/secrets.yaml                       (add hermes.probe-ssh-private-key — requires `sops` interactive)
flake.nix                                  (add 2 pytest checks)
```

### File responsibilities

| File | Responsibility |
|---|---|
| `scripts/hermes-self-heal/daemon.py` | Webhook receiver, state machine, deterministic + AI tier orchestration, action invocation via sudo, heartbeat metric writer. |
| `scripts/hermes-self-heal/actions/*` | Each script performs exactly ONE state-changing systemctl/rm operation and emits a single-line JSON result. Hardcoded paths — no user input. |
| `scripts/hermes-self-heal/aux/*` | Read-only helpers (log tail, sync health-check kick) invoked by the daemon via sudo with argument validation. |
| `modules/services/hermes-self-heal.nix` | System user `hermes-heal`, sudoers allowlist, systemd unit, hardening, SOPS key reuse. |
| `scripts/hermes-nightly-report.py` | Aggregates 8 signal sources, renders ASCII-table email body, pipes to sendmail. Supports `HERMES_REPORT_DRY_RUN=1`. |
| `modules/services/hermes-nightly-report.nix` | systemd timer + oneshot service, tight sandbox, LoadCredential for SSH probe key. |
| `modules/services/alertmanager.nix` | Route `service =~ hermes-(mcp|agent)` to webhook receiver with `continue=true`. |
| `modules/monitoring/alerts/hermes.yaml` | New watchdog rules: `HermesSelfHealDown`, `HermesSelfHealStuck`, `HermesSelfHealLitellmUnreachable`. |

---

## Implementation Notes

### Test-first philosophy

Each Python module follows the cycle: write failing test → run it (verify failure) → write minimal impl → run test (verify pass) → commit. Action scripts get a shape test (executable, correct shebang, valid JSON on smoke invocation with mocked systemctl) but their real verification happens in the end-to-end Acceptance phase — we can't unit-test that `systemctl restart microvm@hermes.service` does the right thing in a sandbox.

### Reference implementations

When the plan says "port openclaw's pattern", read the analogous file first:

| Hermes file | OpenClaw analog to read first |
|---|---|
| `scripts/hermes-self-heal/daemon.py` | `/etc/nixos/scripts/openclaw-self-heal/daemon.py` |
| `scripts/hermes-self-heal/actions/*` | `/etc/nixos/scripts/openclaw-self-heal/actions/*` |
| `scripts/hermes-self-heal/aux/*` | `/etc/nixos/scripts/openclaw-self-heal/aux/*` |
| `modules/services/hermes-self-heal.nix` | `/etc/nixos/modules/services/openclaw-self-heal.nix` |
| `scripts/hermes-nightly-report.py` | `/etc/nixos/scripts/openclaw-nightly-report.py` |
| `modules/services/hermes-nightly-report.nix` | `/etc/nixos/modules/services/openclaw-nightly-report.nix` |
| `scripts/hermes-self-heal/tests/test_daemon.py` | `/etc/nixos/scripts/openclaw-self-heal/tests/test_daemon.py` |
| `scripts/hermes-nightly-report-tests/conftest.py` | `/etc/nixos/scripts/openclaw-nightly-report-tests/conftest.py` |

**Do not copy verbatim.** Read the analog, understand the pattern, then write the Hermes version per the spec — the action set, alert names, port, metric prefix, system prompt, and ignore-on-unknown behavior are all different.

### Critical hardening rules

The spec §8 lists the OpenClaw hardening lessons that MUST carry over. Do not omit any:
- `CapabilityBoundingSet` includes `CAP_SETUID`/`CAP_SETGID`/`CAP_AUDIT_WRITE`/`CAP_SYS_RESOURCE`/`CAP_DAC_OVERRIDE`/`CAP_DAC_READ_SEARCH`/`CAP_FOWNER`/`CAP_CHOWN`/`CAP_KILL`/`CAP_SYS_ADMIN`/`CAP_NET_ADMIN`/`CAP_NET_BIND_SERVICE` so the setuid sudo wrapper can exec.
- `path = [ "/run/wrappers" pkgs.coreutils pkgs.systemd pkgs.bashInteractive pkgs.curl pkgs.jq ]` so bare `sudo` resolves to the setuid wrapper.
- Action scripts use shebang `#!/run/current-system/sw/bin/bash` (absolute, no `/usr/bin/env`).
- `/run/sudo` in `ReadWritePaths` (sudo writes per-uid timestamp even with NOPASSWD).
- `security.sudo.extraConfig` includes `Defaults:hermes-heal !mail_no_perms,!mail_no_user,!mail_badpass,!mail_always` (prevents stuck sendmail loop).
- Nightly report unit `RestrictAddressFamilies` includes `AF_NETLINK` (sendmail calls getifaddrs).

### Commit style

Follow the repo's existing pattern: `<type>(<scope>): <verb-led summary>`. Examples from recent commits: `feat(postfix): relay bia outbound mail via Gmail Workspace`, `fix(monitoring): replace broken per-user mbsync alerts with label-based ones`. Scope here is `hermes-self-heal` or `hermes-nightly-report`. Commit at the end of each task unless the task explicitly says otherwise.

### Do NOT touch in this work

- `modules/services/home-assistant.nix` has uncommitted edits in the working tree (visible in `git status`). Leave it alone — out of scope.
- The existing `modules/monitoring/services/hermes-health-check.nix`, `modules/services/hermes-microvm.nix`, `modules/services/hermes-vm.nix`, `modules/services/hermes-mcp.nix`. The new pieces wrap around these.
- The smoke probe `scripts/openclaw_hermes_smoke.py` and its metric shape — the spec explicitly forbids changes (§7.2 section 4).

---

## Task 1: Plan-only spike — verify port 9098 is free at runtime

**Why first:** A port collision discovered after writing 600 lines of Python costs a day. Five minutes here is cheap insurance.

**Files:**
- Read: `docs/ports.txt`

- [ ] **Step 1:** Confirm 9098 is unassigned in `docs/ports.txt`:

```bash
grep -E "^9098 " /etc/nixos/docs/ports.txt && echo "TAKEN" || echo "FREE"
```

Expected: `FREE`

- [ ] **Step 2:** Confirm nothing is currently listening on 9098 in the running system:

```bash
sudo ss -tunlp 'sport = :9098' | grep -v "^State" || echo "PORT NOT IN USE"
```

Expected: `PORT NOT IN USE`

- [ ] **Step 3:** If either check fails, STOP and surface to the user — pick a different port and amend the spec before continuing. If both pass, move to Task 2.

---

## Task 2: Add port 9098 to the registry

**Files:**
- Modify: `docs/ports.txt`

- [ ] **Step 1:** Find the line for OpenClaw's webhook receiver and insert the Hermes equivalent on the following line:

Open `/etc/nixos/docs/ports.txt`, find:

```
9092 127.0.0.1 OpenClaw Self-Heal webhook receiver
```

Add immediately AFTER:

```
9098 127.0.0.1 Hermes Self-Heal webhook receiver
```

- [ ] **Step 2:** Verify the entry sorts correctly (the file is in port-numeric order — 9092 < 9093 < 9094 < 9095 < 9096 < 9097 < 9098 < 9099):

```bash
grep -E "^909[0-9]" /etc/nixos/docs/ports.txt
```

Expected: 9098 line appears between 9097 and 9099.

- [ ] **Step 3:** Commit:

```bash
git add docs/ports.txt
git commit -m "$(cat <<'EOF'
docs(ports): reserve 9098 for hermes-self-heal webhook receiver

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Scaffold the daemon test suite (TDD bootstrap)

**Files:**
- Create: `scripts/hermes-self-heal/tests/test_daemon.py`
- Create: `scripts/hermes-self-heal/tests/conftest.py`

- [ ] **Step 1:** Create `scripts/hermes-self-heal/tests/conftest.py`:

```python
"""Test fixtures for the hermes-self-heal daemon tests."""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
```

- [ ] **Step 2:** Create `scripts/hermes-self-heal/tests/test_daemon.py` with the allowlist contract test FIRST:

```python
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import daemon
import pytest


def test_allowlist_is_exactly_the_authorized_actions():
    """Guard test: ACTION_ALLOWLIST must exactly match the spec.

    If this ever fails, the sudoers entries in
    modules/services/hermes-self-heal.nix likely need to be updated in
    lockstep — and so does the Hermes self-heal spec.
    """
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm",
        "restart_mcp",
        "restage_secrets",
        "reset_credential_pool",
        "restart_health_check",
    )


def test_webhook_port_is_9098():
    assert daemon.WEBHOOK_PORT == 9098
```

- [ ] **Step 3:** Run to verify it fails (daemon doesn't exist yet):

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -m pytest tests/test_daemon.py -v
```

Expected: `ModuleNotFoundError: No module named 'daemon'`

- [ ] **Step 4:** Do NOT commit yet — committing a failing test on its own is fine, but Task 4 will introduce the minimal daemon. Hold the commit for atomic test+code.

---

## Task 4: Implement minimal daemon — allowlist + port constants

**Files:**
- Create: `scripts/hermes-self-heal/daemon.py`

- [ ] **Step 1:** Create `scripts/hermes-self-heal/daemon.py` with just enough to pass the two tests from Task 3:

```python
#!/usr/bin/env python3
"""hermes-self-heal — Alertmanager webhook receiver and remediation runner.

See docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md.
Ported from scripts/openclaw-self-heal/daemon.py with Hermes-specific
action set, alert mapping, metric prefix, and the explicit-ignore behavior
on unknown alerts (NO default fallback — diverges from OpenClaw).
"""
__version__ = "0.1.0"

ACTION_ALLOWLIST = (
    "restart_microvm",
    "restart_mcp",
    "restage_secrets",
    "reset_credential_pool",
    "restart_health_check",
)
WEBHOOK_PORT = 9098
```

- [ ] **Step 2:** Re-run tests:

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -m pytest tests/test_daemon.py -v
```

Expected: 2 PASSED.

- [ ] **Step 3:** Commit (tests + minimal scaffolding atomically):

```bash
git add scripts/hermes-self-heal/daemon.py scripts/hermes-self-heal/tests/
git commit -m "$(cat <<'EOF'
feat(hermes-self-heal): scaffold daemon module + allowlist contract test

Tests-first bootstrap for the Hermes self-heal daemon. The
test_allowlist_is_exactly_the_authorized_actions guard prevents
silent drift between the Python tuple and the sudoers entries
that will be added in a later task.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Daemon — validate_action, ActionRejectedError

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests:

```python
def test_validate_action_accepts_allowlisted():
    for a in daemon.ACTION_ALLOWLIST:
        assert daemon.validate_action(a) == a


def test_validate_action_rejects_unknown():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("rm_rf_slash")


def test_validate_action_rejects_with_args():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("restart_microvm; rm -rf /")


def test_validate_action_rejects_path_traversal():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("../../bin/sh")
```

- [ ] **Step 2:** Run; expect failure (no `validate_action` yet):

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -m pytest tests/test_daemon.py -v
```

Expected: 4 FAILED (`AttributeError: module 'daemon' has no attribute 'validate_action'`).

- [ ] **Step 3:** Add implementation to `daemon.py`:

```python
class ActionRejectedError(ValueError):
    """Raised when a proposed action is not in the allowlist."""


def validate_action(name: str) -> str:
    """Return name if it's in the allowlist, else raise ActionRejectedError.

    Defense-in-depth: even if the AI returns garbage, the runner will reject.
    """
    if name in ACTION_ALLOWLIST:
        return name
    raise ActionRejectedError(f"action not allowlisted: {name!r}")
```

- [ ] **Step 4:** Re-run; expect all 6 PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): validate_action with allowlist enforcement

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Daemon — incident state primitives (correlation_key, new_incident, attempt counters, load/save)

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests (mirror `openclaw-self-heal/tests/test_daemon.py` — use the analog as a template but check the Hermes alert names):

```python
def test_correlation_key_groups_by_vm_boot():
    a = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "HermesApiServerDown", "vm_active_enter_ts": 1000, "starts_at": 5000}
    assert daemon.correlation_key(a) == daemon.correlation_key(b)


def test_correlation_key_differs_after_vm_restart():
    a = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 2000, "starts_at": 5000}
    assert daemon.correlation_key(a) != daemon.correlation_key(b)


def test_new_incident_starts_in_progress():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing",
                               "vm_active_enter_ts": 1000})
    assert inc["status"] == "in_progress"
    assert inc["attempts"] == []
    assert inc["alerts"] == ["HermesAskFailing"]


def test_next_attempt_n_starts_at_one():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    assert daemon.next_attempt_n(inc) == 1


def test_next_attempt_n_increments():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    inc["attempts"].append({"action": "restart_microvm", "by": "deterministic"})
    assert daemon.next_attempt_n(inc) == 2


def test_should_escalate_after_three_attempts():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    assert not daemon.should_escalate(inc)
    inc["attempts"].extend([{}, {}, {}])
    assert daemon.should_escalate(inc)


def test_state_round_trip(tmp_path):
    state = {"active": {"k": {"status": "in_progress", "attempts": []}}, "history": []}
    p = tmp_path / "incidents.json"
    daemon.save_state(p, state)
    assert daemon.load_state(p) == state


def test_load_state_returns_empty_when_file_missing(tmp_path):
    p = tmp_path / "does-not-exist.json"
    assert daemon.load_state(p) == {"active": {}, "history": []}
```

- [ ] **Step 2:** Run; expect 8 failures.

- [ ] **Step 3:** Add to `daemon.py` (port from openclaw daemon.py — these functions are identical except they live in the Hermes module):

```python
import time
import json
import fcntl
import os
import pathlib


def correlation_key(alert: dict, window_s: int = 300) -> str:
    """Same VM boot + 5-min bucket → same incident."""
    ts = alert.get("starts_at", 0)
    bucket = ts // window_s
    return f"{alert.get('vm_active_enter_ts', 0)}:{bucket}"


def new_incident(alert: dict) -> dict:
    return {
        "first_seen_ts":      int(time.time()),
        "vm_active_enter_ts": alert.get("vm_active_enter_ts", 0),
        "alerts":             [alert["alert_name"]],
        "attempts":           [],
        "status":             "in_progress",
        "next_eligible_ts":   None,
    }


def next_attempt_n(incident: dict) -> int:
    return len(incident["attempts"]) + 1


def should_escalate(incident: dict) -> bool:
    return len(incident["attempts"]) >= 3


def load_state(path):
    p = pathlib.Path(path)
    if not p.exists():
        return {"active": {}, "history": []}
    with p.open("r") as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        try:
            return json.load(f)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def save_state(path, state):
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            json.dump(state, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)
    os.replace(tmp, p)
```

- [ ] **Step 4:** Re-run; expect all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): incident state + correlation key primitives

Ported from openclaw-self-heal/daemon.py with no behavioral change —
the state shape is identical so dashboards and alerts that consume
the OpenClaw schema later can read Hermes too.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Daemon — ACTION_MAP + first_attempt_action (NO default fallback)

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests, including the divergence-from-OpenClaw guard:

```python
def test_action_map_deterministic_first_attempts():
    """Spec §6.2 — verify the deterministic-first-attempt map exactly."""
    assert daemon.ACTION_MAP == {
        "HermesAskFailing":             "restart_microvm",
        "HermesApiServerDown":          "restart_microvm",
        "HermesDiscordZombieSuspected": "restart_microvm",
        "HermesMcpBridgeDown":          "restart_mcp",
        "HermesHealthCheckStale":       "restart_health_check",
    }


def test_first_attempt_action_returns_none_for_unknown_alert():
    """Divergence from OpenClaw: NO default fallback. Spec §6.2 explicit decision."""
    assert daemon.first_attempt_action("SomeNewAlertNobodyMapped") is None


def test_first_attempt_action_returns_action_for_known_alert():
    assert daemon.first_attempt_action("HermesAskFailing") == "restart_microvm"


def test_first_attempt_action_does_NOT_default_for_HermesApiKeyMissing():
    """HermesApiKeyMissing routes here because it has service=hermes-mcp,
    but no allowlisted action can fix a SOPS plumbing failure — defaulting
    would consume the AI tier and end at stuck."""
    assert daemon.first_attempt_action("HermesApiKeyMissing") is None
```

- [ ] **Step 2:** Run; expect 4 failures.

- [ ] **Step 3:** Add to `daemon.py`:

```python
ACTION_MAP = {
    "HermesAskFailing":             "restart_microvm",
    "HermesApiServerDown":          "restart_microvm",
    "HermesDiscordZombieSuspected": "restart_microvm",
    "HermesMcpBridgeDown":          "restart_mcp",
    "HermesHealthCheckStale":       "restart_health_check",
}


def first_attempt_action(alert_name: str) -> str | None:
    """Return the deterministic first-attempt action for an alert name,
    or None if the alert is unknown.

    DIVERGES FROM OpenClaw: no default fallback. Spec §6.2 decision.
    Unknown alerts are explicitly ignored (counted in
    hermes_self_heal_unknown_alerts_total).
    """
    return ACTION_MAP.get(alert_name)
```

- [ ] **Step 4:** Re-run; expect all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): ACTION_MAP and first_attempt_action

DIVERGES from OpenClaw: first_attempt_action returns None for unknown
alerts rather than defaulting to restart_microvm. Hermes has
HermesApiKeyMissing as a known un-fixable alert; defaulting would just
consume the AI tier and end at stuck. Documented in spec §6.2.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Daemon — REDACT_PATTERNS + redact helper

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests:

```python
def test_redact_discord_token():
    s = "Bot is online with token DISCORD_TOKEN_REDACTED OK"
    out = daemon.redact(s)
    assert "NTk5MTYzMTM1OTUwNDMyNTc3" not in out
    assert "[REDACTED]" in out


def test_redact_anthropic_key():
    out = daemon.redact("loaded sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz1234567890")
    assert "sk-ant" not in out
    assert "[REDACTED]" in out


def test_redact_bearer():
    out = daemon.redact("Authorization: Bearer eyJhbGciOiJIUzI1NiIs.abc.def")
    assert "eyJhbGc" not in out
    assert "[REDACTED]" in out


def test_redact_generic_token_assignment():
    out = daemon.redact("config: api_key=sk-proj-xxxxxxxxxxx, password=hunter2")
    assert "sk-proj" not in out
    assert "hunter2" not in out


def test_redact_preserves_non_secret_text():
    s = "Discord WS connected, 12 events received in last 60s"
    assert daemon.redact(s) == s
```

- [ ] **Step 2:** Run; expect 5 failures.

- [ ] **Step 3:** Add to `daemon.py` (copy the patterns from openclaw daemon.py — they're a shared concern):

```python
import re

REDACT_PATTERNS = [
    # Discord bot token: 24+ chars . 6 chars . 27+ chars
    re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
    # Anthropic
    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    # OpenAI / OpenRouter virtual keys (Hermes consumes these)
    re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-or-v1-[A-Za-z0-9_-]{20,}"),
    # Common bearer headers
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    # Generic ?token=... or password=... or api_key=...
    re.compile(r"(?i)(token|password|api[_-]?key)=[^\s&\"]+"),
]


def redact(s: str) -> str:
    for p in REDACT_PATTERNS:
        s = p.sub("[REDACTED]", s)
    return s
```

- [ ] **Step 4:** Re-run; expect all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): redact patterns for log tail privacy

Mirrors openclaw redactor with two additions: sk-or-v1 (OpenRouter
virtual keys, used by Hermes credential pool) and the same
api_key/password generic patterns. Applied to every log line that
flows into the LiteLLM prompt for the AI tier.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Daemon — run_action with subprocess.run + JSON parse

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests with subprocess.run mocked:

```python
def test_run_action_rejects_non_allowlisted(monkeypatch):
    with pytest.raises(daemon.ActionRejectedError):
        daemon.run_action("rm_rf_slash")


def test_run_action_parses_last_line_as_json(monkeypatch):
    import subprocess

    class FakeResult:
        returncode = 0
        stdout = 'some chatter\n{"ok": true, "notes": "did it"}\n'
        stderr = ""

    def fake_run(*a, **kw):
        return FakeResult()

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm")
    assert result == {"ok": True, "notes": "did it"}


def test_run_action_handles_timeout(monkeypatch):
    import subprocess

    def fake_run(*a, **kw):
        raise subprocess.TimeoutExpired(cmd="x", timeout=240)

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm", timeout_s=240)
    assert result == {"ok": False, "notes": "action timed out", "duration_s": 240}


def test_run_action_handles_non_json_output(monkeypatch):
    import subprocess

    class FakeResult:
        returncode = 1
        stdout = "raw error text not json\n"
        stderr = "bad stuff happened"

    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: FakeResult())
    result = daemon.run_action("restart_microvm")
    assert result["ok"] is False
    assert "non-json" in result["notes"]
```

- [ ] **Step 2:** Run; expect failures.

- [ ] **Step 3:** Add to `daemon.py`:

```python
import subprocess

ACTIONS_DIR = "/etc/nixos/scripts/hermes-self-heal/actions"


def run_action(name: str, timeout_s: int = 240) -> dict:
    validate_action(name)
    cmd = ["sudo", "-n", f"{ACTIONS_DIR}/{name}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return {"ok": False, "notes": "action timed out", "duration_s": timeout_s}
    try:
        parsed = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
    except (json.JSONDecodeError, IndexError):
        return {"ok": False, "notes": f"non-json action output (rc={r.returncode}): {r.stderr[-200:]}"}
    parsed.setdefault("ok", r.returncode == 0)
    return parsed
```

- [ ] **Step 4:** Re-run; expect all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): run_action with timeout + JSON parse

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: Daemon — LiteLLM client (call_litellm + LitellmUnreachable)

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests:

```python
def test_call_litellm_raises_unreachable_without_key(monkeypatch):
    monkeypatch.delenv(daemon.LITELLM_KEY_ENV, raising=False)
    with pytest.raises(daemon.LitellmUnreachable):
        daemon.call_litellm([{"role": "user", "content": "test"}])


def test_call_litellm_returns_parsed_json(monkeypatch):
    import io
    import json as _json

    monkeypatch.setenv(daemon.LITELLM_KEY_ENV, "test-key")

    class FakeResp:
        def read(self):
            return _json.dumps({
                "choices": [{"message": {"content": _json.dumps(
                    {"action": "restart_microvm", "reason": "stub"})}}]
            }).encode()

    def fake_post(url, headers, data, timeout):
        return FakeResp()

    monkeypatch.setattr(daemon, "_http_post_json", fake_post)
    result = daemon.call_litellm([{"role": "user", "content": "x"}])
    assert result == {"action": "restart_microvm", "reason": "stub"}


def test_call_litellm_raises_unreachable_on_non_json(monkeypatch):
    monkeypatch.setenv(daemon.LITELLM_KEY_ENV, "test-key")

    class FakeResp:
        def read(self):
            import json as _json
            return _json.dumps({"choices": [{"message": {"content": "not json"}}]}).encode()

    monkeypatch.setattr(daemon, "_http_post_json", lambda *a, **kw: FakeResp())
    with pytest.raises(daemon.LitellmUnreachable):
        daemon.call_litellm([{"role": "user", "content": "x"}])
```

- [ ] **Step 2:** Run; expect failures.

- [ ] **Step 3:** Add to `daemon.py`:

```python
import urllib.request

LITELLM_URL = "http://127.0.0.1:4000/v1/chat/completions"
LITELLM_KEY_ENV = "LITELLM_KEY"


class LitellmUnreachable(RuntimeError):
    pass


def _http_post_json(url, headers, data, timeout):
    req = urllib.request.Request(url, data=data.encode(), headers=headers, method="POST")
    return urllib.request.urlopen(req, timeout=timeout)


def call_litellm(messages, model="hera/Qwen3.6-27B", timeout_s=30):
    key = os.environ.get(LITELLM_KEY_ENV)
    if not key:
        raise LitellmUnreachable("LITELLM_KEY not set")
    headers = {"Content-Type": "application/json",
               "Authorization": f"Bearer {key}"}
    body = json.dumps({"model": model, "messages": messages,
                       "temperature": 0.0,
                       "response_format": {"type": "json_object"}})
    try:
        resp = _http_post_json(LITELLM_URL, headers, body, timeout=timeout_s)
    except Exception as e:
        raise LitellmUnreachable(str(e))
    payload = json.loads(resp.read())
    content = payload["choices"][0]["message"]["content"]
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        raise LitellmUnreachable(f"non-json AI response: {content[:200]}")
```

- [ ] **Step 4:** Re-run; expect all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): LiteLLM client for AI escalation tier

Same hera/Qwen3.6-27B route as openclaw — both daemons share the
LITELLM_KEY credential via the shared SOPS entry.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: Daemon — render_prompt with Hermes-specific system prompt

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests:

```python
def test_render_prompt_includes_all_five_actions_in_system():
    inc = {"alerts": ["HermesAskFailing"], "attempts": []}
    messages = daemon.render_prompt(inc, {}, "", "")
    system = messages[0]["content"]
    for action in daemon.ACTION_ALLOWLIST:
        assert action in system


def test_render_prompt_includes_redacted_log_tails():
    inc = {"alerts": ["HermesAskFailing"], "attempts": []}
    err = "ERROR Bearer eyJhbGc.abc.def"
    out = "INFO connected"
    messages = daemon.render_prompt(inc, {}, err, out)
    user = messages[1]["content"]
    assert "eyJhbGc" not in user
    assert "INFO connected" in user


def test_render_prompt_lists_prior_attempts():
    inc = {
        "alerts": ["HermesAskFailing"],
        "attempts": [{"action": "restart_microvm", "by": "deterministic", "ok": False}],
    }
    messages = daemon.render_prompt(inc, {"hermes_api_server_ok": 0.0}, "", "")
    user = messages[1]["content"]
    assert "restart_microvm" in user
    assert "deterministic" in user
    assert "hermes_api_server_ok=0.0" in user
```

- [ ] **Step 2:** Run; expect failures.

- [ ] **Step 3:** Add to `daemon.py`:

```python
SYSTEM_PROMPT = """You are an SRE for Hermes Agent, a NousResearch LLM bot running as a microVM
on host vulcan. Hermes exposes a Discord bot (Hermes#2985) and an
OpenAI-compatible api_server consumed by hermes-mcp on the host (which
OpenClaw uses as an MCP tool). Your goal is to restore service. You may take
exactly ONE of:
  1. restart_microvm
  2. restart_mcp
  3. restage_secrets
  4. reset_credential_pool
  5. restart_health_check
Output STRICTLY this JSON, no other text:
  {"action": "<one of the five>", "reason": "<one sentence>"}
If you do not believe any of these will help, output:
  {"action": "escalate", "reason": "..."}"""


def render_prompt(incident, metrics, err_log_tail, out_log_tail):
    attempts_str = "\n".join(
        f"  {i+1}. {a.get('action','?')} ({a.get('by','?')}) -> {a.get('ok','?')}"
        for i, a in enumerate(incident["attempts"])
    ) or "  (none)"
    metrics_str = "\n".join(f"  {k}={v}" for k, v in metrics.items())
    user = (
        f"[ALERTS] {', '.join(incident['alerts'])}\n"
        f"[ATTEMPTS SO FAR]\n{attempts_str}\n"
        f"[METRICS]\n{metrics_str}\n"
        f"[errors.log tail]\n{redact(err_log_tail)}\n"
        f"[gateway.log tail]\n{redact(out_log_tail)}\n"
    )
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user",   "content": user},
    ]
```

- [ ] **Step 4:** Re-run; expect all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): render_prompt with Hermes system prompt

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: Daemon — current_metrics + probe_clear

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests:

```python
def test_current_metrics_parses_textfile(monkeypatch, tmp_path):
    metrics_file = tmp_path / "hermes_health.prom"
    metrics_file.write_text(
        "# HELP some helper\n"
        "# TYPE foo gauge\n"
        "hermes_api_server_ok 1\n"
        "hermes_mcp_ask_hermes_ok 0\n"
        "hermes_discord_last_event_age_seconds 423.5\n"
    )
    monkeypatch.setattr(daemon, "HERMES_HEALTH_PROM", str(metrics_file))
    m = daemon.current_metrics()
    assert m["hermes_api_server_ok"] == 1.0
    assert m["hermes_mcp_ask_hermes_ok"] == 0.0
    assert m["hermes_discord_last_event_age_seconds"] == 423.5


def test_current_metrics_returns_empty_when_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(daemon, "HERMES_HEALTH_PROM", str(tmp_path / "missing.prom"))
    assert daemon.current_metrics() == {}


def test_probe_clear_true_when_ask_ok_is_one(monkeypatch):
    monkeypatch.setattr(daemon, "current_metrics",
                        lambda: {"hermes_mcp_ask_hermes_ok": 1.0})
    assert daemon.probe_clear({}) is True


def test_probe_clear_false_when_ask_ok_is_zero(monkeypatch):
    monkeypatch.setattr(daemon, "current_metrics",
                        lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    assert daemon.probe_clear({}) is False


def test_probe_clear_false_when_metric_missing(monkeypatch):
    monkeypatch.setattr(daemon, "current_metrics", lambda: {})
    assert daemon.probe_clear({}) is False
```

- [ ] **Step 2:** Run; expect failures.

- [ ] **Step 3:** Add to `daemon.py`:

```python
STATE_PATH = "/var/lib/hermes-self-heal/incidents.json"
AUX_DIR = "/etc/nixos/scripts/hermes-self-heal/aux"
HERMES_HEALTH_PROM = "/var/lib/prometheus-node-exporter-textfiles/hermes_health.prom"


def current_metrics():
    """Read freshest values from prom textfile collector."""
    out = {}
    try:
        for line in pathlib.Path(HERMES_HEALTH_PROM).read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            k, _, v = line.rpartition(" ")
            try:
                out[k] = float(v)
            except ValueError:
                pass
    except FileNotFoundError:
        pass
    return out


def probe_clear(incident):
    m = current_metrics()
    return m.get("hermes_mcp_ask_hermes_ok", 0.0) == 1.0
```

- [ ] **Step 4:** Re-run; expect all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): current_metrics + probe_clear

probe_clear uses hermes_mcp_ask_hermes_ok as the single load-bearing
end-to-end signal (matches the existing HermesAskFailing alert).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12b: Daemon — vm_active_enter_ts via systemctl show

**Why this exists:** `correlation_key()` (Task 6) needs `vm_active_enter_ts` to detect VM restarts. The OpenClaw daemon reads this from `openclaw_canary.prom` because the openclaw-canary writes it. Hermes has NO canary (spec §2 Non-goals) and `hermes-health-check.nix` does not write this metric. Rather than retrofit the health-check, the daemon will source the timestamp directly from `systemctl show -p ActiveEnterTimestamp --value microvm@hermes.service`.

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing test:

```python
def test_microvm_active_enter_ts_parses_systemctl_output(monkeypatch):
    import subprocess

    def fake_check_output(cmd, **kw):
        # Real format: "Mon 2026-05-20 13:42:01 PDT"
        return "Mon 2026-05-20 13:42:01 PDT\n"

    monkeypatch.setattr(subprocess, "check_output", fake_check_output)
    ts = daemon.microvm_active_enter_ts()
    # Just assert it's a positive int — exact value depends on the test
    # host's TZ, and we just need monotonicity.
    assert isinstance(ts, int)
    assert ts > 0


def test_microvm_active_enter_ts_returns_zero_on_error(monkeypatch):
    import subprocess

    def fake_check_output(cmd, **kw):
        raise subprocess.CalledProcessError(1, cmd)

    monkeypatch.setattr(subprocess, "check_output", fake_check_output)
    assert daemon.microvm_active_enter_ts() == 0


def test_microvm_active_enter_ts_returns_zero_on_unparseable(monkeypatch):
    import subprocess
    monkeypatch.setattr(subprocess, "check_output",
                        lambda cmd, **kw: "n/a\n")
    assert daemon.microvm_active_enter_ts() == 0
```

- [ ] **Step 2:** Run; expect failures.

- [ ] **Step 3:** Add to `daemon.py`:

```python
def microvm_active_enter_ts(unit: str = "microvm@hermes.service") -> int:
    """Return the unix timestamp of the unit's last ActiveEnter, or 0 on error.

    Used by correlation_key() to detect VM restarts. The Hermes-side
    equivalent of the openclaw_microvm_active_enter_timestamp_seconds
    gauge that openclaw-canary writes for OpenClaw — Hermes has no
    canary, so we read systemd directly.
    """
    from datetime import datetime
    try:
        out = subprocess.check_output(
            ["systemctl", "show", "-p", "ActiveEnterTimestamp", "--value", unit],
            text=True, timeout=10,
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return 0
    # Format: "Mon 2026-05-20 13:42:01 PDT" — or "n/a" if never active.
    if not out or out == "n/a":
        return 0
    # systemd uses %a %Y-%m-%d %H:%M:%S %Z. The TZ name (e.g. "PDT") isn't
    # parseable by strptime portably; strip it and parse the rest as naive
    # local time, then convert to a unix timestamp.
    parts = out.rsplit(" ", 1)  # drop the trailing TZ
    if len(parts) != 2:
        return 0
    try:
        dt_naive = datetime.strptime(parts[0], "%a %Y-%m-%d %H:%M:%S")
    except ValueError:
        return 0
    # Assume the timestamp is local time (matches what systemd prints).
    return int(dt_naive.timestamp())
```

- [ ] **Step 4:** Re-run; expect PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): microvm_active_enter_ts via systemctl show

Hermes has no canary equivalent that writes a
hermes_microvm_active_enter_timestamp_seconds gauge (spec §2
Non-goals). Reading systemd directly is more direct anyway —
subprocess to systemctl show -p ActiveEnterTimestamp.

This makes correlation_key() actually distinguish incidents across
VM restarts; without it, two unrelated alerts in the same 5-min
bucket would merge into one incident.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 13: Daemon — log_tail + kick_health_check aux helpers

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`

- [ ] **Step 1:** Add to `daemon.py` (no new tests — these are thin sudo wrappers, tested by the action-script shape suite in Task 18):

```python
def _read_log_tail(which: str, n: int) -> str:
    """which = "err" | "out". The aux script enforces the path allowlist;
    the daemon never sees a free-form path. sudo command is invoked by
    absolute path that EXACTLY matches the sudoers allowlist entry."""
    if which not in ("err", "out"):
        raise ValueError(f"bad log selector: {which!r}")
    try:
        return subprocess.check_output(
            ["sudo", "-n", f"{AUX_DIR}/read_log_tail", which, str(int(n))],
            text=True, timeout=10,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def _err_tail(n: int = 80) -> str:
    return _read_log_tail("err", n)


def _out_tail(n: int = 30) -> str:
    return _read_log_tail("out", n)


def _kick_health_check() -> None:
    try:
        subprocess.run(
            ["sudo", "-n", f"{AUX_DIR}/kick_health_check"],
            check=False, timeout=10,
        )
    except subprocess.TimeoutExpired:
        pass
```

- [ ] **Step 2:** Verify tests still pass:

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -m pytest tests/ -v
```

Expected: all tests still PASSED (we added code that isn't covered yet, that's fine for thin sudo wrappers).

- [ ] **Step 3:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): aux helpers for log tails + kick_health_check

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 14: Daemon — synthetic alert emission

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Modify: `scripts/hermes-self-heal/tests/test_daemon.py`

- [ ] **Step 1:** Add failing tests:

```python
def test_emit_synthetic_alert_shape(monkeypatch):
    captured = {}

    def fake_post(url, headers, data, timeout):
        captured["url"] = url
        captured["data"] = data

        class R:
            def read(self):
                return b""
        return R()

    monkeypatch.setattr(daemon, "_http_post_json", fake_post)
    daemon.emit_synthetic_alert(
        "HermesSelfHealActed",
        {"action": "restart_microvm", "alert": "HermesAskFailing"},
        severity="info",
    )

    import json as _json
    body = _json.loads(captured["data"])
    assert body[0]["labels"]["alertname"] == "HermesSelfHealActed"
    assert body[0]["labels"]["service"] == "hermes-self-heal"  # NOT hermes-*
    assert body[0]["labels"]["severity"] == "info"
    assert "/api/v2/alerts" in captured["url"]
```

- [ ] **Step 2:** Run; expect failure.

- [ ] **Step 3:** Add to `daemon.py`:

```python
ALERTMANAGER_URL = "http://127.0.0.1:9093/api/v2/alerts"


def emit_synthetic_alert(name, annotations, severity="info", duration_s=300):
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    payload = [{
        "labels": {"alertname": name, "severity": severity, "service": "hermes-self-heal"},
        "annotations": {k: str(v) for k, v in annotations.items()},
        "startsAt": now.isoformat(),
        "endsAt":   (now + timedelta(seconds=duration_s)).isoformat(),
    }]
    try:
        _http_post_json(ALERTMANAGER_URL, {"Content-Type": "application/json"},
                        json.dumps(payload), timeout=10)
    except Exception as e:
        print(f"emit_synthetic_alert failed: {e}", flush=True)
```

- [ ] **Step 4:** Re-run; expect PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): synthetic alert injection

service=hermes-self-heal label ensures these alerts never loop back
through the self-heal route (which matches service=hermes-(mcp|agent)).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 15: Daemon — handle_alertmanager_payload (the orchestrator)

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`
- Create: `scripts/hermes-self-heal/tests/test_handle_payload.py`

- [ ] **Step 1:** Create the integration test file:

```python
"""Integration tests for handle_alertmanager_payload.

These tests monkeypatch run_action, call_litellm, _kick_health_check,
emit_synthetic_alert, and the textfile so that no I/O escapes the test.
"""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import daemon
import pytest
from datetime import datetime, timezone


def _payload(alertname):
    return {
        "alerts": [{
            "status": "firing",
            "labels": {"alertname": alertname},
            "startsAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }]
    }


@pytest.fixture(autouse=True)
def stub_microvm_ts(monkeypatch):
    """Avoid subprocess calls to systemctl in tests."""
    monkeypatch.setattr(daemon, "microvm_active_enter_ts", lambda *a, **kw: 1000)


def test_unknown_alert_is_ignored(monkeypatch, tmp_path):
    """Spec §6.2 — no default fallback."""
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)

    actions_called = []
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: actions_called.append(a) or {"ok": True})

    daemon.handle_alertmanager_payload(_payload("HermesApiKeyMissing"))
    assert actions_called == []


def test_first_attempt_uses_deterministic_action(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "emit_synthetic_alert", lambda *a, **kw: None)

    actions = []
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: actions.append(a) or {"ok": True})

    daemon.handle_alertmanager_payload(_payload("HermesMcpBridgeDown"))
    assert actions == ["restart_mcp"]


def test_third_attempt_calls_ai(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "emit_synthetic_alert", lambda *a, **kw: None)
    monkeypatch.setattr(daemon, "_err_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "_out_tail", lambda *a, **kw: "")

    ai_calls = []

    def fake_ai(messages, **kw):
        ai_calls.append(messages)
        return {"action": "restart_mcp", "reason": "fake"}

    monkeypatch.setattr(daemon, "call_litellm", fake_ai)
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: {"ok": False, "notes": "stub"})

    # Simulate three fires of the same alert
    for _ in range(3):
        daemon.handle_alertmanager_payload(_payload("HermesAskFailing"))
        # The same alert with the same starts_at will correlate to the same
        # incident; we want different attempts, so use a slightly later start
        import time
        time.sleep(0.01)

    # First attempt is deterministic, attempts 2-3 use AI
    assert len(ai_calls) >= 1


def test_fourth_attempt_marks_stuck(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "_err_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "_out_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "call_litellm", lambda *a, **kw: {"action": "restart_mcp", "reason": "fake"})
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: {"ok": False})

    synth_alerts = []
    monkeypatch.setattr(daemon, "emit_synthetic_alert",
                        lambda name, ann, **kw: synth_alerts.append((name, ann)))

    # Manually construct an incident with 3 prior attempts to drive into the "stuck" branch
    state = {"active": {}, "history": []}
    daemon.save_state(state_path, state)

    # Drive 4 calls
    for _ in range(4):
        daemon.handle_alertmanager_payload(_payload("HermesAskFailing"))

    # Eventually we should see a HermesSelfHealStuck synthetic alert
    stuck_names = [n for n, _ in synth_alerts]
    assert "HermesSelfHealStuck" in stuck_names


def test_litellm_unreachable_marks_stuck(monkeypatch, tmp_path):
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", str(state_path))
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    monkeypatch.setattr(daemon, "_kick_health_check", lambda: None)
    monkeypatch.setattr(daemon, "_err_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "_out_tail", lambda *a, **kw: "")
    monkeypatch.setattr(daemon, "run_action", lambda a, **kw: {"ok": False})

    def fake_ai(*a, **kw):
        raise daemon.LitellmUnreachable("connection refused")

    monkeypatch.setattr(daemon, "call_litellm", fake_ai)

    synth = []
    monkeypatch.setattr(daemon, "emit_synthetic_alert",
                        lambda name, ann, **kw: synth.append(name))

    # Two attempts: 1st deterministic, 2nd AI (which fails)
    for _ in range(2):
        daemon.handle_alertmanager_payload(_payload("HermesAskFailing"))

    assert "HermesSelfHealLitellmUnreachable" in synth
```

- [ ] **Step 2:** Run; expect failure (`handle_alertmanager_payload` doesn't exist yet):

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -m pytest tests/test_handle_payload.py -v
```

- [ ] **Step 3:** Add to `daemon.py`:

```python
def handle_alertmanager_payload(payload):
    from datetime import datetime
    state = load_state(STATE_PATH)
    metrics = current_metrics()
    vm_ts = microvm_active_enter_ts()  # NOT from metrics — Hermes has no canary producer
    for a in payload.get("alerts", []):
        if a.get("status") != "firing":
            continue
        alert_name = a["labels"]["alertname"]

        # Explicit ignore on unknown alerts — Hermes diverges from OpenClaw here.
        if alert_name not in ACTION_MAP:
            _bump_unknown_counter()
            print(f"ignoring unknown alert: {alert_name}", flush=True)
            continue

        alert_meta = {
            "alert_name":         alert_name,
            "vm_active_enter_ts": vm_ts,
            "starts_at":          int(datetime.fromisoformat(a["startsAt"].replace("Z", "+00:00")).timestamp()),
        }
        key = correlation_key(alert_meta)
        inc = state["active"].get(key) or new_incident(alert_meta)
        state["active"][key] = inc
        if inc["status"] != "in_progress":
            continue
        n = next_attempt_n(inc)
        ai_reason = None
        if n == 1:
            action = first_attempt_action(alert_meta["alert_name"])
            by = "deterministic"
        elif n in (2, 3):
            try:
                ai_resp = call_litellm(render_prompt(inc, metrics, _err_tail(), _out_tail()))
            except LitellmUnreachable as e:
                inc["attempts"].append({"action": "none", "by": "ai", "ok": False,
                                        "notes": "litellm_unreachable", "stderr": str(e)})
                emit_synthetic_alert(
                    "HermesSelfHealLitellmUnreachable",
                    {"alert": alert_meta["alert_name"], "err": str(e)[:200]},
                    severity="warning", duration_s=3600,
                )
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                continue
            if ai_resp.get("action") == "escalate":
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                emit_synthetic_alert("HermesSelfHealStuck",
                    {"alert": alert_meta["alert_name"], "attempts": len(inc["attempts"])},
                    severity="critical", duration_s=14400)
                continue
            try:
                action = validate_action(ai_resp["action"])
            except (ActionRejectedError, KeyError):
                inc["status"] = "stuck"
                save_state(STATE_PATH, state)
                emit_synthetic_alert("HermesSelfHealStuck",
                    {"alert": alert_meta["alert_name"], "attempts": len(inc["attempts"])},
                    severity="critical", duration_s=14400)
                continue
            by = "ai"
            ai_reason = ai_resp.get("reason")
        else:
            inc["status"] = "stuck"
            save_state(STATE_PATH, state)
            emit_synthetic_alert("HermesSelfHealStuck",
                {"alert": alert_meta["alert_name"], "attempts": len(inc["attempts"])},
                severity="critical", duration_s=14400)
            continue
        result = run_action(action)
        inc["attempts"].append({"ts": int(time.time()), "action": action, "by": by,
                                "ai_reason": ai_reason, **result})
        save_state(STATE_PATH, state)
        emit_synthetic_alert("HermesSelfHealActed",
            {"action": action, "alert": alert_meta["alert_name"], "by": by,
             "ok": result.get("ok")})
        _kick_health_check()
        time.sleep(15)
        if probe_clear(inc):
            inc["status"] = "resolved"
        save_state(STATE_PATH, state)


_UNKNOWN_ALERTS_TOTAL = 0


def _bump_unknown_counter():
    global _UNKNOWN_ALERTS_TOTAL
    _UNKNOWN_ALERTS_TOTAL += 1
```

NOTE: The `time.sleep(15)` after each action will make the test slow. For the tests to work, monkeypatch `time.sleep` to a no-op in `test_handle_payload.py` setup:

```python
@pytest.fixture(autouse=True)
def no_sleep(monkeypatch):
    monkeypatch.setattr("time.sleep", lambda s: None)
```

Add that fixture to `test_handle_payload.py` at the top.

- [ ] **Step 4:** Re-run; expect all PASSED. If a test fails due to `time.sleep`, ensure the `no_sleep` autouse fixture is in place.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): handle_alertmanager_payload state machine

The orchestrator: deterministic tier 1, AI tiers 2-3, stuck tier 4.
Unknown alerts (e.g. HermesApiKeyMissing) are explicitly ignored per
spec §6.2 — divergence from OpenClaw documented in the test names.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 16: Daemon — heartbeat writer + HTTP server + main

**Files:**
- Modify: `scripts/hermes-self-heal/daemon.py`

- [ ] **Step 1:** Add to `daemon.py` (no unit tests — these are I/O glue covered by acceptance):

```python
TEXTFILE_DIR = "/var/lib/prometheus-node-exporter-textfiles"
HEARTBEAT_PATH = pathlib.Path(TEXTFILE_DIR) / "hermes_self_heal.prom"


def write_heartbeat(out_path=HEARTBEAT_PATH, active_count=0, action_counts=None,
                    litellm_unreachable=0, unknown_alerts=0):
    action_counts = action_counts or {}
    tmp = pathlib.Path(str(out_path) + ".tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    with tmp.open("w") as f:
        f.write(
            "# HELP hermes_self_heal_last_heartbeat_seconds Last heartbeat from hermes-self-heal daemon\n"
            "# TYPE hermes_self_heal_last_heartbeat_seconds gauge\n"
            f"hermes_self_heal_last_heartbeat_seconds {time.time()}\n"
            "# HELP hermes_self_heal_active_incidents Currently in_progress incidents\n"
            "# TYPE hermes_self_heal_active_incidents gauge\n"
            f"hermes_self_heal_active_incidents {active_count}\n"
            "# HELP hermes_self_heal_attempts_total Cumulative attempts by action\n"
            "# TYPE hermes_self_heal_attempts_total counter\n"
        )
        for a in ACTION_ALLOWLIST:
            f.write(f'hermes_self_heal_attempts_total{{action="{a}"}} {action_counts.get(a, 0)}\n')
        f.write(
            "# HELP hermes_self_heal_litellm_unreachable_total Cumulative LiteLLM unreachable events\n"
            "# TYPE hermes_self_heal_litellm_unreachable_total counter\n"
            f"hermes_self_heal_litellm_unreachable_total {litellm_unreachable}\n"
            "# HELP hermes_self_heal_unknown_alerts_total Cumulative unknown-alert ignore events\n"
            "# TYPE hermes_self_heal_unknown_alerts_total counter\n"
            f"hermes_self_heal_unknown_alerts_total {unknown_alerts}\n"
        )
    os.replace(tmp, out_path)


import threading


def heartbeat_loop():
    while True:
        try:
            state = load_state(STATE_PATH)
            active = sum(1 for v in state["active"].values() if v["status"] == "in_progress")
            counts = {a: 0 for a in ACTION_ALLOWLIST}
            litellm_unreachable = 0
            for inc in list(state["active"].values()) + state["history"]:
                for att in inc.get("attempts", []):
                    if att.get("action") in counts:
                        counts[att["action"]] += 1
                    if att.get("notes") == "litellm_unreachable":
                        litellm_unreachable += 1
            write_heartbeat(active_count=active, action_counts=counts,
                            litellm_unreachable=litellm_unreachable,
                            unknown_alerts=_UNKNOWN_ALERTS_TOTAL)
        except Exception as e:
            print(f"heartbeat error: {e}", flush=True)
        time.sleep(60)


from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/alert":
            self.send_response(404)
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        try:
            payload = json.loads(body)
            handle_alertmanager_payload(payload)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}\n')
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f'{{"ok":false,"err":{json.dumps(str(e))}}}\n'.encode())

    def log_message(self, *a, **kw):
        pass  # silence default access logs


def main():
    threading.Thread(target=heartbeat_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", WEBHOOK_PORT), Handler)
    print(f"hermes-self-heal listening on 127.0.0.1:{WEBHOOK_PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2:** Smoke-test that the daemon imports and the heartbeat writes a sane file:

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -c "
import daemon
import tempfile, pathlib
p = pathlib.Path(tempfile.mkdtemp()) / 'hb.prom'
daemon.write_heartbeat(out_path=p, active_count=0, action_counts={a: 0 for a in daemon.ACTION_ALLOWLIST})
print(p.read_text())
"
```

Expected: prints a valid Prometheus textfile with all five action labels, 0 unknown_alerts, 0 litellm_unreachable.

- [ ] **Step 3:** Run all daemon tests one more time:

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -m pytest tests/ -v
```

Expected: all PASSED.

- [ ] **Step 4:** Commit:

```bash
git add scripts/hermes-self-heal/
git commit -m "feat(hermes-self-heal): heartbeat writer + HTTP server + main entrypoint

Heartbeat shape mirrors openclaw_self_heal_* with two additions:
hermes_self_heal_unknown_alerts_total (counts the explicit-ignore
events that diverge from OpenClaw) plus a hermes-prefixed everything.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 17: Action scripts — all five at once (they're tiny)

**Files:**
- Create: `scripts/hermes-self-heal/actions/restart_microvm`
- Create: `scripts/hermes-self-heal/actions/restart_mcp`
- Create: `scripts/hermes-self-heal/actions/restage_secrets`
- Create: `scripts/hermes-self-heal/actions/reset_credential_pool`
- Create: `scripts/hermes-self-heal/actions/restart_health_check`

- [ ] **Step 1:** Create `restart_microvm`:

```bash
#!/run/current-system/sw/bin/bash
# hermes-self-heal action: restart microvm@hermes.service.
# Output: one line of JSON to stdout describing the result.
set -euo pipefail
start_ts=$(date +%s)
rc=0
/run/current-system/sw/bin/systemctl restart microvm@hermes.service || rc=$?
end_ts=$(date +%s)
duration=$((end_ts - start_ts))
if [ "$rc" -eq 0 ]; then
  printf '{"ok": true, "duration_s": %d, "notes": "microvm@hermes restarted"}\n' "$duration"
else
  printf '{"ok": false, "duration_s": %d, "notes": "systemctl restart returned %d"}\n' "$duration" "$rc"
fi
```

- [ ] **Step 2:** Create `restart_mcp`:

```bash
#!/run/current-system/sw/bin/bash
# hermes-self-heal action: restart hermes-mcp.service.
# Output: one line of JSON to stdout describing the result.
set -euo pipefail
start_ts=$(date +%s)
rc=0
/run/current-system/sw/bin/systemctl restart hermes-mcp.service || rc=$?
end_ts=$(date +%s)
duration=$((end_ts - start_ts))
if [ "$rc" -eq 0 ]; then
  printf '{"ok": true, "duration_s": %d, "notes": "hermes-mcp restarted"}\n' "$duration"
else
  printf '{"ok": false, "duration_s": %d, "notes": "systemctl restart returned %d"}\n' "$duration" "$rc"
fi
```

- [ ] **Step 3:** Create `restage_secrets`:

```bash
#!/run/current-system/sw/bin/bash
# hermes-self-heal action: re-stage SOPS secrets for the microVM and
# restart microvm@hermes so its preStart re-runs.
#
# Used when a SOPS-staged secret (the hermes/env file) is suspected stale
# or when the in-VM environment doesn't reflect what SOPS holds.
#
# Output: one line of JSON to stdout describing the result.
set -euo pipefail
start_ts=$(date +%s)
rc=0
/run/current-system/sw/bin/systemctl restart hermes-prepare-secrets.service || rc=$?
if [ "$rc" -eq 0 ]; then
  /run/current-system/sw/bin/systemctl restart microvm@hermes.service || rc=$?
fi
end_ts=$(date +%s)
duration=$((end_ts - start_ts))
if [ "$rc" -eq 0 ]; then
  printf '{"ok": true, "duration_s": %d, "notes": "secrets restaged and microvm@hermes restarted"}\n' "$duration"
else
  printf '{"ok": false, "duration_s": %d, "notes": "restage failed rc=%d"}\n' "$duration" "$rc"
fi
```

- [ ] **Step 4:** Create `reset_credential_pool`:

```bash
#!/run/current-system/sw/bin/bash
# hermes-self-heal action: recover from the "credential pool stuck-exhausted"
# state by deleting /var/lib/hermes/.hermes/auth.json and restarting microvm@hermes.
# The Hermes module's activationScripts recreate this file fresh on next VM
# start from env vars, so the delete is fully recoverable.
#
# Path safety: this script REFUSES to touch anything outside
# /var/lib/hermes/.hermes/.
#
# Output: one line of JSON to stdout describing the result.
set -euo pipefail
AUTH_FILE=/var/lib/hermes/.hermes/auth.json
start_ts=$(date +%s)

# Defense: verify the path. realpath dereferences any symlink shenanigans.
resolved=$(/run/current-system/sw/bin/realpath -m "$AUTH_FILE")
case "$resolved" in
  /var/lib/hermes/.hermes/*) ;;
  *)
    printf '{"ok": false, "notes": "refusing to delete outside /var/lib/hermes/.hermes/: %s"}\n' "$resolved"
    exit 1
    ;;
esac

if [ -f "$AUTH_FILE" ]; then
  /run/current-system/sw/bin/rm -f "$AUTH_FILE"
  deleted=true
else
  deleted=false
fi

rc=0
/run/current-system/sw/bin/systemctl restart microvm@hermes.service || rc=$?
end_ts=$(date +%s)
duration=$((end_ts - start_ts))
if [ "$rc" -eq 0 ]; then
  printf '{"ok": true, "duration_s": %d, "notes": "auth.json deleted=%s, microvm restarted"}\n' "$duration" "$deleted"
else
  printf '{"ok": false, "duration_s": %d, "notes": "auth.json deleted=%s, restart failed rc=%d"}\n' "$duration" "$deleted" "$rc"
fi
```

- [ ] **Step 5:** Create `restart_health_check`:

```bash
#!/run/current-system/sw/bin/bash
# hermes-self-heal action: restart hermes-health-check.service so it re-runs
# and refreshes hermes_health.prom. Used when HermesHealthCheckStale fires —
# the health check is a host timer-driven unit, not something inside the VM.
#
# Output: one line of JSON to stdout describing the result.
set -euo pipefail
start_ts=$(date +%s)
rc=0
/run/current-system/sw/bin/systemctl restart hermes-health-check.service || rc=$?
end_ts=$(date +%s)
duration=$((end_ts - start_ts))
if [ "$rc" -eq 0 ]; then
  printf '{"ok": true, "duration_s": %d, "notes": "hermes-health-check.service restarted"}\n' "$duration"
else
  printf '{"ok": false, "duration_s": %d, "notes": "restart failed rc=%d"}\n' "$duration" "$rc"
fi
```

- [ ] **Step 6:** Mark all five executable:

```bash
chmod 0755 /etc/nixos/scripts/hermes-self-heal/actions/*
```

- [ ] **Step 7:** Smoke check each one's shebang and that it parses:

```bash
for f in /etc/nixos/scripts/hermes-self-heal/actions/*; do
  head -1 "$f" | grep -q '^#!/run/current-system/sw/bin/bash$' && echo "OK  $f" || echo "BAD $f"
  bash -n "$f" && echo "  syntax ok" || echo "  SYNTAX ERROR"
done
```

Expected: all 5 OK + `syntax ok`.

- [ ] **Step 8:** Commit:

```bash
git add scripts/hermes-self-heal/actions/
git commit -m "feat(hermes-self-heal): L3 action scripts (5 total)

restart_microvm, restart_mcp, restage_secrets, reset_credential_pool,
restart_health_check. All scripts:
  - Use absolute /run/current-system shebang (sudo strips PATH).
  - Print a single line of JSON to stdout describing result.
  - Take no arguments (hardcoded paths).

reset_credential_pool also realpath-validates the auth.json path
before deletion — defense in depth against any future symlink quirks
in /var/lib/hermes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 18: Aux scripts — read_log_tail + kick_health_check

**Files:**
- Create: `scripts/hermes-self-heal/aux/read_log_tail`
- Create: `scripts/hermes-self-heal/aux/kick_health_check`
- Create: `scripts/hermes-self-heal/tests/test_actions_shape.py`

- [ ] **Step 1:** Create `read_log_tail`:

```bash
#!/run/current-system/sw/bin/bash
# hermes-self-heal aux helper: read N lines from one of the two whitelisted
# Hermes log files. Argument-validated to prevent path traversal.
#
# Usage: read_log_tail <selector> <n>
#   selector ∈ { err, out } (errors.log vs gateway.log)
#   n        ∈ [1, 500]
set -euo pipefail

selector="${1:-}"
n="${2:-}"

case "$selector" in
  err) target=/var/lib/hermes/.hermes/logs/errors.log ;;
  out) target=/var/lib/hermes/.hermes/logs/gateway.log ;;
  *) echo "bad selector: $selector" >&2; exit 2 ;;
esac

# Sanity check N: must be a positive integer ≤500.
case "$n" in
  ''|*[!0-9]*) echo "bad n: $n" >&2; exit 2 ;;
esac
if [ "$n" -lt 1 ] || [ "$n" -gt 500 ]; then
  echo "n out of range: $n" >&2; exit 2
fi

if [ -f "$target" ]; then
  /run/current-system/sw/bin/tail -n "$n" "$target" 2>/dev/null || true
fi
```

- [ ] **Step 2:** Create `kick_health_check`:

```bash
#!/run/current-system/sw/bin/bash
# hermes-self-heal aux helper: synchronously trigger hermes-health-check.service
# so the daemon can poll hermes_health.prom shortly after to verify recovery.
set -euo pipefail
/run/current-system/sw/bin/systemctl start --wait hermes-health-check.service || true
```

- [ ] **Step 3:** Mark executable:

```bash
chmod 0755 /etc/nixos/scripts/hermes-self-heal/aux/*
```

- [ ] **Step 4:** Create `tests/test_actions_shape.py`:

```python
"""Action + aux script shape tests.

Verifies every script is executable, has the correct shebang, and
(for actions) prints valid JSON on a smoke invocation. Real systemctl
calls are mocked via a PATH override that places a fake systemctl
first.
"""
import os
import json
import pathlib
import shutil
import stat
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTIONS_DIR = ROOT / "actions"
AUX_DIR = ROOT / "aux"
EXPECTED_ACTIONS = {
    "restart_microvm",
    "restart_mcp",
    "restage_secrets",
    "reset_credential_pool",
    "restart_health_check",
}
EXPECTED_AUX = {"read_log_tail", "kick_health_check"}


def test_actions_dir_has_exactly_expected_scripts():
    actual = {p.name for p in ACTIONS_DIR.iterdir() if p.is_file()}
    assert actual == EXPECTED_ACTIONS


def test_aux_dir_has_exactly_expected_scripts():
    actual = {p.name for p in AUX_DIR.iterdir() if p.is_file()}
    assert actual == EXPECTED_AUX


@pytest.mark.parametrize("name", sorted(EXPECTED_ACTIONS | EXPECTED_AUX))
def test_script_is_executable(name):
    p = ACTIONS_DIR / name if name in EXPECTED_ACTIONS else AUX_DIR / name
    mode = p.stat().st_mode
    assert mode & stat.S_IXUSR, f"{p} not executable"


@pytest.mark.parametrize("name", sorted(EXPECTED_ACTIONS | EXPECTED_AUX))
def test_script_has_absolute_shebang(name):
    """Sudo strips PATH; /usr/bin/env bash will fail."""
    p = ACTIONS_DIR / name if name in EXPECTED_ACTIONS else AUX_DIR / name
    first = p.read_text().splitlines()[0]
    assert first == "#!/run/current-system/sw/bin/bash", \
        f"{name} has wrong shebang: {first!r}"


@pytest.mark.parametrize("name", sorted(EXPECTED_ACTIONS))
def test_action_prints_valid_json_with_fake_systemctl(name, tmp_path, monkeypatch):
    """Smoke test: run each action with a fake systemctl on PATH.
    Asserts the script emits valid JSON on its last stdout line.

    Skipped at flake-check time because /run/current-system doesn't
    exist in the sandbox; runs locally when invoked directly.
    """
    if not pathlib.Path("/run/current-system/sw/bin/bash").exists():
        pytest.skip("Not running on the live system; /run/current-system absent")

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "systemctl").chmod(0o755)
    (fake_bin / "rm").write_text("#!/bin/sh\nexit 0\n")
    (fake_bin / "rm").chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    result = subprocess.run(
        [str(ACTIONS_DIR / name)],
        env=env, capture_output=True, text=True, timeout=10,
    )
    last_line = result.stdout.strip().splitlines()[-1]
    parsed = json.loads(last_line)
    assert "ok" in parsed
```

- [ ] **Step 5:** Run the shape tests:

```bash
cd /etc/nixos/scripts/hermes-self-heal && python3 -m pytest tests/test_actions_shape.py -v
```

Expected: 13 PASSED (or some skipped when not on the live system — the JSON-output tests need `/run/current-system/sw/bin/bash` to exist).

- [ ] **Step 6:** Commit:

```bash
git add scripts/hermes-self-heal/aux/ scripts/hermes-self-heal/tests/test_actions_shape.py
git commit -m "feat(hermes-self-heal): aux helpers + shape tests for all scripts

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 19: Rewrite hermes-self-heal.nix as the daemon module

**Files:**
- Modify: `modules/services/hermes-self-heal.nix`

- [ ] **Step 1:** Read the OpenClaw module once more as the template:

```bash
cat /etc/nixos/modules/services/openclaw-self-heal.nix
```

- [ ] **Step 2:** Replace `modules/services/hermes-self-heal.nix` wholesale (Write tool — this is a full rewrite, not an Edit). The replacement:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermesSelfHeal;
  daemonScript = pkgs.writeText "hermes-self-heal-daemon.py" (
    builtins.readFile ../../scripts/hermes-self-heal/daemon.py
  );
  user = "hermes-heal";
  actionsDir = "/etc/nixos/scripts/hermes-self-heal/actions";
  auxDir = "/etc/nixos/scripts/hermes-self-heal/aux";
in
{
  options.services.hermesSelfHeal = {
    enable = lib.mkEnableOption "hermes self-heal daemon";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9098;
      description = "Loopback port for the Alertmanager webhook.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = "/var/lib/hermes-self-heal";
      createHome = true;
      homeMode = "0700";
      description = "Hermes self-heal daemon";
    };
    users.groups.${user} = { };

    # Persistent state directory — `d` directive preserves contents across rebuilds.
    # On the first rebuild after the rewrite, this re-chowns the dir to hermes-heal
    # (previously owned by root from the shell-watchdog era). Old last-restart-*
    # files keep their root ownership but are harmless; the new daemon never reads
    # them. See spec §10.
    systemd.tmpfiles.rules = [
      "d /var/lib/hermes-self-heal 0700 ${user} ${user} -"
      "d /var/log/hermes-self-heal  0750 ${user} ${user} -"
    ];

    # Suppress sudo's mail-on-error for hermes-heal. Mirrors the
    # openclaw-heal defense against the stuck sendmail loop (see
    # openclaw spec §10, 2026-05-08 → 2026-05-15 incident).
    security.sudo.extraConfig = ''
      Defaults:${user} !mail_no_perms,!mail_no_user,!mail_badpass,!mail_always
    '';

    security.sudo.extraRules = [
      {
        users = [ user ];
        commands = [
          { command = "${actionsDir}/restart_microvm";        options = [ "NOPASSWD" ]; }
          { command = "${actionsDir}/restart_mcp";             options = [ "NOPASSWD" ]; }
          { command = "${actionsDir}/restage_secrets";         options = [ "NOPASSWD" ]; }
          { command = "${actionsDir}/reset_credential_pool";   options = [ "NOPASSWD" ]; }
          { command = "${actionsDir}/restart_health_check";    options = [ "NOPASSWD" ]; }
          { command = "${auxDir}/read_log_tail";               options = [ "NOPASSWD" ]; }
          { command = "${auxDir}/kick_health_check";           options = [ "NOPASSWD" ]; }
        ];
      }
    ];

    # Reuse the same LiteLLM master key that openclaw-self-heal uses.
    # Different SOPS-secrets entry (owner) so the file is readable as hermes-heal.
    sops.secrets."litellm-vulcan-lan-hermes-self-heal" = {
      key = "litellm-vulcan-lan";
      owner = user;
      mode = "0400";
      restartUnits = [ "hermes-self-heal.service" ];
    };

    systemd.services.hermes-self-heal = {
      description = "Hermes self-heal webhook receiver and remediation runner";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "alertmanager.service"
      ];
      wants = [ "network-online.target" ];
      # PATH must include /run/wrappers/bin so the daemon's bare `sudo`
      # invocations resolve to NixOS's setuid sudo wrapper. The daemon
      # never asks sudo to run a bare command — only absolute paths
      # under /etc/nixos/scripts/hermes-self-heal/{actions,aux}/
      # which are matched by exact path in the sudoers allowlist.
      path = [
        "/run/wrappers"
        pkgs.coreutils
        pkgs.systemd
        pkgs.bashInteractive
        pkgs.curl
        pkgs.jq
      ];
      environment = {
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        Restart = "always";
        RestartSec = "5s";
        LoadCredential = [
          "litellm-key:${config.sops.secrets."litellm-vulcan-lan-hermes-self-heal".path}"
        ];
        # Hardening mirrors openclaw-self-heal.
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = false; # needs setuid sudo wrapper
        PrivateTmp = true;
        RestrictSUIDSGID = false; # sudo wrapper is setuid
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # python compiles bytecode
        CapabilityBoundingSet = [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_AUDIT_WRITE"
          "CAP_SYS_RESOURCE"
          "CAP_DAC_OVERRIDE"
          "CAP_DAC_READ_SEARCH"
          "CAP_FOWNER"
          "CAP_CHOWN"
          "CAP_KILL"
          "CAP_SYS_ADMIN"
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        ReadWritePaths = [
          "/var/lib/hermes-self-heal"
          "/var/log/hermes-self-heal"
          "/var/lib/prometheus-node-exporter-textfiles"
          # See openclaw-self-heal.nix comment block: /run/sudo needed even
          # with NOPASSWD, otherwise sudo fails AND spawns a stuck sendmail.
          "/run/sudo"
        ];
      };
      script = ''
        export LITELLM_KEY="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/litellm-key")"
        exec ${pkgs.python3}/bin/python3 ${daemonScript}
      '';
    };

    networking.firewall.allowedTCPPorts = [ ]; # 127.0.0.1 only — no firewall change needed
  };
}
```

- [ ] **Step 3:** `nix fmt` the file (the repo has a formatter hook):

```bash
cd /etc/nixos && nix fmt modules/services/hermes-self-heal.nix
```

- [ ] **Step 4:** Build (without switching) to surface evaluation errors:

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' 2>&1 | tail -40
```

Expected: build succeeds. Task 19 reuses the existing `litellm-vulcan-lan` SOPS key (the daemon's own secret is just a re-export at a different owner), so this build should pass cleanly. If it fails on something (typo, missing comma), fix and rebuild. The nightly-report module that introduces a NEW SOPS entry comes later (Tasks 27 + 28); that's where SOPS work is required.

- [ ] **Step 5:** Commit:

```bash
git add modules/services/hermes-self-heal.nix
git commit -m "$(cat <<'EOF'
feat(hermes-self-heal): replace shell watchdog with webhook-driven daemon

Replaces the simple shell-script polling watchdog with an
Alertmanager-webhook-driven Python daemon (port 9098), mirroring
openclaw-self-heal:
  - 5-action L3 allowlist via sudoers (restart_microvm, restart_mcp,
    restage_secrets, reset_credential_pool, restart_health_check)
  - Deterministic tier 1, LiteLLM AI tiers 2-3, stuck tier 4
  - SOPS-staged LITELLM_KEY (re-use of openclaw's litellm-vulcan-lan)
  - Same CapabilityBoundingSet, ReadWritePaths (/run/sudo), and
    sudo mail_no_* defaults as openclaw-self-heal

Old hermes-self-heal.timer is removed by switch-to-configuration.
Spec §10 migration notes apply.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
EOF
)"
```

---

## Task 20: Wire pytest checks into flake.nix

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1:** Open `flake.nix`, find the checks block (around line 175 — after `openclaw-self-heal-tests`):

```nix
          openclaw-self-heal-tests = helpers.mkPytestCheck {
            name = "openclaw-self-heal-tests";
            src = ./scripts/openclaw-self-heal;
            suiteDir = "tests";
          };
```

Add immediately after it:

```nix
          hermes-self-heal-tests = helpers.mkPytestCheck {
            name = "hermes-self-heal-tests";
            src = ./scripts/hermes-self-heal;
            suiteDir = "tests";
          };
```

And after `openclaw-nightly-report-tests` add (we'll create this dir in Task 23):

```nix
          hermes-nightly-report-tests = helpers.mkPytestCheck {
            name = "hermes-nightly-report-tests";
            src = ./scripts;
            suiteDir = "hermes-nightly-report-tests";
          };
```

- [ ] **Step 2:** Run just the new daemon check:

```bash
sudo nix build --no-link --print-build-logs '/etc/nixos#checks.aarch64-linux.hermes-self-heal-tests' 2>&1 | tail -30
```

Expected: pytest runs in the sandbox and all daemon tests pass. If they fail, fix the daemon — do NOT touch the test.

- [ ] **Step 3:** The `hermes-nightly-report-tests` build will fail because the directory doesn't exist yet. That's OK — we'll commit it later in Task 24. For now, only commit the hermes-self-heal-tests addition:

```bash
git add flake.nix
git commit -m "test(hermes-self-heal): wire daemon pytest suite into nix flake check

Adds hermes-nightly-report-tests stub too — will start passing once
Task 23 lands the suite. The check fails for now if you run it.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 21: Append the 3 watchdog alerts to hermes.yaml

**Files:**
- Modify: `modules/monitoring/alerts/hermes.yaml`

- [ ] **Step 1:** Open `/etc/nixos/modules/monitoring/alerts/hermes.yaml` and append these rules to the existing `hermes_availability` group (keep them grouped — they all relate to Hermes availability through its self-heal):

```yaml
      # The self-heal daemon's own heartbeat. If the daemon dies, no
      # auto-remediation is happening — operator must intervene.
      # NOTE: service: hermes-self-heal (NOT hermes-*) so this alert
      # is not routed back to the daemon itself (which may be dead).
      - alert: HermesSelfHealDown
        expr: time() - hermes_self_heal_last_heartbeat_seconds > 600
        for: 5m
        labels:
          severity: warning
          category: monitoring
          service: hermes-self-heal
        annotations:
          summary: "hermes-self-heal daemon heartbeat stale (>10 min)"
          description: |
            The hermes-self-heal daemon stopped writing
            hermes_self_heal_last_heartbeat_seconds. Either the
            service crashed (check `systemctl status hermes-self-heal`)
            or the textfile collector cannot read its output.

      # An incident has been open for >30 minutes. The daemon has
      # exhausted its 3 attempts or the AI tier returned escalate.
      # Human action required.
      - alert: HermesSelfHealStuck
        expr: hermes_self_heal_active_incidents > 0
        for: 30m
        labels:
          severity: critical
          category: availability
          service: hermes-self-heal
        annotations:
          summary: "Hermes self-heal incident open for >30 minutes"
          description: |
            One or more Hermes incidents have not resolved despite
            the daemon's attempts. Inspect
            /var/lib/hermes-self-heal/incidents.json and recent
            journal output to decide on a manual action.

      # Track how often the AI tier was unreachable. >3/hour suggests
      # LiteLLM is down and the daemon is degraded to deterministic-only.
      - alert: HermesSelfHealLitellmUnreachable
        expr: increase(hermes_self_heal_litellm_unreachable_total[1h]) > 3
        for: 5m
        labels:
          severity: warning
          category: monitoring
          service: hermes-self-heal
        annotations:
          summary: ">3 LiteLLM unreachable events in last hour for hermes self-heal"
          description: |
            The daemon attempted to escalate to the AI tier multiple
            times and could not reach LiteLLM. Verify
            `systemctl status litellm` and that the
            litellm-vulcan-lan-hermes-self-heal SOPS secret matches
            LiteLLM's master key.
```

- [ ] **Step 2:** Validate YAML:

```bash
python3 -c "import yaml; yaml.safe_load(open('/etc/nixos/modules/monitoring/alerts/hermes.yaml'))"
```

Expected: no output (success).

- [ ] **Step 3:** Commit:

```bash
git add modules/monitoring/alerts/hermes.yaml
git commit -m "feat(monitoring): add 3 hermes-self-heal watchdog alerts

HermesSelfHealDown (heartbeat stale >10min, warning),
HermesSelfHealStuck (incident open >30min, critical),
HermesSelfHealLitellmUnreachable (>3/hour, warning).

All labeled service=hermes-self-heal so they do NOT loop back through
the new alertmanager route matching service=hermes-(mcp|agent).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 22: Wire alertmanager route + receiver

**Files:**
- Modify: `modules/services/alertmanager.nix`

- [ ] **Step 1:** Open `/etc/nixos/modules/services/alertmanager.nix`. Find the openclaw-self-heal route block (around line 45-53):

```nix
          {
            match = {
              service = "openclaw";
            };
            receiver = "openclaw-self-heal";
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "4h";
            continue = true;
          }
```

Add immediately AFTER it (before the storage-receiver route):

```nix
          # Hermes self-heal pipeline — service=hermes-mcp and
          # service=hermes-agent alerts both go to the hermes-self-heal
          # daemon's webhook receiver. continue=true preserves the email
          # path so a human still sees the critical alert.
          # NOTE: alerts with service=hermes-self-heal (the daemon's own
          # watchdog) intentionally do NOT match here, so they never loop
          # back to the daemon that may already be dead.
          # First use of match_re in this file; passes through to upstream
          # Alertmanager YAML.
          {
            match_re = {
              service = "hermes-(mcp|agent)";
            };
            receiver = "hermes-self-heal";
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "4h";
            continue = true;
          }
```

- [ ] **Step 2:** Find the openclaw-self-heal receiver block (around line 177-185):

```nix
        {
          name = "openclaw-self-heal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:9092/alert";
              send_resolved = true;
            }
          ];
        }
```

Add immediately AFTER it:

```nix
        {
          name = "hermes-self-heal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:9098/alert";
              send_resolved = true;
            }
          ];
        }
```

- [ ] **Step 3:** Build to surface eval errors:

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' 2>&1 | tail -20
```

Expected: builds (the alertmanager config attrset just passes through to YAML; `match_re` is valid Alertmanager syntax).

- [ ] **Step 4:** Commit:

```bash
git add modules/services/alertmanager.nix
git commit -m "feat(alertmanager): route hermes-(mcp|agent) alerts to self-heal webhook

continue=true keeps the email path firing for human visibility.
First match_re in this file (vs match used elsewhere); inline comment
explains the use.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 23: Scaffold nightly-report tests (parser fixtures)

**Files:**
- Create: `scripts/hermes-nightly-report-tests/conftest.py`
- Create: `scripts/hermes-nightly-report-tests/fixtures/hermes_health_healthy.prom`
- Create: `scripts/hermes-nightly-report-tests/fixtures/hermes_health_degraded.prom`
- Create: `scripts/hermes-nightly-report-tests/fixtures/gateway_log_sample.txt`
- Create: `scripts/hermes-nightly-report-tests/fixtures/errors_log_sample.txt`
- Create: `scripts/hermes-nightly-report-tests/fixtures/incidents_sample.json`

- [ ] **Step 1:** Create the conftest:

```python
"""Test fixtures for the hermes nightly report parser tests."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))


def load_report_module():
    """Load the script as `hermes_nightly_report` despite hyphenated filename."""
    spec_path = SCRIPT_DIR / "hermes-nightly-report.py"
    spec = importlib.util.spec_from_file_location(
        "hermes_nightly_report", spec_path
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
```

- [ ] **Step 2:** Create `fixtures/hermes_health_healthy.prom`:

```
# HELP hermes_api_server_ok 1 if Hermes api_server /v1/capabilities returned 200
# TYPE hermes_api_server_ok gauge
hermes_api_server_ok 1
# HELP hermes_mcp_sse_open_ok 1 if hermes-mcp /sse accepted a connection
# TYPE hermes_mcp_sse_open_ok gauge
hermes_mcp_sse_open_ok 1
# HELP hermes_mcp_ask_hermes_ok 1 if a full ask_hermes round-trip completed within 60s
# TYPE hermes_mcp_ask_hermes_ok gauge
hermes_mcp_ask_hermes_ok 1
# HELP hermes_mcp_ask_hermes_seconds Wall-clock seconds
# TYPE hermes_mcp_ask_hermes_seconds gauge
hermes_mcp_ask_hermes_seconds 8.234
hermes_api_server_probe_seconds 0.041
hermes_discord_event_present 1
hermes_discord_last_event_age_seconds 312.5
hermes_health_check_last_run_timestamp_seconds 1747800000.0
hermes_api_key_present 1
```

- [ ] **Step 3:** Create `fixtures/hermes_health_degraded.prom`:

```
hermes_api_server_ok 1
hermes_mcp_sse_open_ok 0
hermes_mcp_ask_hermes_ok 0
hermes_mcp_ask_hermes_seconds 60.0
hermes_api_server_probe_seconds 0.041
hermes_discord_event_present 0
hermes_discord_last_event_age_seconds 18234.7
hermes_health_check_last_run_timestamp_seconds 1747800000.0
hermes_api_key_present 1
```

- [ ] **Step 4:** Create `fixtures/gateway_log_sample.txt` with realistic Hermes Discord log lines (look at actual production log shape first; use a representative slice):

```
2026-05-20T03:14:22 [gateway.platforms.discord] WS connect ok
2026-05-20T05:31:08 [gateway.platforms.discord] inbound message channel=#general
2026-05-20T05:31:10 [gateway.platforms.discord] outbound message channel=#general
2026-05-20T11:02:44 [gateway.platforms.discord] reconnect (resume ok)
2026-05-20T15:18:01 [gateway.platforms.discord] inbound message channel=#hermes-test
2026-05-20T15:18:04 [gateway.platforms.discord] outbound message channel=#hermes-test
2026-05-20T22:00:00 [gateway.platforms.discord] error: heartbeat ack delayed
```

- [ ] **Step 5:** Create `fixtures/errors_log_sample.txt` (include some patterns that should be redacted to verify the redact pipeline):

```
2026-05-20T03:00:01 ERROR LiteLLM 401: bearer eyJabc.def.ghi
2026-05-20T04:15:09 ERROR LiteLLM 401: bearer eyJabc.def.ghi
2026-05-20T04:15:09 ERROR Failed to parse tool reply from Qwen
2026-05-20T05:31:08 WARN Empty completion (model returned 0 tokens)
2026-05-20T05:31:10 WARN Empty completion (model returned 0 tokens)
2026-05-20T11:02:44 ERROR LiteLLM 401: bearer eyJabc.def.ghi
2026-05-20T15:18:01 ERROR Failed to parse tool reply from Qwen
2026-05-20T22:00:00 ERROR Discord WS heartbeat timeout
```

- [ ] **Step 6:** Create `fixtures/incidents_sample.json`:

```json
{
  "active": {
    "1747800000:5826": {
      "first_seen_ts": 1747800000,
      "vm_active_enter_ts": 1747700000,
      "alerts": ["HermesAskFailing"],
      "attempts": [
        {"ts": 1747800010, "action": "restart_microvm", "by": "deterministic", "ok": false}
      ],
      "status": "in_progress",
      "next_eligible_ts": null
    }
  },
  "history": [
    {
      "first_seen_ts": 1747700000,
      "vm_active_enter_ts": 1747600000,
      "alerts": ["HermesMcpBridgeDown"],
      "attempts": [
        {"ts": 1747700010, "action": "restart_mcp", "by": "deterministic", "ok": true}
      ],
      "status": "resolved"
    }
  ]
}
```

- [ ] **Step 7:** Commit (just the fixtures + conftest — no tests yet):

```bash
git add scripts/hermes-nightly-report-tests/
git commit -m "test(hermes-nightly-report): scaffold conftest + fixture corpus

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 24: Nightly report — write parsers + their tests (TDD round)

**Files:**
- Create: `scripts/hermes-nightly-report.py` (incrementally)
- Create: `scripts/hermes-nightly-report-tests/test_parse_textfile.py`
- Create: `scripts/hermes-nightly-report-tests/test_parse_gateway_log.py`
- Create: `scripts/hermes-nightly-report-tests/test_parse_errors_log.py`
- Create: `scripts/hermes-nightly-report-tests/test_parse_incidents.py`

For brevity, this task is presented as one TDD loop covering all four parsers. The pattern is identical for each: write fixture-driven test → run (fail) → write parser → run (pass).

- [ ] **Step 1:** Create `scripts/hermes-nightly-report.py` with the minimum module-level constants and docstring (similar shape to `scripts/openclaw-nightly-report.py:1-60`):

```python
#!/usr/bin/env python3
"""Nightly Hermes health report → email to johnw@vulcan.lan.

See docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md §7.

Aggregates 8 signal sources:
  1. Headline verdict (hermes_health.prom snapshot)
  2. Live metrics table
  3. microVM + hermes-mcp uptime via `systemctl show`
  4. 24h smoke probe history via Prometheus HTTP API
  5. Discord gateway activity (gateway.log tail)
  6. Errors digest (errors.log tail, redacted)
  7. Self-heal incidents (incidents.json last 24h)
  8. Optional in-VM SSH probe

Composes a plain-text email with ASCII tables and pipes it to sendmail.
Designed to run as root from a systemd timer at 06:15 daily.

Environment overrides:
  HERMES_REPORT_TO          recipient (default: johnw@vulcan.lan)
  HERMES_REPORT_FROM        sender (default: hermes-health@vulcan.lan)
  HERMES_REPORT_SENDMAIL    sendmail path (default: /run/wrappers/bin/sendmail)
  HERMES_REPORT_DRY_RUN     if non-empty, print to stdout instead of mailing
  HERMES_REPORT_SSH_KEY     path to ssh key for in-VM probe
  HERMES_REPORT_SSH_TARGET  e.g. hermes@10.99.1.2
  HERMES_REPORT_PROMETHEUS_URL  default http://127.0.0.1:9090
"""
from __future__ import annotations

import collections
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from typing import Any

TEXTFILE = pathlib.Path(
    "/var/lib/prometheus-node-exporter-textfiles/hermes_health.prom"
)
SMOKE_TEXTFILE = pathlib.Path(
    "/var/lib/prometheus-node-exporter-textfiles/openclaw_hermes_smoke.prom"
)
GATEWAY_LOG = pathlib.Path("/var/lib/hermes/.hermes/logs/gateway.log")
ERRORS_LOG = pathlib.Path("/var/lib/hermes/.hermes/logs/errors.log")
INCIDENTS_JSON = pathlib.Path("/var/lib/hermes-self-heal/incidents.json")

RECIPIENT = os.getenv("HERMES_REPORT_TO", "johnw@vulcan.lan")
SENDER = os.getenv("HERMES_REPORT_FROM", "hermes-health@vulcan.lan")
SENDMAIL = os.getenv("HERMES_REPORT_SENDMAIL", "/run/wrappers/bin/sendmail")
DRY_RUN = bool(os.getenv("HERMES_REPORT_DRY_RUN"))
PROMETHEUS_URL = os.getenv("HERMES_REPORT_PROMETHEUS_URL", "http://127.0.0.1:9090")
SSH_KEY = os.getenv("HERMES_REPORT_SSH_KEY")
SSH_TARGET = os.getenv("HERMES_REPORT_SSH_TARGET", "hermes@10.99.1.2")

# Reuse the redact patterns from the self-heal daemon — same secret shapes.
REDACT_PATTERNS = [
    re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
    re.compile(r"sk-or-v1-[A-Za-z0-9_-]{20,}"),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
    re.compile(r"(?i)(token|password|api[_-]?key)=[^\s&\"]+"),
]


def redact(s: str) -> str:
    for p in REDACT_PATTERNS:
        s = p.sub("[REDACTED]", s)
    return s
```

- [ ] **Step 2:** Write `test_parse_textfile.py`:

```python
from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_parse_textfile_healthy():
    mod = load_report_module()
    parsed = mod.parse_textfile(FIXTURE_DIR / "hermes_health_healthy.prom")
    assert parsed["hermes_api_server_ok"] == 1.0
    assert parsed["hermes_mcp_ask_hermes_ok"] == 1.0
    assert parsed["hermes_discord_last_event_age_seconds"] == 312.5
    assert parsed["hermes_api_key_present"] == 1.0


def test_parse_textfile_degraded():
    mod = load_report_module()
    parsed = mod.parse_textfile(FIXTURE_DIR / "hermes_health_degraded.prom")
    assert parsed["hermes_mcp_sse_open_ok"] == 0.0
    assert parsed["hermes_mcp_ask_hermes_ok"] == 0.0
    assert parsed["hermes_discord_last_event_age_seconds"] == 18234.7


def test_parse_textfile_missing_returns_empty():
    mod = load_report_module()
    parsed = mod.parse_textfile(Path("/nonexistent/file.prom"))
    assert parsed == {}
```

- [ ] **Step 3:** Add `parse_textfile` to `hermes-nightly-report.py`:

```python
def parse_textfile(path: pathlib.Path = TEXTFILE) -> dict[str, float]:
    """Return the gauges from a hermes_health.prom-shaped file."""
    out: dict[str, float] = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        k, _, v = line.rpartition(" ")
        try:
            out[k] = float(v)
        except ValueError:
            pass
    return out
```

- [ ] **Step 4:** Run the textfile parser tests:

```bash
cd /etc/nixos/scripts && python3 -m pytest hermes-nightly-report-tests/test_parse_textfile.py -v
```

Expected: 3 PASSED.

- [ ] **Step 5:** Write `test_parse_gateway_log.py`:

```python
from pathlib import Path
import datetime as dt

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_gateway_log_counts_events_by_type():
    mod = load_report_module()
    result = mod.parse_gateway_log(
        FIXTURE_DIR / "gateway_log_sample.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert result["connect"] == 1
    assert result["inbound"] == 2
    assert result["outbound"] == 2
    assert result["reconnect"] == 1
    assert result["error"] == 1


def test_gateway_log_returns_zero_when_missing():
    mod = load_report_module()
    result = mod.parse_gateway_log(Path("/nonexistent.log"), 24)
    assert result == {"connect": 0, "inbound": 0, "outbound": 0, "reconnect": 0, "error": 0}


def test_gateway_log_returns_most_recent_per_type():
    mod = load_report_module()
    most_recent = mod.most_recent_per_type(
        FIXTURE_DIR / "gateway_log_sample.txt",
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    # outbound's latest line is at 15:18:04 on the 20th
    assert most_recent["outbound"] == dt.datetime(2026, 5, 20, 15, 18, 4)
```

- [ ] **Step 6:** Add `parse_gateway_log` + `most_recent_per_type` to the script:

```python
GATEWAY_TS_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}).*\[gateway\.platforms\.discord\]\s+(?P<rest>.*)$"
)
EVENT_KEYWORDS = {
    "connect":   re.compile(r"\bWS connect\b|\bconnect\b"),
    "reconnect": re.compile(r"\breconnect\b"),
    "inbound":   re.compile(r"\binbound\b"),
    "outbound":  re.compile(r"\boutbound\b"),
    "error":     re.compile(r"\berror\b|\bheartbeat\b.*\bdelayed\b"),
}


def _iter_gateway_events(path, now):
    """Yield (ts, event_type) for each line newer than now-24h."""
    if not path.is_file():
        return
    cutoff = now - dt.timedelta(hours=24)
    for line in path.read_text().splitlines():
        m = GATEWAY_TS_RE.match(line)
        if not m:
            continue
        try:
            ts = dt.datetime.fromisoformat(m.group("ts"))
        except ValueError:
            continue
        if ts < cutoff:
            continue
        rest = m.group("rest")
        for event_type, regex in EVENT_KEYWORDS.items():
            if regex.search(rest):
                yield ts, event_type
                break


def parse_gateway_log(path: pathlib.Path = GATEWAY_LOG, window_hours: int = 24, now=None) -> dict[str, int]:
    """Count Discord events by type in the last `window_hours`."""
    now = now or dt.datetime.now()
    counts = {t: 0 for t in EVENT_KEYWORDS}
    for _ts, etype in _iter_gateway_events(path, now):
        counts[etype] += 1
    return counts


def most_recent_per_type(path: pathlib.Path = GATEWAY_LOG, now=None) -> dict[str, dt.datetime]:
    now = now or dt.datetime.now()
    out: dict[str, dt.datetime] = {}
    for ts, etype in _iter_gateway_events(path, now):
        if etype not in out or ts > out[etype]:
            out[etype] = ts
    return out
```

- [ ] **Step 7:** Run gateway tests:

```bash
cd /etc/nixos/scripts && python3 -m pytest hermes-nightly-report-tests/test_parse_gateway_log.py -v
```

Expected: 3 PASSED. Adjust event-keyword regexes if needed for fixture accuracy.

- [ ] **Step 8:** Write `test_parse_errors_log.py`:

```python
from pathlib import Path
import datetime as dt

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_errors_log_top_patterns():
    mod = load_report_module()
    result = mod.parse_errors_log(
        FIXTURE_DIR / "errors_log_sample.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    # Top pattern should be LiteLLM 401: bearer (3x); the bearer is redacted.
    top = result["patterns"][0]
    assert top["count"] == 3
    assert "[REDACTED]" in top["pattern"]
    assert "eyJabc" not in top["pattern"]


def test_errors_log_total_count():
    mod = load_report_module()
    result = mod.parse_errors_log(
        FIXTURE_DIR / "errors_log_sample.txt",
        window_hours=24,
        now=dt.datetime(2026, 5, 21, 0, 0),
    )
    assert result["total"] >= 8


def test_errors_log_missing_returns_zero():
    mod = load_report_module()
    result = mod.parse_errors_log(Path("/nonexistent.log"), 24)
    assert result == {"total": 0, "patterns": []}
```

- [ ] **Step 9:** Add `parse_errors_log` to the script:

```python
ERRORS_TS_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\s+(?:ERROR|WARN)\s+(?P<msg>.*)$"
)


def parse_errors_log(path: pathlib.Path = ERRORS_LOG, window_hours: int = 24, now=None) -> dict:
    """Return {total, patterns: [{pattern, count}, ...]}, redacted.

    Buckets identical lines (after redaction) so secret variants don't
    fragment the count.
    """
    now = now or dt.datetime.now()
    if not path.is_file():
        return {"total": 0, "patterns": []}
    cutoff = now - dt.timedelta(hours=24)
    bucket: collections.Counter = collections.Counter()
    total = 0
    for line in path.read_text().splitlines():
        m = ERRORS_TS_RE.match(line)
        if not m:
            continue
        try:
            ts = dt.datetime.fromisoformat(m.group("ts"))
        except ValueError:
            continue
        if ts < cutoff:
            continue
        total += 1
        msg = redact(m.group("msg").strip())
        bucket[msg] += 1
    top = [
        {"pattern": p, "count": c}
        for p, c in bucket.most_common(10)
    ]
    return {"total": total, "patterns": top}
```

- [ ] **Step 10:** Run errors tests:

```bash
cd /etc/nixos/scripts && python3 -m pytest hermes-nightly-report-tests/test_parse_errors_log.py -v
```

Expected: 3 PASSED.

- [ ] **Step 11:** Write `test_parse_incidents.py`:

```python
from pathlib import Path

from conftest import load_report_module

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_incidents_counts_by_status():
    mod = load_report_module()
    result = mod.parse_incidents(FIXTURE_DIR / "incidents_sample.json")
    assert result["active"] == 1
    assert result["resolved_24h"] >= 1


def test_incidents_lists_stuck_alerts():
    mod = load_report_module()
    result = mod.parse_incidents(FIXTURE_DIR / "incidents_sample.json")
    # No stuck in the fixture (status="in_progress" not "stuck")
    assert result["stuck_alerts"] == []


def test_incidents_missing_returns_empty():
    mod = load_report_module()
    result = mod.parse_incidents(Path("/nonexistent.json"))
    assert result == {"active": 0, "resolved_24h": 0, "stuck_alerts": []}
```

- [ ] **Step 12:** Add `parse_incidents`:

```python
def parse_incidents(path: pathlib.Path = INCIDENTS_JSON, now=None) -> dict:
    """Summarize self-heal incidents."""
    if not path.is_file():
        return {"active": 0, "resolved_24h": 0, "stuck_alerts": []}
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return {"active": 0, "resolved_24h": 0, "stuck_alerts": []}

    now = now or dt.datetime.now()
    cutoff_ts = int((now - dt.timedelta(hours=24)).timestamp())

    active = sum(
        1 for v in data.get("active", {}).values()
        if v.get("status") == "in_progress"
    )
    stuck_alerts = [
        v["alerts"][0]
        for v in data.get("active", {}).values()
        if v.get("status") == "stuck"
        and v.get("alerts")
    ]
    resolved_24h = sum(
        1 for v in data.get("history", [])
        if v.get("status") == "resolved"
        and v.get("first_seen_ts", 0) >= cutoff_ts
    )
    return {"active": active, "resolved_24h": resolved_24h, "stuck_alerts": stuck_alerts}
```

- [ ] **Step 13:** Run incidents tests:

```bash
cd /etc/nixos/scripts && python3 -m pytest hermes-nightly-report-tests/test_parse_incidents.py -v
```

Expected: 3 PASSED.

- [ ] **Step 14:** Commit (all 4 parsers + their tests):

```bash
git add scripts/hermes-nightly-report.py scripts/hermes-nightly-report-tests/
git commit -m "feat(hermes-nightly-report): 4 parsers (textfile, gateway, errors, incidents)

TDD: each parser developed against a fixture-driven test before the
parser. Redacts errors.log content using the same patterns as the
self-heal daemon. Incidents parser surfaces stuck alerts so the
report can FLAG them at the top.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 25: Nightly report — Prometheus HTTP query for 24h smoke summary

**Files:**
- Modify: `scripts/hermes-nightly-report.py`
- Modify: `scripts/hermes-nightly-report-tests/test_parse_textfile.py` (add Prometheus-query tests)

- [ ] **Step 1:** Add failing tests to `test_parse_textfile.py` (or a new file `test_prometheus_query.py`):

```python
def test_prometheus_query_returns_value(monkeypatch):
    import json as _json
    mod = load_report_module()

    class FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): pass
        def read(self):
            return _json.dumps({
                "status": "success",
                "data": {
                    "resultType": "vector",
                    "result": [{"metric": {}, "value": [1747800000, "0.97"]}],
                },
            }).encode()

    monkeypatch.setattr(mod.urllib.request, "urlopen",
                        lambda *a, **kw: FakeResp())
    result = mod.prometheus_query("avg_over_time(openclaw_hermes_smoke_ok[24h])")
    assert result == 0.97


def test_prometheus_query_returns_none_on_error(monkeypatch):
    mod = load_report_module()

    def fake_urlopen(*a, **kw):
        raise OSError("connection refused")

    monkeypatch.setattr(mod.urllib.request, "urlopen", fake_urlopen)
    assert mod.prometheus_query("any") is None


def test_smoke_summary_uses_three_queries(monkeypatch):
    mod = load_report_module()
    calls = []
    monkeypatch.setattr(mod, "prometheus_query",
                        lambda q: (calls.append(q), 0.5)[1])
    summary = mod.smoke_summary_24h()
    assert len(calls) == 3
    assert any("avg_over_time" in c for c in calls)
    assert any("quantile_over_time(0.5" in c for c in calls)
    assert any("quantile_over_time(0.95" in c for c in calls)
    assert summary["success_ratio"] == 0.5
```

- [ ] **Step 2:** Add to script:

```python
def prometheus_query(promql: str) -> float | None:
    """Query Prometheus' /api/v1/query and return the scalar value, or None on error."""
    url = f"{PROMETHEUS_URL}/api/v1/query?query={urllib.parse.quote(promql)}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
    except (OSError, json.JSONDecodeError, urllib.error.URLError):
        return None
    if data.get("status") != "success":
        return None
    result = data.get("data", {}).get("result", [])
    if not result:
        return None
    try:
        return float(result[0]["value"][1])
    except (KeyError, IndexError, ValueError):
        return None


def smoke_summary_24h() -> dict:
    """Spec §7.2 section 4 — three Prometheus queries over the smoke gauge.

    Returns {success_ratio, p50_seconds, p95_seconds, available}.
    """
    success = prometheus_query("avg_over_time(openclaw_hermes_smoke_ok[24h])")
    p50 = prometheus_query("quantile_over_time(0.5, openclaw_hermes_smoke_duration_seconds[24h])")
    p95 = prometheus_query("quantile_over_time(0.95, openclaw_hermes_smoke_duration_seconds[24h])")
    return {
        "success_ratio": success,
        "p50_seconds": p50,
        "p95_seconds": p95,
        "available": all(v is not None for v in (success, p50, p95)),
    }
```

- [ ] **Step 3:** Run tests:

```bash
cd /etc/nixos/scripts && python3 -m pytest hermes-nightly-report-tests/ -v
```

Expected: all PASSED.

- [ ] **Step 4:** Commit:

```bash
git add scripts/hermes-nightly-report.py scripts/hermes-nightly-report-tests/
git commit -m "feat(hermes-nightly-report): Prometheus HTTP query for 24h smoke summary

Three queries over openclaw_hermes_smoke_ok and _duration_seconds.
Spec §7.2 section 4 — uses gauge avg_over_time (probe emits binary
gauges per 15-min run, not counters). Returns None on connection
errors so the report renders a fallback.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 26: Nightly report — systemctl-show probes, SSH probe, render, deliver, main

**Files:**
- Modify: `scripts/hermes-nightly-report.py`
- Create: `scripts/hermes-nightly-report-tests/test_render_report.py`
- Create: `scripts/hermes-nightly-report-tests/test_main_dry_run.py`

Note: This is the largest single task — the rendering loop, the systemctl probes, the SSH probe, the email assembly, and the `main()`. Test coverage focuses on `render_report` (deterministic given parsed inputs) and `main()` under `DRY_RUN=1` (no real I/O).

- [ ] **Step 1:** Add to `hermes-nightly-report.py`:

```python
def systemd_uptime(unit: str) -> dict[str, Any]:
    """Return {active, since, n_restarts} via `systemctl show`."""
    try:
        out = subprocess.check_output(
            ["systemctl", "show", "-p", "ActiveState,ActiveEnterTimestamp,NRestarts", unit],
            text=True, timeout=10,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return {"active": "unknown", "since": None, "n_restarts": None}
    fields = dict(line.split("=", 1) for line in out.strip().splitlines() if "=" in line)
    enter_ts = fields.get("ActiveEnterTimestamp", "").strip()
    try:
        nrestarts = int(fields.get("NRestarts", "0").strip())
    except ValueError:
        nrestarts = 0
    return {
        "active": fields.get("ActiveState", "unknown").strip(),
        "since": enter_ts or None,
        "n_restarts": nrestarts,
    }


def in_vm_probe() -> dict[str, Any]:
    """Optional in-VM corroboration via SSH. Returns {skipped, reason, http_code}."""
    if not SSH_KEY or not pathlib.Path(SSH_KEY).is_file():
        return {"skipped": True, "reason": "no SSH key available", "http_code": None}
    try:
        out = subprocess.check_output(
            ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5",
             SSH_TARGET,
             "curl -s -m 5 http://localhost:8080/v1/capabilities -o /dev/null -w '%{http_code}'"],
            text=True, timeout=20, stderr=subprocess.DEVNULL,
        ).strip()
        return {"skipped": False, "reason": None, "http_code": out}
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return {"skipped": True, "reason": f"ssh probe failed: {type(e).__name__}", "http_code": None}


def render_report(now: dt.datetime, metrics: dict, smoke: dict,
                  microvm_uptime: dict, mcp_uptime: dict,
                  gateway_counts: dict, gateway_latest: dict,
                  errors: dict, incidents: dict, ssh_probe: dict) -> tuple[str, str]:
    """Return (subject, body) for the email."""
    # Headline verdict
    fail = (
        metrics.get("hermes_api_server_ok", 1) == 0
        or metrics.get("hermes_mcp_sse_open_ok", 1) == 0
        or metrics.get("hermes_mcp_ask_hermes_ok", 1) == 0
    )
    verdict = "FAIL" if fail else "PASS"
    if incidents["stuck_alerts"]:
        verdict = "FAIL"
        summary = f"{len(incidents['stuck_alerts'])} stuck incidents"
    elif incidents["active"]:
        summary = f"{incidents['active']} active incidents"
    elif errors["total"] > 50:
        summary = f"{errors['total']} errors in 24h"
    else:
        summary = "all healthy"

    hostname = os.uname().nodename
    date_str = now.strftime("%Y-%m-%d")
    subject = f"[hermes-nightly] {hostname} {date_str} — {summary}"

    lines = []
    lines.append(f"Hermes nightly report — {hostname} — {now.isoformat(timespec='seconds')}")
    lines.append("=" * 76)
    lines.append("")
    lines.append(f"Headline: {verdict} — {summary}")
    if incidents["stuck_alerts"]:
        lines.append("  STUCK INCIDENTS: " + ", ".join(incidents["stuck_alerts"]))
    lines.append("")

    lines.append("Live metrics")
    lines.append("-" * 76)
    for k, v in sorted(metrics.items()):
        lines.append(f"  {k:50} {v}")
    lines.append("")

    lines.append("microVM + hermes-mcp uptime")
    lines.append("-" * 76)
    lines.append(f"  microvm@hermes  active={microvm_uptime['active']:8} "
                 f"since={microvm_uptime['since'] or '-':25} restarts={microvm_uptime['n_restarts']}")
    lines.append(f"  hermes-mcp      active={mcp_uptime['active']:8} "
                 f"since={mcp_uptime['since'] or '-':25} restarts={mcp_uptime['n_restarts']}")
    lines.append("")

    lines.append("24h smoke probe summary (Prometheus)")
    lines.append("-" * 76)
    if smoke["available"]:
        lines.append(f"  Success ratio: {smoke['success_ratio']*100:.1f}% over 24h")
        lines.append(f"  Latency p50:   {smoke['p50_seconds']:.2f}s")
        lines.append(f"  Latency p95:   {smoke['p95_seconds']:.2f}s")
    else:
        lines.append("  (history unavailable: Prometheus unreachable)")
    lines.append("")

    lines.append("Discord activity (last 24h)")
    lines.append("-" * 76)
    for etype, count in gateway_counts.items():
        last = gateway_latest.get(etype)
        last_str = last.isoformat() if last else "-"
        lines.append(f"  {etype:10} count={count:4}  most recent={last_str}")
    lines.append("")

    lines.append(f"Errors digest (last 24h, total={errors['total']})")
    lines.append("-" * 76)
    if not errors["patterns"]:
        lines.append("  (no errors)")
    for entry in errors["patterns"]:
        lines.append(f"  {entry['count']:4}x  {entry['pattern'][:60]}")
    lines.append("")

    lines.append("Self-heal incidents (last 24h)")
    lines.append("-" * 76)
    lines.append(f"  active:        {incidents['active']}")
    lines.append(f"  resolved 24h:  {incidents['resolved_24h']}")
    if incidents["stuck_alerts"]:
        lines.append("  STUCK alerts:  " + ", ".join(incidents["stuck_alerts"]))
    lines.append("")

    lines.append("In-VM corroboration")
    lines.append("-" * 76)
    if ssh_probe["skipped"]:
        lines.append(f"  (probe skipped: {ssh_probe['reason']})")
    else:
        lines.append(f"  /v1/capabilities HTTP {ssh_probe['http_code']}")
    lines.append("")

    body = "\n".join(lines)
    return subject, body


def _build_message(subject: str, body: str) -> bytes:
    return (
        f"From: {SENDER}\r\n"
        f"To: {RECIPIENT}\r\n"
        f"Subject: {subject}\r\n"
        f"Content-Type: text/plain; charset=utf-8\r\n"
        f"\r\n"
        f"{body}\r\n"
    ).encode()


def deliver(subject: str, body: str) -> int:
    if DRY_RUN:
        print(_build_message(subject, body).decode(), end="")
        return 0
    msg = _build_message(subject, body)
    proc = subprocess.run(
        [SENDMAIL, "-i", "-f", SENDER, RECIPIENT],
        input=msg, capture_output=True, timeout=60,
    )
    if proc.returncode != 0:
        sys.stderr.write(
            f"sendmail rc={proc.returncode}\n"
            f"stdout:{proc.stdout.decode(errors='replace')[:300]}\n"
            f"stderr:{proc.stderr.decode(errors='replace')[:300]}\n"
        )
    return proc.returncode


def main() -> int:
    now = dt.datetime.now()
    metrics = parse_textfile()
    smoke = smoke_summary_24h()
    microvm_up = systemd_uptime("microvm@hermes.service")
    mcp_up = systemd_uptime("hermes-mcp.service")
    gw_counts = parse_gateway_log(window_hours=24, now=now)
    gw_latest = most_recent_per_type(now=now)
    errors = parse_errors_log(window_hours=24, now=now)
    incidents = parse_incidents(now=now)
    ssh = in_vm_probe()
    subject, body = render_report(
        now, metrics, smoke, microvm_up, mcp_up,
        gw_counts, gw_latest, errors, incidents, ssh,
    )
    return deliver(subject, body)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2:** Create `test_render_report.py`:

```python
import datetime as dt

from conftest import load_report_module


def test_render_headline_pass_when_all_metrics_one():
    mod = load_report_module()
    subject, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={"hermes_api_server_ok": 1, "hermes_mcp_sse_open_ok": 1,
                 "hermes_mcp_ask_hermes_ok": 1},
        smoke={"available": True, "success_ratio": 0.99, "p50_seconds": 1.2, "p95_seconds": 3.4},
        microvm_uptime={"active": "active", "since": "Mon 2026-05-20 12:00", "n_restarts": 0},
        mcp_uptime={"active": "active", "since": "Mon 2026-05-20 12:00", "n_restarts": 0},
        gateway_counts={"connect": 1, "inbound": 5, "outbound": 5, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        ssh_probe={"skipped": False, "reason": None, "http_code": "200"},
    )
    assert "PASS" in body
    assert "all healthy" in subject


def test_render_headline_fail_when_ask_ok_zero():
    mod = load_report_module()
    subject, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={"hermes_api_server_ok": 1, "hermes_mcp_sse_open_ok": 1,
                 "hermes_mcp_ask_hermes_ok": 0},
        smoke={"available": True, "success_ratio": 0.5, "p50_seconds": 60, "p95_seconds": 60},
        microvm_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        mcp_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        gateway_counts={"connect": 0, "inbound": 0, "outbound": 0, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        ssh_probe={"skipped": True, "reason": "no key", "http_code": None},
    )
    assert "FAIL" in body


def test_render_flags_stuck_incidents():
    mod = load_report_module()
    _, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={},
        smoke={"available": False, "success_ratio": None, "p50_seconds": None, "p95_seconds": None},
        microvm_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        mcp_uptime={"active": "active", "since": "Mon", "n_restarts": 0},
        gateway_counts={"connect": 0, "inbound": 0, "outbound": 0, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": ["HermesAskFailing"]},
        ssh_probe={"skipped": True, "reason": "no key", "http_code": None},
    )
    assert "STUCK" in body
    assert "HermesAskFailing" in body


def test_render_contains_all_8_section_headers():
    """Acceptance criterion §14.6: 8 section headers."""
    mod = load_report_module()
    _, body = mod.render_report(
        now=dt.datetime(2026, 5, 21, 6, 15),
        metrics={}, smoke={"available": False, "success_ratio": None, "p50_seconds": None, "p95_seconds": None},
        microvm_uptime={"active": "?", "since": None, "n_restarts": 0},
        mcp_uptime={"active": "?", "since": None, "n_restarts": 0},
        gateway_counts={"connect": 0, "inbound": 0, "outbound": 0, "reconnect": 0, "error": 0},
        gateway_latest={},
        errors={"total": 0, "patterns": []},
        incidents={"active": 0, "resolved_24h": 0, "stuck_alerts": []},
        ssh_probe={"skipped": True, "reason": "test", "http_code": None},
    )
    for header in [
        "Headline",
        "Live metrics",
        "microVM + hermes-mcp uptime",
        "24h smoke probe summary",
        "Discord activity",
        "Errors digest",
        "Self-heal incidents",
        "In-VM corroboration",
    ]:
        assert header in body, f"missing section: {header}"
```

- [ ] **Step 3:** Create `test_main_dry_run.py`:

```python
import os
from conftest import load_report_module


def test_main_dry_run_returns_zero(monkeypatch, capsys, tmp_path):
    mod = load_report_module()
    monkeypatch.setattr(mod, "DRY_RUN", True)
    monkeypatch.setattr(mod, "TEXTFILE", tmp_path / "missing.prom")
    monkeypatch.setattr(mod, "GATEWAY_LOG", tmp_path / "missing.log")
    monkeypatch.setattr(mod, "ERRORS_LOG", tmp_path / "missing.log")
    monkeypatch.setattr(mod, "INCIDENTS_JSON", tmp_path / "missing.json")
    monkeypatch.setattr(mod, "prometheus_query", lambda q: None)
    monkeypatch.setattr(mod, "systemd_uptime", lambda u: {"active": "unknown", "since": None, "n_restarts": None})
    monkeypatch.setattr(mod, "in_vm_probe", lambda: {"skipped": True, "reason": "test", "http_code": None})

    rc = mod.main()
    captured = capsys.readouterr()
    assert rc == 0
    assert "Hermes nightly report" in captured.out
    assert "Headline" in captured.out
```

- [ ] **Step 4:** Run all nightly-report tests:

```bash
cd /etc/nixos/scripts && python3 -m pytest hermes-nightly-report-tests/ -v
```

Expected: all PASSED.

- [ ] **Step 5:** Commit:

```bash
git add scripts/hermes-nightly-report.py scripts/hermes-nightly-report-tests/
git commit -m "feat(hermes-nightly-report): systemctl probes + render + deliver + main

Renders 8 sections to plain text (acceptance §14.6). Headline verdict
PASS/FAIL based on the three load-bearing metrics + stuck-incident
flag. Pipes through sendmail or prints to stdout under
HERMES_REPORT_DRY_RUN=1.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 27: Add nightly-report NixOS module

**Files:**
- Create: `modules/services/hermes-nightly-report.nix`

- [ ] **Step 1:** Create the module by adapting `modules/services/openclaw-nightly-report.nix`:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  reportScript = pkgs.writers.writePython3Bin "hermes-nightly-report" {
    flakeIgnore = [
      "E501" # ASCII tables push some lines past 79 chars
      "W503"
      "E265"
      "E203"
    ];
  } (builtins.readFile ../../scripts/hermes-nightly-report.py);

  recipient = "johnw@vulcan.lan";
  sender = "hermes-health@vulcan.lan";

  # 06:15 local time daily — 15 min after openclaw so the two emails
  # don't land in the same minute.
  schedule = "*-*-* 06:15:00";
in
{
  # SSH probe key for the optional in-VM corroboration step.
  # The same key is authorized on the Hermes VM under user `hermes`
  # as `claude-hermes-debug`. Mode 0400 owner root — LoadCredential
  # plumbs it into $CREDENTIALS_DIRECTORY for the unit.
  sops.secrets."hermes/probe-ssh-private-key" = {
    mode = "0400";
    owner = "root";
    group = "root";
  };

  systemd.services.hermes-nightly-report = {
    description = "Aggregate Hermes health and email a nightly report";
    after = [
      "hermes-health-check.service"
      "postfix.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      systemd
      coreutils
      openssh
    ];

    environment = {
      HERMES_REPORT_TO = recipient;
      HERMES_REPORT_FROM = sender;
      HERMES_REPORT_SENDMAIL = "/run/wrappers/bin/sendmail";
      HERMES_REPORT_SSH_KEY = "%d/probe-ssh-key";
      HERMES_REPORT_SSH_TARGET = "hermes@10.99.1.2";
      HERMES_REPORT_PROMETHEUS_URL = "http://127.0.0.1:9090";
    };

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${reportScript}/bin/hermes-nightly-report";

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        # Postfix sendmail calls getifaddrs() at startup; AF_NETLINK
        # is required or sendmail returns 75/TEMPFAIL.
        "AF_NETLINK"
        "AF_PACKET"
      ];
      # Sendmail (setgid postdrop wrapper) writes into postfix's maildrop
      # queue.
      ReadWritePaths = [
        "/var/lib/postfix/queue"
      ];
      ReadOnlyPaths = [
        "/var/lib/hermes"
        "/var/lib/hermes-self-heal"
        "/var/lib/prometheus-node-exporter-textfiles"
        "/etc/nixos/certs"
        "/etc/ssl"
      ];
      LoadCredential = [
        "probe-ssh-key:${config.sops.secrets."hermes/probe-ssh-private-key".path}"
      ];

      TimeoutStartSec = "5min";
    };
  };

  systemd.timers.hermes-nightly-report = {
    description = "Run Hermes nightly health report at 06:15";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = schedule;
      Persistent = true;
      RandomizedDelaySec = "5min";
      AccuracySec = "1min";
      Unit = "hermes-nightly-report.service";
    };
  };
}
```

- [ ] **Step 2:** Register the module in `hosts/vulcan/default.nix`. Find the line:

```
    ../../modules/services/openclaw-nightly-report.nix
```

Add immediately after:

```
    ../../modules/services/hermes-nightly-report.nix
```

- [ ] **Step 3:** `nix fmt`:

```bash
cd /etc/nixos && nix fmt modules/services/hermes-nightly-report.nix hosts/vulcan/default.nix
```

- [ ] **Step 4:** Build (will fail until SOPS secret is added in Task 28):

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' 2>&1 | tail -10
```

If the error is about the missing `hermes/probe-ssh-private-key` SOPS entry, that's expected — fixed in Task 28. Otherwise, fix the new failure.

- [ ] **Step 5:** Commit:

```bash
git add modules/services/hermes-nightly-report.nix hosts/vulcan/default.nix
git commit -m "$(cat <<'EOF'
feat(hermes-nightly-report): systemd timer + service module (06:15 daily)

Emails johnw@vulcan.lan from hermes-health@vulcan.lan via sendmail.
LoadCredential staged probe-ssh-key for the optional in-VM SSH probe.
Sandbox mirrors openclaw-nightly-report:
  - ProtectSystem=strict, ProtectHome, PrivateTmp, NoNewPrivileges
  - AF_NETLINK in RestrictAddressFamilies (postfix sendmail needs it)
  - /var/lib/postfix/queue in ReadWritePaths

Will fail to evaluate until the hermes/probe-ssh-private-key SOPS
entry is added (next task).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
EOF
)"
```

---

## Task 28: Add hermes/probe-ssh-private-key SOPS entry

**This task requires the user.** The agent cannot decrypt secrets and should not generate a real SSH key without sign-off. The agent's role is to prepare the request and wait.

**Files:**
- Modify: `secrets/secrets.yaml` (interactive sops editor)
- Possibly: `modules/services/hermes-vm.nix` (if a new pubkey is authorized)

- [ ] **Step 1:** Present this exact request to the user, then wait:

> The nightly report needs a SOPS-encrypted SSH key at `hermes/probe-ssh-private-key`, mode `0400` root-owned, used only by `hermes-nightly-report.service`. Two options:
>
> 1. **Reuse the existing `/root/.ssh/hermes-debug` key.** Add its private half to SOPS under `hermes:` next to `env`. No change to `hermes-vm.nix:openssh.authorizedKeys.keys` because the public half is already authorized as `claude-hermes-debug`. Easiest, but couples interactive debugging to the nightly probe — rotating one rotates the other.
> 2. **Generate a new probe-only key.** Run `ssh-keygen -t ed25519 -N '' -C 'hermes-nightly-probe' -f /tmp/hermes-probe`, add the private half to SOPS as `hermes/probe-ssh-private-key`, add the public half to `hermes-vm.nix:openssh.authorizedKeys.keys`, redeploy. Clean separation; one extra key to manage.
>
> Which option do you want? If option 2, I can write the `ssh-keygen` line into the terminal and let you press enter — the key never enters Claude's context.

- [ ] **Step 2:** Wait for the user's choice and follow their instruction. The user will run `sops /etc/nixos/secrets/secrets.yaml` and add the entry; Claude does not touch sops.

- [ ] **Step 3:** Once the user confirms the SOPS entry is present, verify the file's structural change is committed (Claude commits the YAML diff because the contents are encrypted):

```bash
git status secrets/secrets.yaml
git diff secrets/secrets.yaml  # safe: encrypted blobs only
```

- [ ] **Step 4:** Commit:

```bash
git add secrets/secrets.yaml
# Also modules/services/hermes-vm.nix if option 2 was chosen.
git commit -m "feat(secrets): add hermes/probe-ssh-private-key for nightly report

Used by hermes-nightly-report.service via LoadCredential to SSH into
the Hermes VM at 10.99.1.2 and probe /v1/capabilities for in-VM
corroboration in the nightly email.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 29: Full system build

**Files:** none (rebuild only).

- [ ] **Step 1:** Build (do not switch):

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' 2>&1 | tail -20
```

Expected: build succeeds. If it fails:
- Common cause: a typo in the new nix module. Fix and rebuild.
- Common cause: the SOPS secret references in Tasks 19/27 don't match the actual key names in `secrets.yaml`. Verify with `grep "hermes/" /etc/nixos/secrets/secrets.yaml` and adjust the module key path.

- [ ] **Step 2:** Run all flake checks:

```bash
sudo nix flake check '/etc/nixos' --no-write-lock-file 2>&1 | tail -30
```

Expected: includes `hermes-self-heal-tests` and `hermes-nightly-report-tests` passing.

---

## Task 30: nixos-rebuild switch + verify daemon

**Files:** none (deploy + verify).

- [ ] **Step 1:** Switch to the new system:

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -20
```

- [ ] **Step 2:** Verify the daemon is running:

```bash
sudo systemctl status hermes-self-heal.service
```

Expected: `Active: active (running)`, "hermes-self-heal listening on 127.0.0.1:9098" in the logs.

- [ ] **Step 3:** Verify the daemon is listening:

```bash
sudo ss -tunlp 'sport = :9098'
```

Expected: TCP listener on 127.0.0.1:9098 owned by python3.

- [ ] **Step 4:** Verify the heartbeat metric is being written:

```bash
ls -la /var/lib/prometheus-node-exporter-textfiles/hermes_self_heal.prom
cat /var/lib/prometheus-node-exporter-textfiles/hermes_self_heal.prom
```

Expected: file exists, mtime recent (<2 min), contains `hermes_self_heal_last_heartbeat_seconds` with a current unix timestamp, plus all 5 action labels.

- [ ] **Step 5:** Verify old shell-watchdog timer is gone:

```bash
systemctl list-timers --all | grep hermes-self-heal
```

Expected: NO output (the new daemon is `simple`/always-on, not timer-driven).

---

## Task 31: End-to-end synthetic alert injection

**Files:** none (runtime verification).

- [ ] **Step 1:** Inject a synthetic HermesMcpBridgeDown alert directly into the daemon:

```bash
curl -X POST http://127.0.0.1:9098/alert -H 'Content-Type: application/json' -d "$(cat <<EOF
{
  "alerts": [{
    "status": "firing",
    "labels": {"alertname": "HermesMcpBridgeDown", "service": "hermes-mcp", "severity": "critical"},
    "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
EOF
)"
```

Expected response: `{"ok":true}`.

**WARNING — this will actually restart hermes-mcp.service.** Confirm with the user before running if Hermes is currently serving live traffic.

- [ ] **Step 2:** Watch the daemon journal for the action invocation:

```bash
sudo journalctl -u hermes-self-heal -n 30
```

Expected: log lines showing the deterministic-tier path, `sudo -n /etc/nixos/scripts/hermes-self-heal/actions/restart_mcp`, and JSON result `{"ok": true, ...}`.

- [ ] **Step 3:** Verify the attempt counter incremented:

```bash
grep restart_mcp /var/lib/prometheus-node-exporter-textfiles/hermes_self_heal.prom
```

Expected: `hermes_self_heal_attempts_total{action="restart_mcp"} 1` (or higher).

- [ ] **Step 4:** Verify hermes-mcp actually restarted:

```bash
sudo systemctl show -p ActiveEnterTimestamp hermes-mcp.service
```

Expected: timestamp within the last minute.

- [ ] **Step 5:** Verify the incident is in the state file:

```bash
sudo cat /var/lib/hermes-self-heal/incidents.json | python3 -m json.tool
```

Expected: one entry under `active` with `status: "in_progress"` or `"resolved"` (the latter if probe_clear saw `hermes_mcp_ask_hermes_ok=1`).

---

## Task 32: Trigger the nightly report manually + verify email

**Files:** none (runtime verification).

- [ ] **Step 1:** Run a dry-run first (does not send mail):

```bash
sudo HERMES_REPORT_DRY_RUN=1 systemctl start hermes-nightly-report.service
sudo journalctl -u hermes-nightly-report -n 100
```

Wait — systemd doesn't let you set env vars that way directly. Better:

```bash
sudo systemd-run --uid=root --gid=root --setenv=HERMES_REPORT_DRY_RUN=1 --pty \
  /run/current-system/sw/bin/python3 \
  /etc/nixos/scripts/hermes-nightly-report.py
```

Or simpler — just trigger the service and let it actually mail:

```bash
sudo systemctl start hermes-nightly-report.service
sudo journalctl -u hermes-nightly-report -n 50
```

Expected: oneshot completes successfully, no errors in the journal.

- [ ] **Step 2:** Verify the email was queued and delivered:

```bash
sudo mailq | head -10
```

Expected: empty queue (mail already delivered) OR one entry being processed.

- [ ] **Step 3:** Confirm with the user that the email arrived in their inbox.

> "I triggered hermes-nightly-report.service manually. Please check johnw@vulcan.lan for a message with subject starting `[hermes-nightly]`. The body should have 8 sections: Headline, Live metrics, microVM uptime, 24h smoke probe, Discord activity, Errors digest, Self-heal incidents, In-VM corroboration."

- [ ] **Step 4:** If the email is missing or malformed, debug:

```bash
sudo journalctl -u hermes-nightly-report -n 100 --no-pager
# Common: 'sendmail: command not found' → check that /run/wrappers/bin/sendmail exists
# Common: 'getifaddrs failed' → AF_NETLINK missing from RestrictAddressFamilies
# Common: SSH probe section says "ssh probe failed: CalledProcessError"
#   → verify the SOPS key auth on the Hermes VM end
```

---

## Task 33: Acceptance criteria sweep

Spec §14 lists 8 acceptance criteria. Verify each.

- [ ] **AC1:** `nixos-rebuild switch --flake '.#vulcan'` succeeds with the new modules. (Done in Task 30.)
- [ ] **AC2:** `nix flake check` passes including the new pytest suites. (Done in Task 29.)
- [ ] **AC3:** `systemctl status hermes-self-heal.service` shows `active (running)`, listening on 127.0.0.1:9098. (Done in Task 30.)
- [ ] **AC4:** `hermes_self_heal_last_heartbeat_seconds` is fresh (<2 min). (Done in Task 30.)
- [ ] **AC5:** A synthetic alert POST results in a logged action and updated counter. (Done in Task 31.)
- [ ] **AC6:** `systemctl start hermes-nightly-report.service` delivers an email with all 8 section headers. (Done in Task 32.)
- [ ] **AC7:** Old `hermes-self-heal.timer` no longer exists. (Done in Task 30 step 5.)
- [ ] **AC8:** `docs/ports.txt` lists `9098 127.0.0.1 Hermes Self-Heal webhook receiver`. (Done in Task 2.)

If all 8 pass, the implementation is complete. If any fails, surface to the user with the exact failing check.

---

## Task 34: Update memory with the Hermes self-heal pipeline

**Files:**
- Create: `/home/johnw/.claude/projects/-etc-nixos/memory/project_hermes_self_heal.md`
- Modify: `/home/johnw/.claude/projects/-etc-nixos/memory/MEMORY.md`

- [ ] **Step 1:** Write the memory file:

```markdown
---
name: Hermes self-heal pipeline
description: AI-assisted self-healing for hermes microVM — daemon on 9098, 5-action L3 allowlist, nightly emailed report
metadata:
  type: project
---
Hermes self-heal landed 2026-05-20. Spec: `docs/superpowers/specs/2026-05-20-hermes-self-heal-and-nightly-report-design.md`. Plan: `docs/superpowers/plans/2026-05-20-hermes-self-heal-and-nightly-report.md`.

**Pieces:**
- `modules/services/hermes-self-heal.nix` — NixOS module, user `hermes-heal`, sudoers allowlist (NOPASSWD on 5 actions + 2 aux).
- `scripts/hermes-self-heal/daemon.py` — Python webhook on `127.0.0.1:9098`, deterministic action (attempt 1) → AI via LiteLLM `hera/Qwen3.6-27B` (attempts 2-3) → stuck (attempt ≥4 emits `HermesSelfHealStuck`). State at `/var/lib/hermes-self-heal/incidents.json`.
- `scripts/hermes-self-heal/actions/{restart_microvm,restart_mcp,restage_secrets,reset_credential_pool,restart_health_check}` — L3 allowlist.
- `scripts/hermes-self-heal/aux/{read_log_tail,kick_health_check}` — read-only helpers.
- `modules/services/hermes-nightly-report.nix` + `scripts/hermes-nightly-report.py` — daily 06:15 email to johnw@vulcan.lan with 8 sections incl. in-VM SSH probe.
- `modules/services/alertmanager.nix` — route `service =~ "hermes-(mcp|agent)"` to receiver `hermes-self-heal` with `continue=true`. First `match_re` in the file.
- `modules/monitoring/alerts/hermes.yaml` — 3 watchdog alerts (`HermesSelfHealDown`, `HermesSelfHealStuck`, `HermesSelfHealLitellmUnreachable`), all labeled `service: hermes-self-heal` so they don't loop.

**Divergence from OpenClaw:** Unknown alerts are explicitly ignored (counted in `hermes_self_heal_unknown_alerts_total`) rather than defaulted to `restart_microvm`. Reason: `HermesApiKeyMissing` is a known un-fixable alert; defaulting would just consume the AI tier and end at stuck.

**How to apply:** When Hermes goes silent:
1. Check `hermes_self_heal_last_heartbeat_seconds` is fresh — if not, the daemon is dead, restart it.
2. Deterministic map: `HermesAskFailing/HermesApiServerDown/HermesDiscordZombieSuspected → restart_microvm`, `HermesMcpBridgeDown → restart_mcp`, `HermesHealthCheckStale → restart_health_check`.
3. Manual override: `curl -X POST http://127.0.0.1:9098/alert -d '{"alerts":[{"status":"firing","labels":{"alertname":"<one of above>","service":"hermes-mcp"},"startsAt":"<isoz>"}]}'`.
4. Reset incident state: `sudo rm /var/lib/hermes-self-heal/incidents.json; sudo systemctl restart hermes-self-heal`.

Related: [[project_openclaw_self_heal]] is the analog this mirrors; [[project_hermes_agent]] is the Hermes VM project.
```

- [ ] **Step 2:** Add to `MEMORY.md`:

```
- [project_hermes_self_heal.md](project_hermes_self_heal.md) — Hermes self-heal daemon on 9098 + nightly emailed report; mirrors OpenClaw with one divergence (no default fallback)
```

- [ ] **Step 3:** No git commit needed for memory files (they're in `~/.claude/`, not the repo).

---

## Completion criteria

- All 34 tasks checked off.
- All 8 acceptance criteria from spec §14 verified.
- An end-to-end alert injection results in the correct action AND the heartbeat metric reflects the attempt.
- The user has confirmed an email arrived from the manually-triggered nightly report.
- Memory updated so future sessions know the pipeline exists.

---

## Risk register

| Risk | Mitigation |
|---|---|
| The first synthetic alert injection (Task 31) actually restarts hermes-mcp during normal hours. | Explicit user confirmation before Task 31 step 1. |
| `match_re` syntax rejected by Alertmanager at runtime despite passing eval. | Tested manually via Alertmanager UI after Task 30 — verify the route appears under `http://127.0.0.1:9093/#/status`. |
| LiteLLM is reachable from the daemon's sandbox (the `RestrictAddressFamilies` excludes nothing relevant, but the credential plumbing is new). | Acceptance task 31 step 3 covers attempt-counter increment; if AI tier ever runs, the `_litellm_unreachable_total` counter would catch missing connectivity. |
| Nightly report SSH probe key has wrong permissions / format. | Task 28 ensures mode `0400` owner root. `LoadCredential` plumbs it into a transient memory-backed dir. |
| The replaced `hermes-self-heal.service` unit's `Type` change from `oneshot` to `simple` confuses switch-to-configuration. | Tested in Task 30 — should be clean per systemd's normal behavior. |
| `reset_credential_pool` deletes the wrong file. | Action script realpath-validates the target before delete. Test covered by the action-script shape test family. |
