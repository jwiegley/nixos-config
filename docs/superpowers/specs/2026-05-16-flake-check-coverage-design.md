# Flake-check Coverage: Schema Drift + Pytest — Design Spec

> **Archival — 2026-05-16.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `tests/openclaw/check-schema.nix`, `tests/openclaw/expected-keys.txt`).

Two related improvements to the regression-catch story for the OpenClaw ↔ Hermes integration. Bundled into one spec because both are about strengthening `nix flake check` so a `nixos-rebuild` catches problems before they ship.

## Why

1. **No automated regression catch for the openclaw.json structural template.** If a future edit to `modules/services/openclaw-config.nix` accidentally drops a key (say, by deleting a `meta.lastTouchedAt` line), the template still produces valid JSON and the build still succeeds — the regression only surfaces when openclaw mid-flight notices the missing key, possibly hours later. We want the build to fail at `nix flake check` time.
2. **No automated regression catch for upstream openclaw schema additions.** When the openclaw nixpkgs input bumps and the new openclaw version adds a config key the Nix template doesn't model, the rendered config silently lacks that key. The merge-into-staging still works; only behavior subtly diverges from upstream's default. We need a way to detect this *in production*, where the live openclaw.json reflects whatever the running openclaw expected.
3. **Three pytest suites run only when humans remember.** `scripts/openclaw-self-heal/tests/`, `scripts/openclaw-hermes-smoke-tests/`, and `scripts/openclaw-nightly-report-tests/` each have working pytest suites, but none are tied into `nix flake check`. A regression in any of them passes review and only fails when someone manually re-runs pytest in nix-shell.

## Deliverable A: snapshot flake check on `pkgs.openclaw-config-template`

### Scope

A `checks.<system>.openclaw-config-schema` derivation that:

1. Realises `pkgs.openclaw-config-template` (already produced by the existing overlay in `modules/services/openclaw-config.nix`).
2. Extracts the sorted dot-notation key set via `jq -r 'paths | map(tostring) | join(".")' | sort`.
3. Diffs the result against a committed snapshot at `tests/openclaw-expected-keys.txt`.
4. Fails the check with a clear "added: X / removed: Y" message if there's any difference.

This catches both: (a) accidental key removal from the Nix template (template breaks, build fails) and (b) accidental key addition during template authoring (build fails, expected-keys.txt update forces a deliberate decision).

### Updating the snapshot

When a deliberate template change adds or removes a key, the workflow is:

```bash
# NOTE: the template is overlay-injected into the host's pkgs set from inside
# a NixOS module, NOT via /etc/nixos/overlays/. Plain `nix build .#openclaw-config-template`
# will NOT resolve — only the `nixosConfigurations.vulcan.pkgs.<attr>` form works.
TPL=$(nix build --no-link --print-out-paths '/etc/nixos#nixosConfigurations.vulcan.pkgs.openclaw-config-template')
jq -r 'paths | map(tostring) | join(".")' "$TPL" | sort > tests/openclaw/expected-keys.txt
git add tests/openclaw/expected-keys.txt
git commit -m "chore(openclaw): update expected schema keys for <reason>"
```

The check failure message will include this exact regeneration recipe so an operator doesn't have to look it up.

The committed snapshot lives at `/etc/nixos/tests/openclaw/expected-keys.txt` — a **new top-level `tests/` directory** for repo-wide flake-check fixtures. This is the first such fixture; future flake checks for other services may add siblings (e.g. `tests/hermes-mcp/...`).

### What it doesn't catch

- Value-level changes (only key presence is tracked).
- Array-length changes (the dotted path strips array indices).
- Type changes (`string` → `int`) at the same key path.

These are all acceptable losses: structural shape is what regressions touch, value/type drift is rare and would surface in the runtime drift detector (Deliverable B).

## Deliverable B: production schema-drift detector

### Scope

A new monitoring service that compares the live openclaw.json (inside the guest VM) against the in-store template, emits a Prometheus textfile metric, and is consumed by an existing alert rule pattern.

#### Service: `openclaw-config-drift-check`

- Runs as `oneshot` on a daily timer (`OnCalendar = "*-*-* 04:00:00"` with `RandomizedDelaySec = "20m"`).
- Runs as `User=openclaw-heal`. **This is the first time openclaw-heal acquires SSH access** (not a reuse — the user previously only used sudo to escalate for local systemctl actions). Wire the existing `sops.secrets."openclaw/probe-ssh-private-key"` (already declared and used by `openclaw-nightly-report.service`) into this unit via `LoadCredential = "probe-ssh-key:${config.sops.secrets."openclaw/probe-ssh-private-key".path}"`. The SOPS secret keeps its current `root:root 0400` ownership; LoadCredential resolves the read-time access for systemd unit consumption without granting the openclaw-heal user direct read on `/run/secrets/openclaw/probe-ssh-private-key`.
- Reads the live openclaw.json from the guest VM via the openclaw-probe SSH key, **pre-stripping secret-named keys** through the canonical secret regex so no credential bytes ever cross the SSH pipe.
- The canonical secret regex is currently inlined in three other places (`openclaw-nix-config` spec, `openclaw_hermes_smoke.py`, `scripts/openclaw-nightly-report.py`). This service makes the fourth. The pattern is `([Aa]pi[Kk]ey|[Tt]oken|[Pp]assword|[Pp]assphrase|[Ss]ecret|[Ss]ecretKey|[Pp]sk|[Bb]earer)`. **Inline it in this service too**; extracting to a shared aux file is a separate refactor and not blocking.
- Reads the in-store template path from the rendered prepare-secrets unit (the same grep pattern Task 7 of the openclaw-nix-config plan used).
- Computes two integer counts: keys-in-live-not-in-template (`added`) and keys-in-template-not-in-live (`removed`).
- Writes `/var/lib/prometheus-node-exporter-textfiles/openclaw_config_drift.prom` with three metrics:
  - `openclaw_config_drift_keys_added` (gauge, int)
  - `openclaw_config_drift_keys_removed` (gauge, int)
  - `openclaw_config_drift_last_run_timestamp_seconds` (gauge, float unix)
- **Never emits the differing keys themselves** — only counts. Keys could contain hints about internal structure that we don't need to publish to Prometheus.
- Hardened with `User=openclaw-heal` (reusing the self-heal user, which already has SSH access patterns), `ProtectSystem=strict`, `RuntimeMaxSec=120s`.

#### Alert: `OpenClawConfigDrift`

- Severity: `warning`
- Expression: `openclaw_config_drift_keys_added > 0 or openclaw_config_drift_keys_removed > 0` for 24h
- The 24-hour window prevents an alert during the operator's deliberate template-update window.
- Annotations include a pointer to the runbook entry on how to investigate (which is just "fetch live config, diff against template, decide whether to update template or `expected-keys.txt`").

#### Failure mode

If the drift-check timer or service fails repeatedly, the daily cadence + systemd's standard `unit failed` alerting catches it. We do NOT add a `restart_drift_check` action to the self-heal daemon — daily cadence + transient-failure self-correction makes that unnecessary.

### What it doesn't catch

- Same as Deliverable A's value-level / type-level limitations.
- A complete openclaw guest VM outage. **Handled by emitting a companion `openclaw_config_drift_probe_up` gauge (`1` = SSH probe succeeded; `0` = probe failed)** rather than poisoning the `added`/`removed` gauges with sentinel values. On probe failure the `added`/`removed` gauges are simply not refreshed (their last-known values stay until the next successful run). The alert rule uses `openclaw_config_drift_probe_up == 1 and (openclaw_config_drift_keys_added > 0 or ...)` to avoid spurious alerts when the VM is reachable but the previous successful probe found drift. The companion gauge also gives the dashboard a clean "probe healthy" signal.

## Deliverable C: Nix-wired pytest checks

### Pre-requisite gate (must precede C's wiring)

`scripts/openclaw-self-heal/tests/test_daemon.py::test_allowlist_is_exactly_the_authorized_actions` currently **fails** — the audit work in commit `19d2b10` added `restart_canary` and `restart_mcporter_check` to `ACTION_ALLOWLIST` but didn't update the test. C's wiring would have `nix flake check` fail on day one for an unrelated reason. The plan's first step under C must update this assertion to match the current 6-tuple. Empirically verified: `1 failed, 24 passed` today.

### Scope

Three new `checks.<system>` entries in `flake.nix`, one per test suite:

| Check name | Suite location | Dependencies |
|---|---|---|
| `openclaw-self-heal-tests` | `scripts/openclaw-self-heal/tests/` | `python3`, `pytest` |
| `openclaw-hermes-smoke-tests` | `scripts/openclaw-hermes-smoke-tests/` | `python3`, `pytest` (stdlib only otherwise) |
| `openclaw-nightly-report-tests` | `scripts/openclaw-nightly-report-tests/` | `python3`, `pytest` |

Each check is a `pkgs.runCommand` derivation that:
1. Copies the relevant scripts directory into the sandbox.
2. Sets `PYTHONPATH` to include it.
3. Invokes `pytest <suite-dir> -v`.
4. Touches `$out` on success; the runCommand fails on non-zero pytest exit.

Per-suite (not bundled) so a failure in one suite doesn't mask state of the others.

### Why this is bounded scope

The smoke-tests suite uses stdlib `http.server` to fake the MCP-SSE server, which works fine in Nix's sandbox (loopback only). The other two suites have similar shapes (unit tests with mocked subprocess calls). No suite needs network egress, the openclaw or hermes microVMs, or any /run/secrets path. All three should run in <10s on aarch64.

### What it doesn't do

- **No new test-runner pattern**. We use plain `pkgs.runCommand` + pytest, not a Nix-derived pytest harness like the buildPythonApplication patterns in nixpkgs. Reason: the scripts are not Python packages; they're loose .py files with pytest tests next to them. Wrapping each in a `buildPythonApplication` would be more invasive than this spec warrants.
- **No coverage reporting**. Add later if useful; not the point of this spec.
- **No parallel test execution**. Per-suite, sequential, fine for our scale.

### Dependencies confirmed minimal

All three suites use stdlib + pytest only — no `anthropic`, `prometheus_client`, `httpx`, or other third-party packages. The runCommand derivation needs `python312` and `python312Packages.pytest` only. If a future test adds a third-party import, the spec for that addition must update this list.

## Cross-deliverable boundary clarification

Deliverable A catches **template-vs-committed-snapshot at build time** (developer-facing — fails `nix flake check` if the template loses a key). Deliverable B catches **live-config-vs-template at runtime** (upstream-drift-facing — emits a metric when production diverges from the template). They share neither code nor failure modes; the overlap is conceptual only.

## Verification — what "done" looks like

1. `nix flake check /etc/nixos 2>&1 | tail -10` runs the four new checks and exits 0.
2. Deliberately removing a key from `modules/services/openclaw-config.nix` (e.g. `meta.lastTouchedAt`) makes `nix flake check` fail with a message including "removed: meta.lastTouchedAt" and the regeneration recipe.
3. Deliberately breaking a smoke-test (e.g. `assert s.HOST == "1.2.3.4"` injected) makes `nix flake check` fail on `openclaw-hermes-smoke-tests`.
4. `cat /var/lib/prometheus-node-exporter-textfiles/openclaw_config_drift.prom` shows three metrics after the first manual run (`sudo systemctl start openclaw-config-drift-check.service`), and the `added`/`removed` counts are both 0 (or `-1` if the guest is unreachable).
5. `systemctl list-timers openclaw-config-drift-check.timer` shows the next scheduled fire.
6. No new failed systemd units.

## Risks

| Risk | Mitigation |
| --- | --- |
| Pytest checks run in Nix sandbox where `127.0.0.1` may not be the loopback the test expects. | The fake-server tests bind to `127.0.0.1:0` (kernel-assigned port). Loopback in Nix sandbox works. Verified empirically by similar patterns elsewhere. |
| Schema-drift detector needs SSH key access from a system service. | Reuse `openclaw-heal` user which already has analogous patterns (it sudoes restart_canary now). Add `/root/.ssh/openclaw-probe` to its `LoadCredential` — wait, that pulls from /root which is mode 600. Use a `sops.secrets.openclaw/probe-ssh-private-key` (already declared per memory note for nightly-report) with appropriate owner. |
| `expected-keys.txt` becomes stale faster than reviewers notice. | The check fails loudly on every nix flake check until it's regenerated. Painful by design. |
| Adding 4 new `nix flake check` derivations slows down `nix flake check` runtime. | Each is small (<10s). Total added: ~30s. Tolerable. If it becomes a problem, add `passthru.tests` selectivity. |

## Out of scope (future sessions)

- Full NixOS VM tests booting the openclaw config end-to-end (much heavier).
- Auto-update of `expected-keys.txt` from CI.
- A flake-check assertion on `hermes-mcp`'s own config schema (analogous pattern but Hermes config is dumb-by-design).
- Pytest coverage reporting / test categorization.
