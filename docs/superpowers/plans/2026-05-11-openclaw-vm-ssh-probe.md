# OpenClaw VM SSH Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four `(skipped from host context)` MCP server statuses in the
OpenClaw nightly health report with real `mcporter list` results obtained by SSH'ing
from the host (vulcan) into the OpenClaw microVM (10.99.0.2) as the `openclaw` runtime
user.

**Architecture:** The microVM gets an `openssh` daemon bound to its bridge IP and
locked to host-bridge ingress only. The host's `openclaw-nightly-report` systemd
service receives an SOPS-encrypted ed25519 private key via `LoadCredential=`, then
invokes `ssh openclaw@10.99.0.2 mcporter list` whenever it needs to probe a
`HOST_BLIND_SERVERS` entry. The existing `mcporter list` output format is identical
inside the VM, so a shared `_parse_mcporter_output()` helper feeds both the host-side
and SSH-side probes. SSH failures fall back to the current "skipped" rendering with a
stderr note, so a broken VM SSH path never blocks the report.

**Tech Stack:** NixOS modules, SOPS-nix, systemd `LoadCredential=`, OpenSSH client
(host) + server (VM), Python 3 (existing `writePython3Bin` wrapper), pytest for
parser unit tests.

---

## Why this approach

`HOST_BLIND_SERVERS` (drafts, google-calendar-personal, google-calendar-work,
home-assistant) need credentials that only exist inside the microVM: OAuth tokens
under `${stateDir}/.config/`, the Home Assistant token mounted via the stateDir
share, and the in-VM CA bundle that lets the remote SSE bridge to `drafts` on hera
work. Running `mcporter list` inside the VM is the only place those credentials
already exist; SSH gives us the simplest invocation channel without adding a new
RPC service or shared-filesystem mount.

## File Structure

**Modified files:**

- `/etc/nixos/secrets/secrets.yaml` — adds `openclaw.probe-ssh-private-key` (the
  private half of the probe keypair). The public half is non-secret and lives in
  the VM module.
- `/etc/nixos/modules/services/openclaw-vm.nix` — enables `services.openssh` inside
  the guest, pins it to `10.99.0.2:22`, sets `users.users.openclaw.openssh.authorizedKeys.keys`
  to the probe public key, and opens TCP/22 on the guest firewall only from the
  host bridge address (10.99.0.1).
- `/etc/nixos/modules/services/openclaw-nightly-report.nix` — declares the SOPS
  secret for the private key, adds `LoadCredential=` to the systemd service,
  appends `openssh` to the service `path`, adds two env vars
  (`OPENCLAW_REPORT_SSH_KEY`, `OPENCLAW_REPORT_SSH_TARGET`).
- `/etc/nixos/scripts/openclaw-nightly-report.py` — extracts a private
  `_parse_mcporter_output()` helper, adds `run_mcporter_list_via_ssh()`, merges its
  results into `live` before `render_report()`, and updates the rendering branch at
  L590 to consult the merged dict before falling back to "skipped".

**Created files:**

- `/etc/nixos/scripts/openclaw-nightly-report-tests/test_parse_mcporter_output.py` —
  pytest module covering the new shared parser with the existing host-side output
  shape and the SSH-side output shape.
- `/etc/nixos/scripts/openclaw-nightly-report-tests/conftest.py` — adds the script
  directory to `sys.path` so the script can be imported as a module under test.

## Decisions locked in

- **VM user:** `openclaw` (already runs the gateway and owns
  `${stateDir}/.config/mcporter/` plus all OAuth state).
- **Key delivery:** SOPS-encrypted, `LoadCredential=` (matches the pattern in
  `modules/services/fetchmail.nix:135`).
- **Host-key verification:** `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`.
  The path between host and VM is the private nftables-managed bridge — there is no
  MitM surface that isn't already root-on-host. This avoids stateful known_hosts
  bookkeeping under `ProtectSystem=strict`.
- **Fallback on failure:** preserve the existing `(skipped from host context)`
  rendering and emit a stderr note. Never let SSH failure abort the report.
- **Scope:** ssh probe runs on every report; we do not add caching or a separate
  systemd timer. The script's existing 180s `mcporter list` timeout becomes a 60s
  SSH-wrapped timeout (more than enough — the VM's `mcporter list` already
  completes in <1s for live servers per memory observation 2128).

---

## Task 1: Generate probe keypair and store in SOPS

**Files:**

- Create: `~/.cache/openclaw-probe-key` + `~/.cache/openclaw-probe-key.pub`
  (ephemeral local scratch; deleted after copy)
- Modify: `/etc/nixos/secrets/secrets.yaml`
- (record of public key for next task: `/tmp/openclaw-probe.pub`)

- [ ] **Step 1: Generate an ed25519 keypair on the host**

```bash
mkdir -p ~/.cache
ssh-keygen -t ed25519 -N "" -C "openclaw-nightly-report-probe" \
  -f ~/.cache/openclaw-probe-key
```

Expected: two files created. Do **NOT** `cat` either of them.
Verify with metadata only:

```bash
ls -la ~/.cache/openclaw-probe-key ~/.cache/openclaw-probe-key.pub
file ~/.cache/openclaw-probe-key
```

- [ ] **Step 2: Stage the public key for the next task**

```bash
cp ~/.cache/openclaw-probe-key.pub /tmp/openclaw-probe.pub
```

The public key file is safe to view (`cat /tmp/openclaw-probe.pub`) — it is
designed to be checked into source.

- [ ] **Step 3: Encrypt the private key into `secrets.yaml` via the SOPS editor**

Multi-line OpenSSH private keys through `sops --set` + shell expansion is
fragile (newlines and quoting). Use the editor flow:

```bash
sops /etc/nixos/secrets/secrets.yaml
```

In the editor, under the existing `openclaw:` block (line ~113, alongside
sub-keys `org-db-password`, `config`, `gcp-oauth-keys`, etc.), add:

```yaml
    probe-ssh-private-key: |
      -----BEGIN OPENSSH PRIVATE KEY-----
      <paste full contents of ~/.cache/openclaw-probe-key here, preserving
       all line breaks; sops will encrypt the literal block scalar>
      -----END OPENSSH PRIVATE KEY-----
```

Indentation must match the other sub-keys under `openclaw:` (4 spaces).
Save and exit.

- [ ] **Step 4: Securely delete the local private key immediately**

The plaintext key is no longer needed — encryption is complete. Destroy it
before doing any further verification:

```bash
shred -u ~/.cache/openclaw-probe-key
```

The public half stays at `/tmp/openclaw-probe.pub` for Task 2.

- [ ] **Step 5: Verify the encrypted form landed correctly**

```bash
grep -n "probe-ssh-private-key" /etc/nixos/secrets/secrets.yaml
```

Expected: line shows `probe-ssh-private-key: ENC[AES256_GCM,…`. The presence of
`ENC[` is the proof. Do **NOT** `sops -d` to verify content — that is forbidden
by CLAUDE.md.

- [ ] **Step 6: Commit**

```bash
git add /etc/nixos/secrets/secrets.yaml
git commit -m "feat(openclaw): add SSH probe key for nightly-report VM access"
```

---

## Task 2: Enable sshd inside the OpenClaw microVM

**Files:**

- Modify: `/etc/nixos/modules/services/openclaw-vm.nix`
  - After `users.groups.openclaw = { gid = openclawGid; };` (currently L503-505),
    add the `authorizedKeys` attribute via a separate `users.users.openclaw`
    augmentation block — keeping the `let` preamble untouched.
  - Inside the guest config (where `networking.hostName`, `networking.firewall`,
    etc. live), add `services.openssh` configuration.
  - Inside the guest firewall declaration (currently L1084 — `networking.firewall`),
    open TCP/22 with a source restriction.

- [ ] **Step 1: Read the public key value to paste into the module**

```bash
cat /tmp/openclaw-probe.pub
```

Copy the single-line `ssh-ed25519 AAAA… openclaw-nightly-report-probe` for the
next step.

- [ ] **Step 2: Add `authorizedKeys.keys` to the openclaw user**

Edit `/etc/nixos/modules/services/openclaw-vm.nix`. Locate the existing block:

```nix
  users.users.openclaw = {
    isSystemUser = true;
    uid = openclawUid;
    group = "openclaw";
    home = stateDir;
    shell = pkgs.bashInteractive;
    description = "OpenClaw AI Gateway service user";
  };
```

Add the `openssh.authorizedKeys.keys` field as the last attribute (before the
closing `};`):

```nix
    openssh.authorizedKeys.keys = [
      # Public half of the SSH key used by openclaw-nightly-report on the
      # host to probe HOST_BLIND_SERVERS from inside the VM. Private half
      # lives in secrets.yaml under openclaw.probe-ssh-private-key.
      "ssh-ed25519 AAAAC3Nz…<paste from /tmp/openclaw-probe.pub>… openclaw-nightly-report-probe"
    ];
```

- [ ] **Step 3: Enable `services.openssh` in the guest**

Add a new block alongside the other guest service declarations (anywhere inside
the microVM config — pick a spot near `systemd.services.openclaw` for locality,
e.g. just before that block at L521):

```nix
  # ========================================================================
  # In-VM sshd
  # ========================================================================
  # Used exclusively by openclaw-nightly-report on the host to probe MCP
  # servers whose credentials live inside the VM (drafts, google-calendar-*,
  # home-assistant). Listening only on the bridge IP and gated by the guest
  # firewall to source 10.99.0.1.

  services.openssh = {
    enable = true;
    # CRITICAL: default is true, which would add TCP/22 to
    # networking.firewall.allowedTCPPorts (unrestricted), defeating the
    # source-scoped extraInputRules below. Source-restrict via nftables
    # only.
    openFirewall = false;
    listenAddresses = [
      { addr = "10.99.0.2"; port = 22; }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      # Limit which users can SSH in — only the probe user.
      AllowUsers = [ "openclaw" ];
    };
  };
```

The VM's host keys are auto-generated by NixOS on first boot and stored at
`/etc/ssh/ssh_host_*` inside the guest. We intentionally do not pin them — the
host-side `StrictHostKeyChecking=no` setting in Task 4 makes their rotation
harmless.

- [ ] **Step 4: Open TCP/22 in the guest firewall, source-restricted**

Locate the `networking.firewall` block at L1084. The existing form is
`networking.firewall = { … };`. We do **not** want to add 22 to the global
`allowedTCPPorts` list — that would accept connections from anywhere routed to
the VM. Use `extraInputRules` instead so the rule is scoped to source IP:

```nix
  networking.firewall = {
    enable = true;
    # … existing allowedTCPPorts etc. …
    extraInputRules = ''
      ip saddr 10.99.0.1 tcp dport 22 accept comment "openclaw-nightly-report probe from host bridge"
    '';
  };
```

(If `extraInputRules` already exists, append the new line to the existing
multi-line string rather than redefining the field.)

- [ ] **Step 5: Verify the change builds**

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' 2>&1 | tail -20
```

Expected: build succeeds, no eval errors. Do **not** switch yet.

- [ ] **Step 6: Switch and verify sshd is listening inside the VM**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
sudo systemctl status microvm@openclaw.service --no-pager
```

Then from the host, probe the bridge directly:

```bash
nc -zv 10.99.0.2 22
```

Expected: `Connection to 10.99.0.2 22 port [tcp/ssh] succeeded!`

- [ ] **Step 7: Verify the probe key can authenticate**

Use a transient one-shot SSH call from a shell that has the SOPS-decrypted key
deployed (it will be at `/run/secrets/openclaw/probe-ssh-private-key` only
after Task 3 — for now, use the original local copy if you kept one, or skip
this step and defer verification to the end of Task 4):

```bash
# Skip if the local /tmp/openclaw-probe.pub is the only copy left.
# Verification is built into Task 4's deployment.
```

- [ ] **Step 8: Commit**

```bash
git add /etc/nixos/modules/services/openclaw-vm.nix
git commit -m "feat(openclaw-vm): expose sshd to host bridge for nightly probe"
```

---

## Task 3: Wire the probe key into the host nightly-report service

**Files:**

- Modify: `/etc/nixos/modules/services/openclaw-nightly-report.nix`

- [ ] **Step 1: Declare the SOPS secret**

At the top of the module (after the `let … in` block, before
`systemd.services.openclaw-nightly-report = { … }`), add:

```nix
  sops.secrets."openclaw/probe-ssh-private-key" = {
    mode = "0400";
    owner = "root";
    group = "root";
  };
```

- [ ] **Step 2: Add `openssh` to the service `path`**

In the existing `path = with pkgs; [ … ];` list (currently L38-42), append
`openssh`:

```nix
    path = with pkgs; [
      systemd
      coreutils
      mcporterPkg
      openssh # for the in-VM mcporter probe over SSH
    ];
```

- [ ] **Step 3: Add the SSH env vars**

In the existing `environment = { … };` block (currently L44-52), append:

```nix
      # In-VM probe for HOST_BLIND_SERVERS (drafts, google-calendar-*,
      # home-assistant). SSH key is delivered via LoadCredential below;
      # %d expands to $CREDENTIALS_DIRECTORY at runtime.
      OPENCLAW_REPORT_SSH_KEY = "%d/probe-ssh-key";
      OPENCLAW_REPORT_SSH_TARGET = "openclaw@10.99.0.2";
```

Note: `%d` expands to `$CREDENTIALS_DIRECTORY` at runtime inside the
systemd-managed credential mount.

- [ ] **Step 4: Add `LoadCredential` to `serviceConfig`**

In the existing `serviceConfig = { … };` block (currently L54-89), add:

```nix
      LoadCredential = [
        "probe-ssh-key:${config.sops.secrets."openclaw/probe-ssh-private-key".path}"
      ];
```

If a `LoadCredential` field already exists, merge into the list rather than
replacing.

- [ ] **Step 5: Rebuild and verify credential delivery**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
sudo systemctl show openclaw-nightly-report.service -p LoadCredential
```

Expected: `LoadCredential=probe-ssh-key:/run/secrets/openclaw/probe-ssh-private-key`

Verify the encrypted-on-disk secret deployed correctly without reading content:

```bash
sudo stat /run/secrets/openclaw/probe-ssh-private-key
```

Expected: `Uid: (0/root)` `Gid: (0/root)` `Access: (0400/-r--------)`.

- [ ] **Step 6: One-shot smoke test — credential reaches ssh**

```bash
sudo systemd-run --unit=ssh-probe-smoke --pty \
  --property=LoadCredential="probe-ssh-key:/run/secrets/openclaw/probe-ssh-private-key" \
  --property=PrivateTmp=true \
  /run/current-system/sw/bin/ssh \
    -i "$CREDENTIALS_DIRECTORY/probe-ssh-key" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    openclaw@10.99.0.2 \
    'echo ok && which mcporter'
```

Expected: prints `ok` followed by a `/nix/store/.../bin/mcporter` path.

- [ ] **Step 7: Commit**

```bash
git add /etc/nixos/modules/services/openclaw-nightly-report.nix
git commit -m "feat(openclaw-nightly-report): wire SSH probe credential and ssh binary"
```

---

## Task 4: Implement the SSH probe in the Python script (TDD)

**Files:**

- Create: `/etc/nixos/scripts/openclaw-nightly-report-tests/conftest.py`
- Create: `/etc/nixos/scripts/openclaw-nightly-report-tests/test_parse_mcporter_output.py`
- Modify: `/etc/nixos/scripts/openclaw-nightly-report.py`

The TDD ordering: factor the parser first under test, then add the SSH variant
on top of the proven parser.

### Sub-Task 4a: Factor parser into a tested helper

- [ ] **Step 1: Create the test scaffolding**

Create `/etc/nixos/scripts/openclaw-nightly-report-tests/conftest.py`:

```python
"""Test fixtures for the openclaw nightly report parser tests."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))


def load_report_module():
    """Load the script as `openclaw_nightly_report` despite its filename hyphens."""
    spec_path = SCRIPT_DIR / "openclaw-nightly-report.py"
    spec = importlib.util.spec_from_file_location(
        "openclaw_nightly_report", spec_path
    )
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod
```

- [ ] **Step 2: Write the failing parser test**

Create `/etc/nixos/scripts/openclaw-nightly-report-tests/test_parse_mcporter_output.py`:

```python
"""Unit tests for _parse_mcporter_output()."""

from __future__ import annotations

from conftest import load_report_module

report = load_report_module()


def test_parses_single_ok_server():
    stdout = "- searxng — SearXNG metasearch (2 tools, 0.6s)\n"
    result = report._parse_mcporter_output(stdout)
    assert "searxng" in result
    assert result["searxng"]["tool_count"] == 2
    assert result["searxng"]["status"].startswith("2 tools")


def test_parses_multiple_servers():
    stdout = (
        "- email-contacts — Email contacts (7 tools, 0.6s)\n"
        "- stock-trader — Stock trading (8 tools, 0.6s)\n"
        "- drafts — Drafts SSE bridge (1 tool, 0.8s)\n"
    )
    result = report._parse_mcporter_output(stdout)
    assert set(result) == {"email-contacts", "stock-trader", "drafts"}
    assert result["email-contacts"]["tool_count"] == 7
    assert result["drafts"]["tool_count"] == 1


def test_ignores_non_matching_lines():
    stdout = (
        "Listing MCP servers from /home/openclaw/.config/mcporter/mcp.json\n"
        "- vane — Vane (1 tool, 0.6s)\n"
        "\n"
    )
    result = report._parse_mcporter_output(stdout)
    assert set(result) == {"vane"}


def test_empty_input_returns_empty_dict():
    assert report._parse_mcporter_output("") == {}
```

- [ ] **Step 3: Run the test — confirm it fails**

```bash
cd /etc/nixos/scripts
pytest openclaw-nightly-report-tests/ -v 2>&1 | tail -20
```

Expected: collection error or `AttributeError: module … has no attribute
'_parse_mcporter_output'`.

- [ ] **Step 4: Extract `_parse_mcporter_output` from `run_mcporter_list`**

In `/etc/nixos/scripts/openclaw-nightly-report.py`, find the parsing loop
(currently at L262 inside `run_mcporter_list`). Lift it into a module-level
helper, immediately after `_MCPORTER_LIST_RE` (L136):

```python
def _parse_mcporter_output(stdout: str) -> dict[str, dict[str, Any]]:
    """Parse `mcporter list` stdout into {name: {"status", "tool_count", "raw"}}."""
    out: dict[str, dict[str, Any]] = {}
    for line in stdout.splitlines():
        m = _MCPORTER_LIST_RE.match(line)
        if not m:
            continue
        name = m.group("name")
        status_raw = m.group("status")
        tc_match = re.match(r"(\d+)\s+tools?", status_raw)
        out[name] = {
            "status": status_raw,
            "tool_count": int(tc_match.group(1)) if tc_match else None,
            "raw": line,
        }
    return out
```

Then replace the in-function loop in `run_mcporter_list` (currently L262-279
— the `matched = 0; for line in proc.stdout.splitlines(): …` block and the
trailing `if matched == 0:` diagnostic) with a single call. The existing
diagnostic stderr message must be preserved verbatim — capture its current
text from the script before editing, then write back:

```python
    out = _parse_mcporter_output(proc.stdout)
    if not out:
        # Preserve the exact diagnostic that was at the old L279+ — read it
        # out of the current file before this edit and paste it back here.
        sys.stderr.write(
            "run_mcporter_list: parsed 0 servers from mcporter output. "
            "Check mcp.json and credentials.\n"
        )
    return out
```

Concrete procedure: run `sed -n '260,290p' /etc/nixos/scripts/openclaw-nightly-report.py`
before editing to see the exact existing stderr text and copy it into the new
form. Do not paraphrase — the journal grep patterns in self-heal depend on
the exact string.

- [ ] **Step 5: Run the parser tests — confirm they pass**

```bash
cd /etc/nixos/scripts
pytest openclaw-nightly-report-tests/ -v 2>&1 | tail -10
```

Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
git add /etc/nixos/scripts/openclaw-nightly-report.py \
        /etc/nixos/scripts/openclaw-nightly-report-tests/
git commit -m "refactor(openclaw-report): extract _parse_mcporter_output for reuse"
```

### Sub-Task 4b: Add the SSH probe function

- [ ] **Step 1: Write a failing test for the SSH probe**

Append to `/etc/nixos/scripts/openclaw-nightly-report-tests/test_parse_mcporter_output.py`:

```python
import subprocess
from unittest.mock import patch, MagicMock


def test_run_mcporter_list_via_ssh_returns_parsed_dict(monkeypatch):
    fake_stdout = (
        "- drafts — Drafts (1 tool, 0.5s)\n"
        "- home-assistant — HA bridge (12 tools, 0.7s)\n"
    )
    fake_proc = MagicMock(returncode=0, stdout=fake_stdout, stderr="")
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: fake_proc)
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_KEY", "/tmp/fake-key")
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_TARGET", "openclaw@10.99.0.2")
    result = report.run_mcporter_list_via_ssh()
    assert set(result) == {"drafts", "home-assistant"}
    assert result["home-assistant"]["tool_count"] == 12


def test_run_mcporter_list_via_ssh_missing_env_returns_empty(monkeypatch):
    monkeypatch.delenv("OPENCLAW_REPORT_SSH_KEY", raising=False)
    monkeypatch.delenv("OPENCLAW_REPORT_SSH_TARGET", raising=False)
    assert report.run_mcporter_list_via_ssh() == {}


def test_run_mcporter_list_via_ssh_returns_empty_on_failure(monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **k: (_ for _ in ()).throw(subprocess.TimeoutExpired("ssh", 60)),
    )
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_KEY", "/tmp/fake-key")
    monkeypatch.setenv("OPENCLAW_REPORT_SSH_TARGET", "openclaw@10.99.0.2")
    assert report.run_mcporter_list_via_ssh() == {}
```

- [ ] **Step 2: Run it — confirm it fails**

```bash
cd /etc/nixos/scripts
pytest openclaw-nightly-report-tests/ -v -k via_ssh 2>&1 | tail -10
```

Expected: `AttributeError: … has no attribute 'run_mcporter_list_via_ssh'`.

- [ ] **Step 3: Implement `run_mcporter_list_via_ssh`**

In `/etc/nixos/scripts/openclaw-nightly-report.py`, add this function
immediately after `run_mcporter_list` (which currently ends near L286). Place
it before any later sections (e.g. before "Source 3: gateway state"):

```python
def run_mcporter_list_via_ssh() -> dict[str, dict[str, Any]]:
    """Probe MCP servers from inside the OpenClaw microVM over SSH.

    Returns the same shape as `run_mcporter_list()`. Empty dict on any failure;
    callers must merge defensively. Required env:
        OPENCLAW_REPORT_SSH_KEY     path to private key (LoadCredential).
        OPENCLAW_REPORT_SSH_TARGET  user@host (e.g. openclaw@10.99.0.2).
    """
    key = os.getenv("OPENCLAW_REPORT_SSH_KEY")
    target = os.getenv("OPENCLAW_REPORT_SSH_TARGET")
    if not key or not target:
        sys.stderr.write(
            "run_mcporter_list_via_ssh: SSH env not configured; skipping VM probe\n"
        )
        return {}

    ssh_cmd = [
        "ssh",
        "-i", key,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "LogLevel=ERROR",
        # Defensive: don't fall back to ssh-agent or user-default identities.
        "-o", "IdentitiesOnly=yes",
        target,
        "mcporter list",
    ]
    try:
        proc = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        sys.stderr.write("run_mcporter_list_via_ssh: ssh timed out after 60s\n")
        return {}
    except Exception as exc:
        sys.stderr.write(
            f"run_mcporter_list_via_ssh: ssh subprocess failed: "
            f"{type(exc).__name__}: {exc}\n"
        )
        return {}

    if proc.returncode != 0:
        sys.stderr.write(
            f"run_mcporter_list_via_ssh: ssh exited {proc.returncode}: "
            f"{proc.stderr[:300]}\n"
        )
        return {}

    return _parse_mcporter_output(proc.stdout)
```

- [ ] **Step 4: Run the tests — confirm they pass**

```bash
cd /etc/nixos/scripts
pytest openclaw-nightly-report-tests/ -v 2>&1 | tail -10
```

Expected: 7 passed (4 from sub-task 4a + 3 new).

- [ ] **Step 5: Commit**

```bash
git add /etc/nixos/scripts/openclaw-nightly-report.py \
        /etc/nixos/scripts/openclaw-nightly-report-tests/
git commit -m "feat(openclaw-report): add run_mcporter_list_via_ssh probe function"
```

### Sub-Task 4c: Integrate into the report flow

- [ ] **Step 1: Update `main()` to merge both probe results**

In `/etc/nixos/scripts/openclaw-nightly-report.py`, modify `main()` (currently
L741-748):

```python
def main() -> int:
    textfile = parse_textfile()
    live = run_mcporter_list()
    # Probe HOST_BLIND_SERVERS from inside the VM. VM results take precedence
    # over host results only for the blind set — host probes of other servers
    # are authoritative because they exercise the same code path as the bot.
    vm_live = run_mcporter_list_via_ssh()
    for name in HOST_BLIND_SERVERS:
        if name in vm_live:
            live[name] = vm_live[name]
    gateway = gateway_state()
    errors = recent_errors()
    uptime = microvm_uptime()
    subject, body = render_report(textfile, live, gateway, errors, uptime)
    return deliver(subject, body)
```

- [ ] **Step 2: Update the renderer's HOST_BLIND branch**

In `render_report()`, at the current L583-602, the branch reads:

```python
        live_info = live.get(name)
        …
        if name in HOST_BLIND_SERVERS:
            live_count = "n/a"
            status = "(skipped from host context)"
        elif live_info is None:
            …
```

Reorder so that VM-probed `HOST_BLIND_SERVERS` get rendered with real counts,
and only fall back to "skipped" when the VM probe yielded nothing:

```python
        live_info = live.get(name)
        if name in HOST_BLIND_SERVERS and live_info is None:
            # VM-side probe failed or wasn't available. Preserve the
            # historical "skipped" presentation so a broken SSH path
            # doesn't degrade the readability of the report.
            live_count = "n/a"
            status = "(skipped from host context)"
        elif live_info is None:
            live_count = "?"
            status = "(not seen in mcporter list)"
        else:
            live_count = (
                str(live_info["tool_count"])
                if live_info["tool_count"] is not None
                else "—"
            )
            status = live_info["status"]
```

- [ ] **Step 3: Dry-run end-to-end on the host**

`systemctl start` doesn't accept environment overrides for an existing unit's
config. Use `systemd-run` to invoke the unit's binary in a transient scope
with the dry-run env var injected, while reusing the unit's credential
delivery:

```bash
sudo systemd-run --pty --wait \
  --unit=openclaw-nightly-report-dryrun \
  --property=Environment=OPENCLAW_REPORT_DRY_RUN=1 \
  --property=Environment=OPENCLAW_REPORT_TO=johnw@vulcan.lan \
  --property=Environment=OPENCLAW_REPORT_FROM=openclaw-health@vulcan.lan \
  --property=Environment=OPENCLAW_REPORT_SENDMAIL=/run/wrappers/bin/sendmail \
  --property=Environment=OPENCLAW_REPORT_MCPORTER=$(systemctl show openclaw-nightly-report.service -p Environment --value | grep -oP 'OPENCLAW_REPORT_MCPORTER=\K[^ ]+') \
  --property=Environment=OPENCLAW_REPORT_SSH_KEY=%d/probe-ssh-key \
  --property=Environment=OPENCLAW_REPORT_SSH_TARGET=openclaw@10.99.0.2 \
  --property=LoadCredential=probe-ssh-key:/run/secrets/openclaw/probe-ssh-private-key \
  $(systemctl show openclaw-nightly-report.service -p ExecStart --value | awk '{print $1}' | sed 's/[{};]//g')
```

Alternative (simpler but writes to your inbox if not careful) — use
`systemctl edit --runtime` to add a transient `Environment=OPENCLAW_REPORT_DRY_RUN=1`
drop-in, run the unit normally, then `systemctl revert --runtime` to remove
the drop-in:

```bash
sudo systemctl edit --runtime openclaw-nightly-report.service
# Add in editor:
#   [Service]
#   Environment=OPENCLAW_REPORT_DRY_RUN=1
sudo systemctl start openclaw-nightly-report.service
sudo journalctl -u openclaw-nightly-report.service -n 120 --no-pager
sudo systemctl revert openclaw-nightly-report.service
```

Expected: the MCP table now shows live tool counts for drafts,
google-calendar-personal, google-calendar-work, and home-assistant, with
status strings like `12 tools, 0.7s` instead of `(skipped from host context)`.

- [ ] **Step 4: Verify the fallback path still works**

SSH originates from the host, so the host's `input` chain isn't the right
place to insert a reject rule (it filters incoming traffic *to* the host).
Break the path from the VM side instead by transiently stopping sshd inside
the guest:

```bash
# Stop sshd inside the VM. The microvm exposes the guest console via a unix
# socket — easier to just briefly reject TCP/22 on the VM's input chain.
sudo machinectl shell openclaw@openclaw-vm /bin/sh -c \
  'nft insert rule inet filter input tcp dport 22 reject comment "TEMP-fallback-test"'

# Rerun the dry-run (Step 3's systemd-run variant).

# Remove the reject:
sudo machinectl shell openclaw@openclaw-vm /bin/sh -c \
  'nft -a list chain inet filter input | awk "/TEMP-fallback-test/ {print \$NF}" | xargs -r -I H nft delete rule inet filter input handle H'
```

If `machinectl shell` isn't available for this microVM (microvm.nix doesn't
always expose a machinectl-compatible interface), fall back to host-side
output filtering, which definitely affects the report's outbound connection:

```bash
sudo nft add rule inet filter output ip daddr 10.99.0.2 tcp dport 22 reject \
  comment "TEMP-openclaw-probe-output-block"
# Rerun the dry-run.
sudo nft -a list chain inet filter output | grep TEMP-openclaw-probe-output-block
# Note the handle, then:
sudo nft delete rule inet filter output handle <N>
```

Expected: the four servers render as `(skipped from host context)` again, and
a stderr line like `run_mcporter_list_via_ssh: ssh exited …` (or
`run_mcporter_list_via_ssh: ssh subprocess failed`) appears in the journal.

- [ ] **Step 5: Commit**

```bash
git add /etc/nixos/scripts/openclaw-nightly-report.py
git commit -m "feat(openclaw-report): probe HOST_BLIND_SERVERS via VM SSH"
```

---

## Task 5: Deploy, verify in production, and clean up

- [ ] **Step 1: Final rebuild and switch**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
```

- [ ] **Step 2: Trigger a live report run (no dry-run)**

```bash
sudo systemctl start openclaw-nightly-report.service
sudo journalctl -u openclaw-nightly-report.service -n 100 --no-pager
```

Verify in the journal that the run succeeded and that no stderr lines
mention SSH errors.

- [ ] **Step 3: Check the delivered email**

Use `doveadm` to inspect the most recent mail to johnw:

```bash
# Find the latest UID in INBOX, then fetch that single message's body.
LATEST=$(sudo doveadm -f flow search -u johnw mailbox INBOX all \
  | awk 'END{print $NF}')
sudo doveadm fetch -u johnw 'body' mailbox INBOX uid "$LATEST" \
  2>/dev/null | grep -A 12 "MCP Servers"
```

If your search syntax differs, opening the inbox in your usual mail client is
fine — the visual confirmation is what matters.

Expected: the four previously-skipped servers now show live tool counts. The
table should resemble:

```
drafts                       OK      1        1 tool, 0.6s
google-calendar-personal     OK      14       14 tools, 0.8s
google-calendar-work         OK      14       14 tools, 0.8s
home-assistant               OK      12       12 tools, 0.9s
```

- [ ] **Step 4: Remove the staged public key file**

```bash
rm /tmp/openclaw-probe.pub
```

- [ ] **Step 5: Save a project memory**

Save a `project_openclaw_vm_ssh_probe.md` memory describing:

- Probe key flow: `secrets.yaml` → `LoadCredential=probe-ssh-key:…` →
  `$CREDENTIALS_DIRECTORY/probe-ssh-key` → `ssh openclaw@10.99.0.2`.
- Host bridge (10.99.0.1) is the only ingress on the VM's TCP/22; gated
  by `extraInputRules` with `services.openssh.openFirewall = false` so
  the global firewall doesn't auto-open the port.
- Fallback path on SSH failure: preserve the `(skipped from host context)`
  rendering. Stderr line `run_mcporter_list_via_ssh: …` in the journal is
  the diagnostic signal.
- Manual fallback-test commands (from Task 4c Step 4 of this plan) so future
  sessions don't rediscover them.

This helps future sessions diagnose unexpected fallback occurrences and
avoids re-litigating the SSH-vs-textfile design decision.

- [ ] **Step 6: Final commit (only if any uncommitted polish remains)**

```bash
git status
# If clean, skip. Otherwise:
# git commit -m "chore(openclaw): wrap up VM SSH probe rollout"
```

---

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| SSH host key rotates on VM rebuild → connection fails. | `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`. Bridge is private; MitM scope is host root, which already owns the report. |
| sshd inside VM increases attack surface. | Bound to 10.99.0.2 only; firewall rule allows only saddr 10.99.0.1; only `openclaw` user accepted; password auth off; no root login. |
| `mcporter list` inside VM is slow → blocks report. | 60s SSH timeout (vs the host-side 180s today). Memory 2128 shows VM-side mcporter takes <2.4s. |
| Report runs every 5 min via `openclaw-mcporter-check.service` — does our change apply there too? | No. Read the `openclaw-mcporter-check` module before assuming. This plan touches only `openclaw-nightly-report`. If the check service also has the same blind-set problem, file a follow-up. |
| systemd sandbox blocks ssh. | Existing `RestrictAddressFamilies` already includes `AF_INET`; ssh writes nothing under `ProtectSystem=strict` because we route known_hosts to `/dev/null`. PrivateTmp=true is fine — ssh doesn't use /tmp by default. |
| Private key on disk in `/run/secrets/`. | Mode `0400 root:root`; only visible to the report unit via `LoadCredential` namespace `%d`. Standard SOPS pattern. |

## Out of scope

- Updating `openclaw-mcporter-check.service` (the every-5-minute exporter) to
  use the same probe. It currently uses textfile metrics only; extending it
  belongs in a separate plan.
- Adding a Nagios/Prometheus alert when the SSH probe fails. The nightly
  report's existing "issues" header now naturally surfaces probe loss because
  the skipped rows become rare instead of constant.
- Rewriting the report to deduplicate host vs VM probes for non-blind servers.
  We intentionally keep host-side probes authoritative for everything outside
  `HOST_BLIND_SERVERS`, since they exercise the same network path the bot
  itself uses.
