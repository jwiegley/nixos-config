# Unified Agent Health Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two divergent nightly-report scripts with one shared engine (`agent_health_report.py`) driven by per-agent profiles, so the OpenClaw and Hermes emails render the same 11-section union, each section probed for real where a signal exists.

**Architecture:** A single Python file holds generic helpers + 11 section renderers + a `PROFILES` table (one dict per agent) + `collect`/`render`/`main`. The binary is invoked `agent-health-report --agent {openclaw|hermes}`. Both NixOS modules build the same file and pass the flag, keeping their existing env/sandbox/timer. Old scripts and their two test dirs are deleted; one consolidated test dir replaces them.

**Tech Stack:** Python 3 stdlib only (argparse, urllib, subprocess, re, json, pathlib, collections, datetime, tempfile); `pkgs.writers.writePython3Bin`; `helpers.mkPytestCheck` flake check; systemd timers; postfix sendmail.

**Spec:** `docs/superpowers/specs/2026-06-01-unified-agent-health-report-design.md`

**Source-of-truth references for ported code:**
- `scripts/openclaw-nightly-report.py` — `_parse_mcporter_output`, `run_mcporter_list`, `run_mcporter_list_via_ssh`, `microvm_uptime`, `recent_errors`+`_BENIGN_WARNING_PATTERNS`+`_is_benign_warning`+`_TS_RE`, `_ok`, `_fmt_uptime`, `_build_message`, `deliver`, the MCP-table renderer, the HA-textfile renderer.
- `scripts/hermes-nightly-report.py` — `redact`+`REDACT_PATTERNS`, `parse_textfile`, `GATEWAY_TS_RE`+`EVENT_KEYWORDS`+`_iter_gateway_events`+`parse_gateway_log`+`most_recent_per_type`, `ERRORS_TS_RE`+`parse_errors_log`, `parse_incidents`, `prometheus_query`, `smoke_summary_24h`, `systemd_uptime`, `in_vm_probe`, headline-verdict logic, `_build_message`, `deliver`.

---

## File Structure

- **Create** `scripts/agent_health_report.py` — the engine + profiles + main (one responsibility: render an agent health email from its profile).
- **Create** `scripts/agent-health-report-tests/conftest.py` — imports the module.
- **Create** `scripts/agent-health-report-tests/test_*.py` — ported + new tests.
- **Create** `scripts/agent-health-report-tests/fixtures/` — copy reusable fixtures from the two old `*-tests/fixtures` dirs.
- **Modify** `modules/services/openclaw-nightly-report.nix` — ExecStart `--agent openclaw`; add `OPENCLAW_REPORT_PROMETHEUS_URL`; add `/var/lib/openclaw-self-heal` to `ReadOnlyPaths`; union `flakeIgnore`.
- **Modify** `modules/services/hermes-nightly-report.nix` — ExecStart `--agent hermes`; union `flakeIgnore`.
- **Modify** `flake.nix:273-283` — replace the two `*-nightly-report-tests` checks with one `agent-health-report-tests`.
- **Delete** `scripts/openclaw-nightly-report.py`, `scripts/hermes-nightly-report.py`, `scripts/openclaw-nightly-report-tests/`, `scripts/hermes-nightly-report-tests/`.

### The two profiles (authoritative — implement exactly)

```python
TF = "/var/lib/prometheus-node-exporter-textfiles"

PROFILES = {
  "openclaw": {
    "agent": "openclaw", "display_name": "OpenClaw",
    "env_prefix": "OPENCLAW_REPORT", "report_header": "X-Openclaw-Report",
    "default_from": "openclaw-health@vulcan.lan",
    "live_textfiles": [f"{TF}/openclaw_mcporter.prom", f"{TF}/openclaw_canary.prom"],
    "expected_servers": (  # fallback if textfile server_ok keys empty; live keys still merged
        "email-contacts","google-calendar-personal","google-calendar-work",
        "home-assistant","searxng","stock-trader","vane"),
    "mcporter_struct_textfile": f"{TF}/openclaw_mcporter.prom",
    "server_ok_metric": "openclaw_mcporter_server_ok",   # has {name="..."} label
    "mcporter_live": "host+ssh",
    "host_blind_servers": frozenset({"google-calendar-personal","google-calendar-work","home-assistant"}),
    "gateway": {"ready_age":"openclaw_gateway_ready_age_seconds",
                "ready_ts":"openclaw_gateway_ready_timestamp_seconds",
                "plugins_total":"openclaw_gateway_ready_plugins_total",
                "channels":"openclaw_channel_plugin_loaded",
                "init_fails":"openclaw_plugin_init_failures_recent_total"},
    "units": ["microvm@openclaw.service","openclaw-self-heal.service"],
    "probe_families": [{"label":"OpenClaw→Hermes bridge smoke",
                        "ok":"openclaw_hermes_smoke_ok",
                        "dur":"openclaw_hermes_smoke_duration_seconds"}],
    "discord": {"mode":"metrics",
                "connected":"openclaw_discord_ws_connected",
                "last_ready_age":"openclaw_discord_ws_last_ready_age_seconds"},
    "ha_mcp": {"mode":"textfile",
               "token":"openclaw_mcporter_ha_token_present",
               "reachable":"openclaw_mcporter_ha_endpoint_reachable",
               "auth":"openclaw_mcporter_ha_auth_ok",
               "last_run":"openclaw_mcporter_check_last_run_timestamp_seconds"},
    "errors_log": "/var/lib/openclaw/.openclaw/logs/gateway-vm.err.log",
    "errors_grammar": "openclaw",     # selects _TS_RE + benign filtering + dedup munging
    "incidents_json": "/var/lib/openclaw-self-heal/incidents.json",
    "selfheal_textfile": f"{TF}/openclaw_self_heal.prom",
    "selfheal_metric_prefix": "openclaw_self_heal",
    "invm_checks": [
        {"label":"trader /api/schwab/status","kind":"curl",
         "url":"https://trader.vulcan.lan/api/schwab/status"},
        {"label":"trader requests-TLS","kind":"requests_tls",
         "url":"https://trader.vulcan.lan/api/schwab/status"}],
    "verdict_fail_if_zero": [("openclaw_mcporter_ha_auth_ok","HA auth failing")],
    "errors_fail_threshold": 20,
  },
  "hermes": {
    "agent": "hermes", "display_name": "Hermes",
    "env_prefix": "HERMES_REPORT", "report_header": "X-Hermes-Report",
    "default_from": "hermes-health@vulcan.lan",
    "live_textfiles": [f"{TF}/hermes_health.prom", f"{TF}/hermes_e2e_chat.prom",
                       f"{TF}/hermes_self_heal.prom"],
    "expected_servers": (  # service-parity set; CONFIRM names vs VM mcporter.json in Task 1
        "vane","home-assistant","stock-trader","email-contacts",
        "perplexity","org-db","searxng"),
    "mcporter_struct_textfile": None,    # struct column renders "—"
    "server_ok_metric": None,
    "mcporter_live": "ssh",
    "host_blind_servers": frozenset(),   # everything via the VM probe
    "gateway": None,                      # → n/a section (no plugin gateway)
    "units": ["microvm@hermes.service","hermes-mcp.service","hermes-self-heal.service"],
    "probe_families": [{"label":"Hermes e2e chat",
                        "ok":"hermes_e2e_chat_ok","dur":"hermes_e2e_chat_duration_seconds"},
                       {"label":"OpenClaw→Hermes bridge smoke",
                        "ok":"openclaw_hermes_smoke_ok",
                        "dur":"openclaw_hermes_smoke_duration_seconds"}],
    "discord": {"mode":"log",
                "log":"/var/lib/hermes/.hermes/logs/gateway.log",
                "heartbeat_age_metric":"hermes_discord_heartbeat_age_seconds"},
    "ha_mcp": {"mode":"mcporter_row","server":"home-assistant"},
    "errors_log": "/var/lib/hermes/.hermes/logs/errors.log",
    "errors_grammar": "hermes",          # ERRORS_TS_RE (ERROR|WARN), redact, no benign set yet
    "incidents_json": "/var/lib/hermes-self-heal/incidents.json",
    "selfheal_textfile": f"{TF}/hermes_self_heal.prom",
    "selfheal_metric_prefix": "hermes_self_heal",
    "invm_checks": [
        {"label":"/v1/capabilities","kind":"curl","url":"http://localhost:8080/v1/capabilities"},
        {"label":"trader /api/schwab/status","kind":"curl",
         "url":"https://trader.vulcan.lan/api/schwab/status"},
        {"label":"trader requests-TLS","kind":"requests_tls",
         "url":"https://trader.vulcan.lan/api/schwab/status"}],
    "verdict_fail_if_zero": [("hermes_api_server_ok","api_server down"),
                             ("hermes_mcp_sse_open_ok","hermes-mcp SSE down"),
                             ("hermes_mcp_ask_hermes_ok","ask_hermes round-trip failing")],
    "errors_fail_threshold": 50,
  },
}
```

Both reports redact AND benign-filter. Redaction is unconditional (both grammars). The benign set is the existing OpenClaw `_BENIGN_WARNING_PATTERNS` for the `openclaw` grammar and an empty list for `hermes` (a profile-overridable field, left empty now per spec §5 item 8).

---

## Task 1: Scaffold module + profiles + test harness

**Files:**
- Create: `scripts/agent_health_report.py`
- Create: `scripts/agent-health-report-tests/conftest.py`
- Test: `scripts/agent-health-report-tests/test_profiles.py`

- [ ] **Step 1: Confirm Hermes server names.** Before hardcoding `expected_servers`, read the VM's mcporter config: `sudo ssh -i /run/secrets/hermes/probe-ssh-private-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null hermes@10.99.1.2 'cat ~/.mcporter/mcporter.json 2>/dev/null | python3 -c "import sys,json;print(sorted(json.load(sys.stdin).get(\"mcpServers\",{}).keys()))"'`. **SECURITY:** this prints only server *names* (keys), never values. If it fails, keep the parity tuple and note it; the table is dynamic-tolerant anyway.
- [ ] **Step 2: Write `conftest.py`** — `sys.path.insert(0, str(Path(__file__).resolve().parent.parent))`; `import agent_health_report as m` exposed via a `load_report_module()` helper returning `m` (filename has underscores, so a plain import works — no importlib needed).
- [ ] **Step 3: Write the failing test** `test_profiles.py`:

```python
from conftest import load_report_module
m = load_report_module()

REQUIRED = {"agent","display_name","env_prefix","report_header","default_from",
            "live_textfiles","expected_servers","units","probe_families",
            "discord","ha_mcp","errors_log","errors_grammar","incidents_json",
            "selfheal_textfile","invm_checks","verdict_fail_if_zero"}

def test_both_profiles_present():
    assert set(m.PROFILES) == {"openclaw","hermes"}

def test_profiles_have_required_keys():
    for name, p in m.PROFILES.items():
        assert REQUIRED <= set(p), f"{name} missing {REQUIRED - set(p)}"

def test_get_profile_rejects_unknown():
    import pytest
    with pytest.raises(SystemExit):
        m.get_profile("nope")
```

- [ ] **Step 4: Run, expect fail** — `cd scripts/agent-health-report-tests && python -m pytest -q` → ImportError / AttributeError.
- [ ] **Step 5: Implement scaffold** — module docstring (list the 11 sections + env overrides), stdlib imports, the full `PROFILES` dict above, `get_profile(name)` (`SystemExit` on unknown), and a stub `main(argv=None)` using `argparse` with required `--agent`. Add the `TF` constant.
- [ ] **Step 6: Run, expect pass.**
- [ ] **Step 7: Commit** — `feat(monitoring): scaffold unified agent_health_report engine + profiles`.

## Task 2: Generic helpers (port + extend), TDD

**Files:** Modify `scripts/agent_health_report.py`; Test `test_helpers.py`, `test_errors.py`, `test_incidents.py`, `test_prometheus.py`, `test_mcporter.py`.

- [ ] **Step 1: Write failing tests.** Port from old suites and add new:
  - `test_mcporter.py`: copy `openclaw-nightly-report-tests/test_parse_mcporter_output.py` (calls `m._parse_mcporter_output`).
  - `test_incidents.py`: port `hermes-nightly-report-tests/test_parse_incidents.py` (`m.parse_incidents`).
  - `test_prometheus.py`: port `test_prometheus_query.py` (`m.prometheus_query`).
  - `test_errors.py`: port `test_parse_errors_log.py`; adapt to `m.parse_errors_log(path, grammar="hermes", now=...)`. **Add** `test_openclaw_errors_redacted`: a fabricated `gateway-vm.err.log` line containing `Bearer abc123def456...` is redacted to `[REDACTED]` in the returned patterns (regression for the new OpenClaw redaction path).
  - `test_helpers.py`: `test_redact` (Bearer / sk-ant / token= shapes → `[REDACTED]`); `test_parse_prom_textfile` (port `test_parse_textfile.py` → `m.parse_prom_textfile`; handles `{label="x"}` lines by keeping the full `name{...}` as key); `test_parse_prom_textfile_multi` (merges a list of files).
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement helpers** in the module:
  - `redact(s)` + `REDACT_PATTERNS` — verbatim from hermes script.
  - `parse_prom_textfile(path)` and `parse_prom_textfiles(paths)` — generalize hermes `parse_textfile`; `rpartition(" ")` keeps `name{label="v"}` intact as the key.
  - `prometheus_query(promql, base_url)` — from hermes (take `base_url` arg, default from env).
  - `systemd_uptime(unit)` — from hermes (`active/since/n_restarts`).
  - `parse_incidents(path, now)` — verbatim from hermes.
  - `parse_errors_log(path, grammar, now, window_hours=24)` — unify both: pick `_TS_RE`/`ERRORS_TS_RE` + munging + benign set by `grammar`; **always** `redact()` each bucketed line; return `{total, errors_total, warnings_total, patterns, warnings}`.
  - `_BENIGN_WARNING_PATTERNS` + `_is_benign_warning` — from openclaw.
  - `_parse_mcporter_output`, `run_mcporter_list(env...)`, `run_mcporter_list_via_ssh(target,key)` — from openclaw; keep `_find_mcporter`, `_build_ca_bundle`.
  - `ssh_probe(target, key, checks)` — generalize hermes `in_vm_probe`: build one remote shell script from `checks` (`curl` → `%{http_code}`; `requests_tls` → the existing python verify snippet), parse `label=value` lines, return `{"skipped":bool,"reason":..., results:{label:value}}`. Use the converged ssh options (spec §6).
  - `_ok`, `_fmt_uptime`, `_build_message(subject,body,sender,recipient,header_tag)`, `deliver(...)` — from either (identical).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit** — `feat(monitoring): port + unify report helpers (redact both grammars)`.

## Task 3: Discord/gateway log parsing, TDD

**Files:** Modify module; Test `test_gateway_log.py`.

- [ ] **Step 1:** Port `hermes-nightly-report-tests/test_parse_gateway_log.py` → `m.parse_gateway_log` / `m.most_recent_per_type`. Copy fixtures into `fixtures/`.
- [ ] **Step 2:** Run, expect fail.
- [ ] **Step 3:** Port `GATEWAY_TS_RE`, `EVENT_KEYWORDS`, `_iter_gateway_events`, `parse_gateway_log`, `most_recent_per_type` verbatim from hermes (used only by `discord.mode == "log"`).
- [ ] **Step 4:** Run, expect pass.
- [ ] **Step 5: Commit** — `feat(monitoring): port Discord gateway-log parsing into engine`.

## Task 4: `collect(profile)` data gatherer

**Files:** Modify module; Test `test_collect.py`.

- [ ] **Step 1:** Write `test_collect.py`: monkeypatch the helper functions (`m.prometheus_query = lambda *a, **k: 1.0`, `m.systemd_uptime = ...`, `m.run_mcporter_list = ...`, `m.ssh_probe = ...`, point textfile/log/incidents paths at `tmp_path` fixtures via a cloned profile) and assert `collect(profile)` returns a dict with keys `{live, servers, gateway, uptime, probes, discord, ha_mcp, errors, selfheal, invm}` and never raises when every source is missing (returns empty/None sub-values, not exceptions).
- [ ] **Step 2:** Run, expect fail.
- [ ] **Step 3:** Implement `collect(profile)`: read env (`<prefix>_PROMETHEUS_URL`, `_SSH_KEY`, `_SSH_TARGET`, `_MCPORTER`, `_CA_BUNDLE`) once; call each helper guarded so any single failure degrades to `None`/empty; for `mcporter_live`: `host+ssh` merges host list then overlays VM list for `host_blind_servers` (openclaw `main` logic); `ssh`-only runs one VM `mcporter list`. Run `ssh_probe` once and reuse for §7-derive (Hermes ha row) + §10.
- [ ] **Step 4:** Run, expect pass.
- [ ] **Step 5: Commit** — `feat(monitoring): add collect() to gather all section data`.

## Task 5: Section renderers + `render()`, TDD

**Files:** Modify module; Test `test_render.py`.

- [ ] **Step 1: Write failing tests** (structural, over a hand-built `data` dict per agent):
  - `test_render_openclaw_all_headers_in_order` — body contains the 11 section headers in order (`Live metrics`, `MCP servers`, `Gateway`, `microVM`, `24h probe summary`, `Discord activity`, `Home Assistant MCP`, `Errors digest`, `Self-heal incidents`, `In-VM corroboration`). Assert via increasing `.index()`.
  - `test_render_hermes_all_headers_in_order` — same set, same order.
  - `test_render_hermes_gateway_na` — Hermes body has `Gateway` header followed by `n/a — not applicable` and the MCP-server count.
  - `test_render_hermes_gateway_na_count_unavailable` — when `data["servers"]` is empty, the n/a line says `count unavailable`, not `None`.
  - `test_render_headline_fail` — a `data["live"]` with `hermes_api_server_ok=0` yields `Headline: FAIL` and lists `api_server down`.
  - `test_render_redacts` — an errors-digest pattern containing a Bearer token comes out `[REDACTED]`.
  - Port `hermes-nightly-report-tests/test_render_report.py` adapted to `subject, body = m.render(profile, data)`.
- [ ] **Step 2:** Run, expect fail.
- [ ] **Step 3: Implement** the 11 `render_*(profile, data) -> list[str]` helpers + a `_na(reason, kind="unavailable")` helper (`f"  n/a — {kind} ({reason})"`), and `render(profile, data) -> (subject, body)`:
  - Header line `f"{display} health report — {host} — {iso}"`, `=`*76.
  - Headline: compute `issues` from `verdict_fail_if_zero` over `data["live"]`, microvm-not-active, stuck incidents, `errors_total > errors_fail_threshold`, trader/invm failed, any struct-invalid server. `verdict = FAIL if issues else PASS`; `summary = issues[0] if issues else "all healthy"`. Subject `f"[{agent}-nightly] {host} {date} - {summary}"` (ASCII hyphen).
  - `render_mcp_servers`: openclaw table logic (struct/live/blind handling) generalized; Hermes struct col `—`.
  - `render_gateway`: if `profile["gateway"]` is None → `_na("NousResearch agent has no plugin gateway; " + (f"{n} MCP servers loaded" if n is not None else "MCP server count unavailable"), kind="not applicable")`.
  - `render_ha_mcp`: `textfile` mode = openclaw 3-line + last-check age; `mcporter_row` mode = derive from `data["servers"]["home-assistant"]` (present & tool_count>0 → `bearer accepted: OK (via in-VM mcporter, N tools)`), else `_na`.
  - `render_selfheal`: incidents (active/resolved/stuck) + attempts-by-action + heartbeat age from the `selfheal_*` gauges in `data["live_selfheal"]`.
  - `render_invm`: skipped → one `_na`; else one line per check result.
  - Footer `--` + `Sent by agent-health-report.service (--agent {agent})`.
- [ ] **Step 4:** Run, expect pass.
- [ ] **Step 5: Commit** — `feat(monitoring): add 11 section renderers + unified render()`.

## Task 6: `main()` + delivery, TDD

**Files:** Modify module; Test `test_main_dry_run.py`.

- [ ] **Step 1:** Port `test_main_dry_run.py` for BOTH agents: monkeypatch `collect` to return a minimal valid `data`, set `<prefix>_DRY_RUN=1`, capture stdout, assert it starts with `Subject: [openclaw-nightly]` / `[hermes-nightly]` and contains all 11 headers. (Dry-run must make zero network/subprocess calls — assert by monkeypatching `collect`.)
- [ ] **Step 2:** Run, expect fail.
- [ ] **Step 3:** Implement `main(argv)`: parse `--agent`; `p = get_profile(args.agent)`; read `<prefix>_{TO,FROM,SENDMAIL,DRY_RUN}` env **inside main** (`prefix = p["env_prefix"]`); `data = collect(p)`; `subject, body = render(p, data)`; `deliver(subject, body, sender, recipient, sendmail, header_tag, dry_run)`. `if __name__ == "__main__": sys.exit(main())`. **IMPORTANT — do NOT replicate the old module-level globals.** The ported `deliver`/`_build_message` must take `sender/recipient/sendmail/header_tag/dry_run` as **arguments**; there must be no `DRY_RUN = bool(os.getenv(...))` / `SENDER = ...` / `RECIPIENT = ...` at module scope (those were per-agent in the old scripts and would ignore `--agent`). All env reads are prefix-scoped and happen at call time.
- [ ] **Step 4:** Run, expect pass; then run the WHOLE suite `python -m pytest -q` — all green.
- [ ] **Step 5: Commit** — `feat(monitoring): wire main() + delivery for both agents`.

## Task 7: NixOS wiring + delete old scripts

**Files:** Modify two `*.nix` + `flake.nix`; delete old scripts + test dirs.

- [ ] **Step 1:** Edit `modules/services/openclaw-nightly-report.nix`: `reportScript` reads `../../scripts/agent_health_report.py`; `flakeIgnore` = union of both sets (add `E241`, `E226`, `W503`); `ExecStart = "${reportScript}/bin/agent-health-report --agent openclaw"` (the `writePython3Bin` name becomes `agent-health-report`); add `OPENCLAW_REPORT_PROMETHEUS_URL = "http://127.0.0.1:9090"`; add `"/var/lib/openclaw-self-heal"` to `ReadOnlyPaths`.
- [ ] **Step 2:** Edit `modules/services/hermes-nightly-report.nix`: read `../../scripts/agent_health_report.py`; `ExecStart = "...--agent hermes"`; `flakeIgnore` union. (ReadOnlyPaths already has hermes-self-heal.)
- [ ] **Step 3:** Edit `flake.nix:273-283`: delete the two `*-nightly-report-tests` checks; add one `agent-health-report-tests = helpers.mkPytestCheck { name = "agent-health-report-tests"; src = ./scripts; suiteDir = "agent-health-report-tests"; };`.
- [ ] **Step 4:** `git rm scripts/openclaw-nightly-report.py scripts/hermes-nightly-report.py` and `git rm -r scripts/openclaw-nightly-report-tests scripts/hermes-nightly-report-tests`.
- [ ] **Step 5: Commit** — `refactor(monitoring): build both nightly reports from the shared engine; drop old scripts`.

## Task 8: Validate

- [ ] **Step 1:** `cd /etc/nixos && nix fmt -- .` (format the .nix edits; bare `nix fmt` fails on this host).
- [ ] **Step 2:** `sudo nixos-rebuild build --flake '.#vulcan' --show-trace` → clean build.
- [ ] **Step 3:** `nix build .#checks.aarch64-linux.agent-health-report-tests -L` → pytest green. (Also confirm the two old checks no longer evaluate.)
- [ ] **Step 4:** If anything fails, fix and re-commit (`fix(monitoring): …`).

## Task 9: Deploy + sample (handoff to verification)

- [ ] **Step 1:** `sudo nixos-rebuild switch --flake '.#vulcan'`.
- [ ] **Step 2:** Capture dry-run renders (full data, no email): run the built binary as root with `<prefix>_DRY_RUN=1` and the real SSH key env so the in-VM probe runs. The SOPS secret `<agent>/probe-ssh-private-key` deploys to `/run/secrets/<agent>/probe-ssh-private-key` (mode `0400 root:root`, readable under `sudo`) — pin both exact paths:
  - OpenClaw: `sudo OPENCLAW_REPORT_DRY_RUN=1 OPENCLAW_REPORT_SSH_KEY=/run/secrets/openclaw/probe-ssh-private-key OPENCLAW_REPORT_SSH_TARGET=openclaw@10.99.0.2 OPENCLAW_REPORT_PROMETHEUS_URL=http://127.0.0.1:9090 <store-bin> --agent openclaw`
  - Hermes: `sudo HERMES_REPORT_DRY_RUN=1 HERMES_REPORT_SSH_KEY=/run/secrets/hermes/probe-ssh-private-key HERMES_REPORT_SSH_TARGET=hermes@10.99.1.2 HERMES_REPORT_PROMETHEUS_URL=http://127.0.0.1:9090 <store-bin> --agent hermes`
  - First `stat` each key path to confirm it exists; if absent the probe degrades to `n/a — unavailable` (not a failure). **SECURITY:** review output for secrets before pasting; the digest is redacted but eyeball it.
- [ ] **Step 3:** Send the real pair: `sudo systemctl start openclaw-nightly-report.service hermes-nightly-report.service`; confirm delivery via `journalctl -u …` (summary lines only) and that two mails reached `johnw@vulcan.lan`.
- [ ] **Step 4:** Save a project memory (`project_unified_agent_health_report`) + update `MEMORY.md`.

---

## Notes for the executor
- **Security (CLAUDE.md PRIMARY LENS):** never `cat` logs/secrets to the conversation; the error digest is redacted in-engine, but still eyeball any sample output. The Hermes-server-name probe in Task 1 prints keys only. No `sops -d`.
- **DRY/YAGNI:** one renderer per section; no per-agent branching outside the profile + the two genuine mode-switches (`discord.mode`, `ha_mcp.mode`, `gateway is None`).
- **TDD:** test-first for every pure function and the renderer; `collect`/`main` are covered via monkeypatched dry-run.
- **Commit cadence:** one commit per task (frequent, atomic).
- Reference: @superpowers:executing-plans for the batch-with-checkpoints flow.
