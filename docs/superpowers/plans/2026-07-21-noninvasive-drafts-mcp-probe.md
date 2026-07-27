# Non-invasive Drafts MCP Probe Implementation Plan

> **Archival — 2026-07-21.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `scripts/drafts-mcp-check/drafts_mcp_check.py`, `modules/monitoring/services/drafts-mcp-check.nix`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve five-minute Drafts MCP transport monitoring on Vulcan without any scheduled AppleEvent or GUI interaction, while retaining a clearly invasive manual app/TCC diagnostic.

**Architecture:** A standalone Python probe exposes two explicit modes. The default scheduled mode stops after MCP `tools/list` and publishes transport-only metrics; `--app-check` adds exactly one read-only `drafts_list_workspaces` call, writes no periodic metrics, and is reachable only through an untimed manual systemd unit. Prometheus alerts and self-healing follow the transport-only contract.

**Tech Stack:** NixOS modules, systemd services and timers, Python 3.12, httpx, pytest, Prometheus rules, promtool.

## Global Constraints

- No scheduled code path may send MCP `tools/call`, address Drafts.app through AppleEvents, launch it, reopen it, or reveal it.
- The scheduled interval remains 300 seconds.
- The scheduled path must verify `drafts-mcp.service`, loopback SSE, the persistent SSH child, Hera's forced command, and MCP `tools/list`.
- The only application call is the manual service's read-only `drafts_list_workspaces`; `drafts_run_action` and all mutating tools remain forbidden.
- Periodic metrics and alerts may claim only transport evidence.
- Self-healing may restart only `drafts-mcp.service` and only for bridge or transport failures.
- The manual service has no timer, `wantedBy`, or automatic dependency.
- Existing hard timeouts, atomic textfile writes, service confinement, and secret-free operation remain.
- Do not decrypt or inspect `secrets/secrets.yaml`.
- Before any Vulcan build or switch, obey the `/etc/nixos/.nixos-build` lock protocol.
- Completion requires live Hera event-log evidence across a scheduled cycle, not source inspection alone.

---

### Task 1: Add a Failing No-GUI Regression Test

**Files:**
- Create: `scripts/drafts-mcp-check/tests/test_drafts_mcp_check.py`
- Modify: `flake.nix`

**Interfaces:**
- Consumes: `scripts/drafts-mcp-check/drafts_mcp_check.py`, initially absent.
- Produces: flake check `drafts-mcp-check-tests`.

- [ ] **Step 1: Create the focused test suite before production code**

The test module must load `../drafts_mcp_check.py` with
`importlib.util.spec_from_file_location`. Before loading, install a minimal
`httpx` sentinel in `sys.modules`; the tests exercise pure request and
mode-control functions rather than making network calls.

Require these exact behaviors:

```python
def test_scheduled_request_sequence_never_calls_a_tool(probe):
    requests = probe.build_mcp_requests(app_check=False)
    assert [request["method"] for request in requests] == [
        "initialize",
        "notifications/initialized",
        "tools/list",
    ]
    assert all(request["method"] != "tools/call" for request in requests)


def test_manual_request_sequence_calls_only_read_only_workspace_tool(probe):
    requests = probe.build_mcp_requests(app_check=True)
    calls = [request for request in requests if request["method"] == "tools/call"]
    assert calls == [{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "drafts_list_workspaces",
            "arguments": {},
        },
    }]


def test_periodic_metrics_are_transport_only(probe):
    metrics = probe.periodic_metrics(
        bridge_up=1,
        sse_open_ok=1,
        ssh_hera_ok=1,
        timestamp=123.5,
    )
    assert set(metrics) == {
        "drafts_mcp_bridge_up",
        "drafts_mcp_sse_open_ok",
        "drafts_mcp_ssh_hera_ok",
        "drafts_mcp_check_last_run_timestamp_seconds",
    }
    assert "drafts_mcp_tcc_automation_ok" not in metrics
    assert "drafts_mcp_e2e_ok" not in metrics
```

Also test that `parse_args([]).app_check` is false,
`parse_args(["--app-check"]).app_check` is true, scheduled mode writes
metrics, manual mode never calls `write_metrics`, and manual app failure
returns a nonzero status.

- [ ] **Step 2: Register the test in the flake**

Add:

```nix
drafts-mcp-check-tests = helpers.mkPytestCheck {
  name = "drafts-mcp-check-tests";
  src = ./scripts/drafts-mcp-check;
  suiteDir = "tests";
};
```

The test stubs `httpx`, so no test-environment dependency change is needed.

- [ ] **Step 3: Run the focused check and verify RED**

Run:

```sh
nix build -L path:.#checks.aarch64-linux.drafts-mcp-check-tests
```

Expected: FAIL because `drafts_mcp_check.py` does not exist. Confirm the
failure is the missing production module, not a fixture or Nix evaluation
error.

### Task 2: Implement the Split Scheduled and Manual Probe

**Files:**
- Create: `scripts/drafts-mcp-check/drafts_mcp_check.py`
- Modify: `modules/monitoring/services/drafts-mcp-check.nix`
- Test: `scripts/drafts-mcp-check/tests/test_drafts_mcp_check.py`

**Interfaces:**
- Produces:
  - `build_mcp_requests(app_check: bool) -> list[dict[str, object]]`
  - `periodic_metrics(bridge_up: int, sse_open_ok: int, ssh_hera_ok: int, timestamp: float) -> dict[str, int | float]`
  - `parse_args(argv: Sequence[str] | None) -> argparse.Namespace`
  - `probe_mcp(app_check: bool) -> tuple[int, int | None]`
  - `main_async(app_check: bool) -> int`
- Scheduled unit: `drafts-mcp-check.service`.
- Manual unit: `drafts-mcp-app-check.service`.

- [ ] **Step 1: Implement request construction**

`build_mcp_requests(False)` returns only initialize, initialized notification,
and tools/list. `build_mcp_requests(True)` appends exactly:

```python
{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
        "name": "drafts_list_workspaces",
        "arguments": {},
    },
}
```

The runtime must iterate this request sequence. It must wait for and validate a
JSON-RPC result after the two requests carrying ids 1 and 2. It must wait for
id 3 only in manual mode. Any timeout, malformed response, JSON-RPC error, or
`isError` tool result makes the relevant result zero.

- [ ] **Step 2: Implement mode-specific outcomes**

Scheduled mode:

```python
async def main_async(app_check: bool) -> int:
    if not app_check:
        bridge_up = unit_is_active(DRAFTS_MCP_UNIT)
        sse_ok = await probe_sse_open()
        ssh_ok, _ = await probe_mcp(False) if sse_ok else (0, None)
        write_metrics(periodic_metrics(
            bridge_up, sse_ok, ssh_ok, round(time.time(), 3)
        ))
        return 0
```

Manual mode calls `probe_mcp(True)`, prints either
`drafts-mcp app check: ok` or a concise non-secret failure, writes no
Prometheus textfile, and exits 0 only when both transport and the read-only app
call succeed.

`write_metrics` retains atomic same-directory replacement. The help map
contains only the four periodic metrics.

- [ ] **Step 3: Package the source and define distinct units**

In the Nix module, package the standalone source with a Python interpreter
containing httpx. The scheduled unit executes the script with no arguments.
The manual unit executes it with `--app-check`.

Both units retain `DynamicUser`, hard timeouts, network-family restrictions,
and the existing system-call hardening. Only the scheduled service receives
write access to the node-exporter textfile directory. Define:

```nix
systemd.services.drafts-mcp-app-check = {
  description = "Manual Drafts MCP app/TCC check (contacts Drafts.app on hera and may reveal it)";
  after = [ "drafts-mcp.service" "network-online.target" ];
  wants = [ "network-online.target" ];
  serviceConfig = probeHardening // {
    ExecStart = "${healthScript} --app-check";
  };
};
```

Do not add `wantedBy` or any timer for this unit. Keep
`drafts-mcp-check.timer` pointed only at `drafts-mcp-check.service`.

- [ ] **Step 4: Run the focused check and verify GREEN**

Run:

```sh
nix build -L path:.#checks.aarch64-linux.drafts-mcp-check-tests
```

Expected: all focused tests pass.

- [ ] **Step 5: Evaluate systemd wiring**

Run:

```sh
nix eval --raw path:.#nixosConfigurations.vulcan.config.systemd.services.drafts-mcp-check.serviceConfig.ExecStart
nix eval --raw path:.#nixosConfigurations.vulcan.config.systemd.services.drafts-mcp-app-check.serviceConfig.ExecStart
nix eval --raw path:.#nixosConfigurations.vulcan.config.systemd.timers.drafts-mcp-check.timerConfig.Unit
```

Expected: scheduled ExecStart has no `--app-check`; manual ExecStart has it;
the sole timer target is `drafts-mcp-check.service`.

### Task 3: Align Alerts and Self-healing with Transport Evidence

**Files:**
- Modify: `modules/monitoring/alerts/drafts.yaml`
- Modify: `modules/services/drafts-mcp-self-heal.nix`
- Modify: `modules/services/alertmanager.nix`
- Test: `scripts/drafts-mcp-check/tests/test_drafts_mcp_check.py`

**Interfaces:**
- Removes periodic contracts `drafts_mcp_e2e_ok`,
  `drafts_mcp_tcc_automation_ok`, `DraftsMcpAskFailing`, and
  `DraftsMcpTccAutomationLost`.
- Adds alert `DraftsMcpTransportFailing`.
- Changes `HEALABLE` to
  `{"DraftsMcpBridgeDown", "DraftsMcpTransportFailing"}`.

- [ ] **Step 1: Add a Nix wiring-and-rules check and verify RED**

Add `drafts-mcp-probe-wiring` to `checks.${system}`. It obtains the
evaluated Vulcan service and timer definitions and asserts:

- scheduled ExecStart does not contain `--app-check`;
- manual ExecStart does contain `--app-check`;
- the timer target is exactly `drafts-mcp-check.service`;
- the manual unit has no `wantedBy`;
- no timer named `drafts-mcp-app-check` exists.

The derivation must include `pkgs.prometheus` and run
`promtool check rules` on `modules/monitoring/alerts/drafts.yaml`. It must
also grep the active alert, self-heal, and Alertmanager source files for the
new transport contract and reject the two removed metric and alert names.

Run:

```sh
nix build -L path:.#checks.aarch64-linux.drafts-mcp-probe-wiring
```

Expected: FAIL because the old configuration has no manual unit and still
contains the app-level metrics and alerts.

- [ ] **Step 2: Replace the app-level alerts**

Keep `DraftsMcpBridgeDown`. Replace `DraftsMcpAskFailing` with
`DraftsMcpTransportFailing`, using:

```yaml
expr: drafts_mcp_sse_open_ok == 1 and drafts_mcp_ssh_hera_ok == 0
```

Its annotations must state that SSE opens but the SSH child, Hera forced
command, or MCP server did not complete `tools/list`; they must not claim a
Drafts tool or AppleEvent was tested. Remove
`DraftsMcpTccAutomationLost` entirely.

- [ ] **Step 3: Update self-healing and routing documentation**

Change the self-heal allowlist and comments from `DraftsMcpAskFailing` to
`DraftsMcpTransportFailing`. Remove the obsolete Alertmanager TCC comment.
Do not change the remediation command or routing labels.

- [ ] **Step 4: Verify rule syntax, wiring, and focused tests**

Run:

```sh
nix build -L path:.#checks.aarch64-linux.drafts-mcp-check-tests
nix build -L path:.#checks.aarch64-linux.drafts-mcp-probe-wiring
```

Expected: focused tests pass; the wiring check evaluates the two units and
sole timer successfully; and its packaged promtool reports one valid rule
file. No ad-hoc package environment or dependency installation is permitted.

### Task 4: Full Repository Verification and Commit

**Files:**
- All Task 1-3 files.
- Update: `docs/superpowers/specs/2026-07-21-noninvasive-drafts-mcp-probe-design.md` only if implementation reveals a factual correction.

- [ ] **Step 1: Format and inspect**

Run:

```sh
nix fmt
git diff --check
git diff --stat
rg -n 'drafts_mcp_(e2e|tcc_automation)_ok|DraftsMcp(AskFailing|TccAutomationLost)' modules scripts flake.nix
```

Expected: formatting succeeds, the diff is clean, and the final search has no
active configuration hit.

- [ ] **Step 2: Run the authoritative repository gate**

Run:

```sh
nix flake check -L path:.
nix build -L path:.#nixosConfigurations.vulcan.config.system.build.toplevel
```

Expected: all flake checks and the complete Vulcan system build pass.

- [ ] **Step 3: Recheck Anvil state and commit one coherent unit**

Confirm the dedicated Anvil daemon has no modified file buffers, inspect
structured git status/diff, stage only the implementation files, and commit:

```sh
git commit -m "fix: make Drafts health probe non-invasive"
```

- [ ] **Step 4: Run an independent fess audit**

Give the reviewer the approved design, this plan, the exact diff, test output,
and generated systemd wiring. Verify every finding; amend real fixes into a
separate fess-fix commit and do not re-audit that pure fix commit.

### Task 5: Switch Vulcan and Prove Drafts Stays Hidden

**Files:** No additional source files unless live evidence exposes a tested bug.

- [ ] **Step 1: Verify the live deployment source**

Read Vulcan's `/etc/nixos` branch, HEAD, status, flake output, and relationship
to the local implementation commit. Do not overwrite dirty or divergent work.

- [ ] **Step 2: Acquire the build lock**

If `/etc/nixos/.nixos-build` exists, wait in ten-second increments for at
most ten minutes. If it remains, stop and ask the user. Otherwise create it
with `sudo touch /etc/nixos/.nixos-build` immediately before build/switch.

- [ ] **Step 3: Build and switch**

Make the implementation commit available to Vulcan's live checkout without a
force push or destructive reset, then run its repository-native equivalent of:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#vulcan
```

Remove `/etc/nixos/.nixos-build` after success or failure and record the
generation and exit status.

- [ ] **Step 4: Verify the deployed units and metrics**

Confirm:

- `drafts-mcp-check.timer` is active with a 300-second cadence;
- no timer references `drafts-mcp-app-check.service`;
- the scheduled ExecStart omits `--app-check`;
- the manual ExecStart includes `--app-check`;
- a manually started scheduled probe writes exactly the four transport metrics;
- the current textfile contains neither removed metric.

- [ ] **Step 5: Verify no scheduled GUI side effect**

Hide Drafts on Hera. Record a bounded baseline of Drafts reopen AppleEvents,
`osascript` children, and relevant visibility assertions. Start
`drafts-mcp-check.service` once and also observe the next timer invocation.
For both probes, correlate Vulcan timestamps with Hera logs and require zero
`tools/call`, zero `osascript`, zero Drafts reopen event, and no reveal.

- [ ] **Step 6: Verify the explicit manual diagnostic**

Start `drafts-mcp-app-check.service` once. Confirm the Vulcan journal reports
the read-only workspace check result and Hera shows the expected single
intentional app interaction. Hide Drafts afterward. Confirm the next scheduled
probe again produces no interaction.

### Task 6: Wiggum Closeout for This Work Unit

**Files:**
- Update the active umbrella handoff with commit ids, gate output, Vulcan
  generation, metric set, and correlated Hera proof.

- [ ] **Step 1: Drain partner observations**

Inspect direct non-hidden `doc/observations/*.md` in the NixOS repository. If
present, run partner cleanup and verify its commit.

- [ ] **Step 2: Run final independent review**

Provide the complete implementation and deployment evidence to a fresh
reviewer. Fix every Critical or Important finding and re-run affected gates.

- [ ] **Step 3: Verify branch currency locally**

Fetch `origin` and prove the implementation branch is based on current
`origin/main`. If a rebase changes the deployed commit id, repeat the Vulcan
switch and live no-reveal proof. Do not push or force-push.

- [ ] **Step 4: Resume the umbrella goal**

After the Drafts work unit is proved, resume the existing
flatten-recordings LiteLLM route, queue drain, and `update-agents` tasks.
