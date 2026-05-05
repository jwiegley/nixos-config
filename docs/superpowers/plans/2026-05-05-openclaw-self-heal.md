# OpenClaw self-heal — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an always-on, AI-assisted self-healing layer over the OpenClaw microVM on `vulcan` so the Discord bot stays responsive without weekly human babysitting.

**Architecture:** A new long-running Python daemon on the host (`openclaw-self-heal.service`) receives Alertmanager webhooks for `service=openclaw` alerts, runs deterministic remediation on attempt 1, calls `hera/Qwen3.6-27B` via LiteLLM on attempts 2–3 to pick from a 3-action allowlist (`restart_microvm`, `doctor_fix`, `prune_stale_plugin_deps`), and pages a human after attempt 3. Probes that drive the alerts come from extensions to the existing `openclaw-canary` script plus a new blackbox `/health` probe. Reliability scaffolding (auto-doctor in preStart, plugin-deps GC) addresses the upstream-upgrade failure class at the source.

**Tech Stack:** NixOS modules (Nix), Python 3 stdlib (HTTP server via `http.server`, no external deps), Bash for action scripts, Prometheus textfile collector for metrics, LiteLLM (existing) for AI calls, Alertmanager (existing) for routing.

**Spec:** [`docs/superpowers/specs/2026-05-05-openclaw-self-heal-design.md`](../specs/2026-05-05-openclaw-self-heal-design.md)

---

## File map

**Created:**
- `modules/services/openclaw-self-heal.nix` — NixOS module wrapping the daemon, user, sudo rules, ports, hardening
- `scripts/openclaw-self-heal/daemon.py` — webhook listener + state machine + AI client
- `scripts/openclaw-self-heal/actions/restart_microvm` — bash action script (state-changing, in L3 allowlist)
- `scripts/openclaw-self-heal/actions/doctor_fix` — bash action script (state-changing, in L3 allowlist)
- `scripts/openclaw-self-heal/actions/prune_stale_plugin_deps` — bash action script (state-changing, in L3 allowlist)
- `scripts/openclaw-self-heal/aux/read_log_tail` — bash helper, read-only access to the gateway logs (constrained: hardcoded paths, no shell-injection surface). NOT in L3 allowlist; the daemon calls it for context-gathering, the AI never sees it.
- `scripts/openclaw-self-heal/aux/kick_canary` — bash helper that triggers `openclaw-canary.service` to refresh metrics after an action. NOT in L3 allowlist.
- `scripts/openclaw-self-heal/tests/test_daemon.py` — pytest unit tests for the daemon
- `modules/monitoring/services/openclaw-blackbox-probe.nix` — blackbox probe definition (only if not already present)

**Modified:**
- `modules/services/openclaw-vm.nix` — preStart adds (a) auto-`doctor --fix`, (b) stale plugin-deps GC
- `modules/monitoring/services/openclaw-canary.nix` — bare-`ready` regex, `expectedChannels` option, Discord WS probe, drop `acpx` from default
- `modules/monitoring/alerts/openclaw.yaml` — new alerts (`OpenClawDiscordWsDown`, `OpenClawHttpHealthDown`, `OpenClawSelfHealDown`, `OpenClawSelfHealStuck`, `OpenClawSelfHealLitellmUnreachable`); existing alerts get `service: openclaw` label
- `modules/monitoring/services/prometheus-server.nix` *(or wherever Alertmanager route lives)* — add receiver `openclaw-self-heal` and route for `service=openclaw`
- `hosts/vulcan/default.nix` — import `openclaw-self-heal.nix`
- `docs/ports.txt` — reserve port 9092 for the webhook receiver

**Notes for executor:**
- The plan is split into four phases. Each phase ends with `nixos-rebuild build --flake '.#vulcan'` succeeding and a smoke test passing. **Commit at each `- [ ] Step: Commit`** marker.
- TDD where Python is involved (Phase B). For Nix modules and shell scripts, the "test" is `nixos-rebuild build` plus a runtime smoke test after `switch`.
- **Never** decrypt SOPS, never read `/etc/NetworkManager/system-connections/*`, follow CLAUDE.md primary lens. The daemon must redact secrets from prompts (Phase B).

---

## Phase A — Reliability scaffolding (independent of the daemon)

These deliver immediate value: monitoring becomes correct on 2026.5.x, and future openclaw upgrades stop silently breaking Discord.

### Task A1: Canary supports 2026.5.x bare-`ready` line

**Files:**
- Modify: `modules/monitoring/services/openclaw-canary.nix` (the embedded Python script, around the `READY_RE`/`READY_FULL_RE` definitions)

**Why:** 2026.5.x emits `[gateway] ready` without the parenthetical plugin list. The plugin list now appears in `[gateway] http server listening (N plugins: …)`. Without a fallback, plugin-presence gauges flatline at 0.

- [ ] **Step 1: Add fallback regex in canaryScript**

  In the Python heredoc inside `openclaw-canary.nix`, after the existing `READY_FULL_RE` definition, add:

  ```python
  LISTEN_RE = re.compile(
      r"^(?P<ts>\S+)\s+\[gateway\]\s+http\s+server\s+listening\s+"
      r"\((?P<n>\d+)\s+plugin[s]?:\s*(?P<list>[^;)]+)"
  )
  ```

- [ ] **Step 2: Use LISTEN_RE as fallback when READY_FULL_RE doesn't match**

  In `main()`, replace the `if ready_full:` block with:

  ```python
  presence = ready_full or find_last(LISTEN_RE, lines)
  if presence:
      plugin_list = [p.strip() for p in presence["list"].split(",") if p.strip()]
      for c in EXPECTED:
          channel_loaded[c] = 1.0 if c in plugin_list else 0.0
      plugins_total = float(int(presence["n"]))
  ```

  (Drops the now-unused `ready_full` variable name in favor of `presence`.)

- [ ] **Step 3: Build to confirm Nix evaluates**

  ```bash
  sudo nixos-rebuild build --flake '/etc/nixos#vulcan'
  ```

  Expected: builds successfully; new system in `./result/`.

- [ ] **Step 4: Switch and run canary once to verify**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  sudo systemctl start openclaw-canary.service
  cat /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom | grep openclaw_channel_plugin_loaded
  ```

  Expected: discord/whatsapp/lobster/memory-qdrant all show `1.0` (matching the current loaded set).

- [ ] **Step 5: Commit**

  ```bash
  cd /etc/nixos
  git add modules/monitoring/services/openclaw-canary.nix
  git commit -m "fix(openclaw-canary): support 2026.5.x bare [gateway] ready line"
  ```

---

### Task A2: `expectedChannels` becomes a NixOS option; default drops `acpx`

**Files:**
- Modify: `modules/monitoring/services/openclaw-canary.nix` (top of module, where `expectedChannels` is defined)

**Why:** `acpx` is a backend in 2026.5.x, not a channel plugin; it never appears in `http server listening`. Hardcoding the list also makes user adjustment painful.

- [ ] **Step 1: Add `options` block at the top of the module**

  Replace the existing `expectedChannels` `let`-binding with a NixOS option, then read it from `config`:

  ```nix
  { config, lib, pkgs, ... }:
  let
    cfg = config.services.openclawCanary;
    expectedChannels = cfg.expectedChannels;
    textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
    # ... rest unchanged
  in {
    options.services.openclawCanary = {
      expectedChannels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "discord" "whatsapp" "lobster" "memory-qdrant" ];
        description = "Channels/plugins that must be present in the most-recent gateway-ready line. Drop 'acpx' since 2026.5.x makes it a backend, not a plugin.";
      };
    };
    config = {
      systemd.services.openclaw-canary = { ... };  # existing definitions, indented
      systemd.timers.openclaw-canary = { ... };
    };
  }
  ```

- [ ] **Step 2: Build to confirm**

  ```bash
  sudo nixos-rebuild build --flake '/etc/nixos#vulcan'
  ```

  Expected: builds.

- [ ] **Step 3: Switch and verify metrics**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  sudo systemctl start openclaw-canary.service
  grep -c openclaw_channel_plugin_loaded /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom
  ```

  Expected: 4 lines (discord, whatsapp, lobster, memory-qdrant — `acpx` gone).

- [ ] **Step 4: Commit**

  ```bash
  git add modules/monitoring/services/openclaw-canary.nix
  git commit -m "refactor(openclaw-canary): expectedChannels as NixOS option, drop acpx default"
  ```

---

### Task A3: Discord WebSocket state probe in canary

**Files:**
- Modify: `modules/monitoring/services/openclaw-canary.nix` (Python heredoc)

**Why:** The B-floor health signal — without this, the daemon has nothing to alert on for "Discord is connected but gateway thinks it's healthy."

- [ ] **Step 1: Add regexes for Discord WS events**

  Audit of `/var/lib/openclaw/.openclaw/logs/gateway-vm.log` against 2026.5.x found that no `[discord] gateway: ready` line is ever emitted (zero matches across multi-week tail). The actual positive ready signals are `[discord] client initialized as ... awaiting gateway readiness` (2026.5.x), `[discord] logged in to discord as ...` (older 2026.4.x), and `[discord] startup [...] gateway-debug ...ms WebSocket connection opened` (2026.4.x debug). Negative events live in both gateway-vm.log (close, reconnect-scheduled) and gateway-vm.err.log (gateway error, was-not-ready, channel exited), so we scan both. Closed-driven `gateway: Gateway reconnect scheduled in Nms (close|zombie, ...)` is a real disconnect; `(reconnect-opcode, ...)` is a normal Discord lifecycle event and is intentionally NOT matched.

  In the Python heredoc, after `FAIL_RE`, add:

  ```python
  DISCORD_READY_RE = re.compile(
      r"^(?P<ts>\S+)\s+\[discord\]\s+(?:"
      r"client\s+initialized\s+as\s+\S+;\s*awaiting\s+gateway\s+readiness"
      r"|"
      r"logged\s+in\s+to\s+discord\s+as\s+"
      r"|"
      r"startup\s+\[\S+\]\s+gateway-debug\s+\d+ms\s+WebSocket\s+connection\s+opened"
      r")"
  )
  DISCORD_CLOSED_RE = re.compile(
      r"^(?P<ts>\S+)\s+(?:"
      r"\[discord\]\s+(?:"
      r"gateway:\s+Gateway\s+websocket\s+closed:"
      r"|"
      r"gateway\s+error:"
      r"|"
      r"gateway:\s+Gateway\s+reconnect\s+scheduled\s+in\s+\d+ms\s+\((?:close|zombie)"
      r"|"
      r"gateway\s+was\s+not\s+ready\s+after\s+\d+ms"
      r"|"
      r"\[\S+\]\s+channel\s+exited:\s+discord\s+gateway\s+did\s+not\s+reach\s+READY"
      r")"
      r"|"
      r"\[health-monitor\]\s+\[discord:default\]\s+health-monitor:\s+restarting\s+\(reason:\s+disconnected\)"
      r")"
  )
  DISCORD_RECONNECT_GRACE_SEC = 60
  ```

- [ ] **Step 2: Compute `discord_ws_connected` in main()**

  Add after the existing fail_count loop. Discord 2026.5.x emits no log line on a successful silent reconnect, so we apply a 60s reconnect-grace window after the last close: a still-stuck client emits `gateway was not ready after 15000ms` lines every ~15s, which would refresh the negative timestamp; absence of any negative event for 60s therefore signals successful recovery.

  ```python
  d_ready = find_last(DISCORD_READY_RE, lines)
  d_closed_log = find_last(DISCORD_CLOSED_RE, lines)
  d_closed_err = find_last(DISCORD_CLOSED_RE, err_lines)
  d_closed_log_ts = iso_to_epoch(d_closed_log["ts"]) if d_closed_log else 0.0
  d_closed_err_ts = iso_to_epoch(d_closed_err["ts"]) if d_closed_err else 0.0
  d_ready_ts = iso_to_epoch(d_ready["ts"]) if d_ready else 0.0
  d_closed_ts = max(d_closed_log_ts, d_closed_err_ts)
  if d_ready_ts > 0 and d_ready_ts >= d_closed_ts:
      discord_ws_connected = 1.0
  elif (
      d_ready_ts > 0
      and d_closed_ts > 0
      and (now - d_closed_ts) > DISCORD_RECONNECT_GRACE_SEC
  ):
      discord_ws_connected = 1.0
  else:
      discord_ws_connected = 0.0
  discord_ws_last_ready_age = max(0.0, now - d_ready_ts) if d_ready_ts else 0.0
  ```

- [ ] **Step 3: Emit two new metrics in `write_metrics`**

  Add to the f.write block:

  ```python
  f.write(
      "# HELP openclaw_discord_ws_connected 1 if Discord WebSocket is currently connected\n"
      "# TYPE openclaw_discord_ws_connected gauge\n"
      f"openclaw_discord_ws_connected {payload['discord_ws_connected']}\n"
      "# HELP openclaw_discord_ws_last_ready_age_seconds Seconds since the most recent positive Discord ready event (client initialized / logged in / WebSocket connection opened)\n"
      "# TYPE openclaw_discord_ws_last_ready_age_seconds gauge\n"
      f"openclaw_discord_ws_last_ready_age_seconds {payload['discord_ws_last_ready_age']}\n"
  )
  ```

  Pass through the new keys in the `payload` dicts in both `if ready:` branches of `main()`.

- [ ] **Step 4: Build and switch**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  sudo systemctl start openclaw-canary.service
  grep -E 'openclaw_discord_ws' /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom
  ```

  Expected: `openclaw_discord_ws_connected 1.0` and an age in seconds.

- [ ] **Step 5: Commit**

  ```bash
  git add modules/monitoring/services/openclaw-canary.nix
  git commit -m "feat(openclaw-canary): add Discord WebSocket connected gauge"
  ```

---

### Task A4: Blackbox probe of `/health`

**Files:**
- Modify: existing blackbox-exporter scrape config (likely in `modules/monitoring/services/prometheus-server.nix` or a dedicated blackbox module — find it via `grep -rn 'blackbox' modules/monitoring/`)
- Create: `modules/monitoring/services/openclaw-blackbox-probe.nix` only if there is no existing blackbox config to extend

**Why:** Independent probe of `https://openclaw.vulcan.lan/health` so a canary bug can't mask a real outage.

- [ ] **Step 1: Find the blackbox scrape config**

  ```bash
  grep -rn 'blackbox\|prober:\|probe_success' /etc/nixos/modules/monitoring/ | head
  ```

  Expected: identifies a single existing scrape job; we'll add an openclaw target to it. If none exists, create the new module file.

- [ ] **Step 2: Add the openclaw target to that job**

  Add to the `static_configs` of the `blackbox` job:

  ```yaml
  - targets:
      - https://openclaw.vulcan.lan/health
    labels:
      service: openclaw
      probe: openclaw-health
  ```

  Use module `http_2xx` (or whichever probes `200`).

- [ ] **Step 3: Build, switch, verify**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  curl -sS 'http://127.0.0.1:9090/api/v1/query?query=probe_success{probe="openclaw-health"}' | jq '.data.result[0].value[1]'
  ```

  Expected: `"1"`.

- [ ] **Step 4: Commit**

  ```bash
  git add -A modules/monitoring/
  git commit -m "feat(monitoring): blackbox probe for openclaw /health"
  ```

---

### Task A5: New & updated alert rules

**Files:**
- Modify: `modules/monitoring/alerts/openclaw.yaml`

**Why:** `OpenClawDiscordWsDown` is the new B-floor signal. `OpenClawHttpHealthDown` covers gateway HTTP failure. `OpenClawSelfHealDown` is the human-paging escape hatch that intentionally bypasses the self-heal.

- [ ] **Step 1: Add `service: openclaw` label to every existing rule's `labels` block**

  Open `modules/monitoring/alerts/openclaw.yaml`. Every existing alert in the `openclaw_availability` group already has `service: openclaw` — verify, no change needed if so.

- [ ] **Step 2: Append three new alerts**

  Append inside the `rules:` list of `openclaw_availability`:

  ```yaml
      - alert: OpenClawDiscordWsDown
        expr: openclaw_discord_ws_connected == 0
        for: 3m
        labels:
          severity: critical
          category: availability
          service: openclaw
        annotations:
          summary: "OpenClaw Discord WebSocket disconnected for 3 minutes"
          description: |
            The most recent positive Discord ready event (client initialized /
            logged in / WebSocket connection opened) is older than the most
            recent negative event (websocket closed / gateway error / reconnect
            scheduled (close|zombie) / was-not-ready / channel exited /
            health-monitor restart), and the 60s reconnect grace window has
            not produced a fresh negative event. Bot will not receive or send
            Discord messages until the connection is restored.

      - alert: OpenClawHttpHealthDown
        expr: probe_success{probe="openclaw-health"} == 0
        for: 1m
        labels:
          severity: critical
          category: availability
          service: openclaw
        annotations:
          summary: "OpenClaw HTTP /health probe failing for 1 minute"
          description: |
            blackbox_exporter cannot reach https://openclaw.vulcan.lan/health.

      - alert: OpenClawSelfHealDown
        expr: time() - openclaw_self_heal_last_heartbeat_seconds > 600
        for: 2m
        labels:
          severity: critical
          category: monitoring
          service: openclaw-self-heal      # NOTE: not "openclaw"; this alert
                                            # MUST NOT route to the self-heal
                                            # webhook.
        annotations:
          summary: "openclaw-self-heal daemon hasn't heartbeat in >10 minutes"
          description: |
            The self-heal daemon is the watchdog; if it dies, nothing else
            will. Investigate openclaw-self-heal.service on vulcan.
  ```

- [ ] **Step 3: Build and verify Prometheus reloads rules**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  curl -sS 'http://127.0.0.1:9090/api/v1/rules' | jq '[.data.groups[].rules[] | select(.name | startswith("OpenClaw"))] | length'
  ```

  Expected: at least 9 OpenClaw* rules.

- [ ] **Step 4: Commit**

  ```bash
  git add modules/monitoring/alerts/openclaw.yaml
  git commit -m "feat(alerts): add DiscordWsDown, HttpHealthDown, SelfHealDown for openclaw"
  ```

---

### Task A6: Auto-`doctor --fix` in preStart

**Files:**
- Modify: `modules/services/openclaw-vm.nix` — preStart, after the existing jq pipeline that writes `openclaw.json`

**Why:** Today's incident needed `doctor --fix` to migrate plugin-registry state. Running it on every boot makes upgrades silent.

- [ ] **Step 1: Add the doctor invocation block to preStart**

  Find the line `chmod 600 ${openclawDir}/openclaw.json` in `openclaw-vm.nix` (around line 565 of the current preStart). Insert immediately after it:

  ```nix
            # ────────────────────────────────────────────────────────────────
            # Auto-migrate runtime state on every boot. doctor is idempotent:
            # if there's nothing to migrate, it's a no-op (~2 s). When openclaw
            # bumps, this catches new schema/state migrations before any alert
            # fires. Failures are non-fatal — gateway still boots so we can
            # diagnose.
            # ────────────────────────────────────────────────────────────────
            (
              export OPENCLAW_STATE_DIR="${openclawDir}"
              export OPENCLAW_CONFIG_PATH="${openclawDir}/openclaw.json"
              export HOME="${stateDir}"
              ${pkgs.coreutils}/bin/timeout 120s \
                ${openclawPkg}/bin/openclaw doctor --fix --non-interactive --yes \
                || ${pkgs.coreutils}/bin/echo "openclaw doctor --fix failed (non-fatal); see journal"
            )
  ```

- [ ] **Step 2: Build**

  ```bash
  sudo nixos-rebuild build --flake '/etc/nixos#vulcan'
  ```

- [ ] **Step 3: Switch and watch journal**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  sudo journalctl -u openclaw.service --since '3 min ago' | grep -i doctor | head
  ```

  Expected: doctor output present, gateway reaches ready as before.

- [ ] **Step 4: Verify Discord WS still connected after the rebuild**

  ```bash
  cat /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom | grep openclaw_discord_ws_connected
  ```

  Expected: `1.0`.

- [ ] **Step 5: Commit**

  ```bash
  git add modules/services/openclaw-vm.nix
  git commit -m "feat(openclaw): run doctor --fix idempotently in preStart"
  ```

---

### Task A7: Stale `plugin-runtime-deps` GC in preStart

**Files:**
- Modify: `modules/services/openclaw-vm.nix` — preStart, immediately after the doctor block from A6

**Why:** 14 GB / 349 stale dirs accumulated. With the upstream patch dropped in 2026.5.x, these are dead weight.

- [ ] **Step 1: Add GC block**

  Insert after the doctor block:

  ```nix
            # ────────────────────────────────────────────────────────────────
            # GC stale plugin-runtime-deps subdirs. The upstream
            # stageBundledPluginRuntimeDeps mechanism was dropped in
            # openclaw 2026.5.x (numtide/llm-agents.nix d9cdb33), so subdirs
            # named after older versions are dead weight forever.
            # mv-not-rm pattern: deleted entries become .bak-<ts>, purged by
            # a separate weekly timer.
            # ────────────────────────────────────────────────────────────────
            DEPS_DIR="${openclawDir}/plugin-runtime-deps"
            CURRENT_VER=$(${openclawPkg}/bin/openclaw --version 2>/dev/null \
                          | ${pkgs.gnused}/bin/sed -nE 's/.*OpenClaw ([0-9.]+).*/\1/p' \
                          | ${pkgs.coreutils}/bin/head -n1)
            if [ -n "$CURRENT_VER" ] && [ -d "$DEPS_DIR" ]; then
              BAK_TS=$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)
              for entry in "$DEPS_DIR"/*; do
                [ -d "$entry" ] || continue
                base=$(${pkgs.coreutils}/bin/basename "$entry")
                case "$base" in
                  openclaw-"$CURRENT_VER"-*)  : ;;            # keep
                  openclaw-*)
                    ${pkgs.coreutils}/bin/mv "$entry" \
                      "$DEPS_DIR/.bak-$BAK_TS-$base"
                    ;;
                esac
              done
            fi
  ```

- [ ] **Step 2: Add weekly purge timer (separate systemd unit)**

  Lower in `openclaw-vm.nix` (or in `openclaw-microvm.nix`, wherever host-side units live), add:

  ```nix
  systemd.services.openclaw-plugin-deps-bak-purge = {
    description = "Purge openclaw plugin-runtime-deps backups older than 7 days";
    serviceConfig = {
      Type = "oneshot";
      User = "openclaw";
      ExecStart = pkgs.writeShellScript "openclaw-bak-purge" ''
        DEPS=/var/lib/openclaw/.openclaw/plugin-runtime-deps
        ${pkgs.findutils}/bin/find "$DEPS" -maxdepth 1 -type d \
            -name '.bak-*' -mtime +7 -exec ${pkgs.coreutils}/bin/rm -rf {} +
      '';
    };
  };

  systemd.timers.openclaw-plugin-deps-bak-purge = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
  ```

- [ ] **Step 3: Build, switch, verify**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  sudo ls /var/lib/openclaw/.openclaw/plugin-runtime-deps/ | head
  sudo du -sh /var/lib/openclaw/.openclaw/plugin-runtime-deps/
  ```

  Expected: only directories with `2026.5.3` in the name remain (or `.bak-*` placeholders); size under 100 MB.

- [ ] **Step 4: Commit**

  ```bash
  git add modules/services/openclaw-vm.nix
  git commit -m "feat(openclaw): GC stale plugin-runtime-deps in preStart + weekly purge"
  ```

---

### Task A8: Phase A end-to-end smoke test

- [ ] **Step 1: Verify all monitoring signals fresh**

  ```bash
  cat /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom | grep -E 'openclaw_(discord_ws|channel_plugin|gateway_ready_age|canary_parse_ok)'
  curl -sS 'http://127.0.0.1:9090/api/v1/query?query=probe_success{probe="openclaw-health"}' | jq -r '.data.result[0].value[1]'
  curl -sS 'http://127.0.0.1:9093/api/v2/alerts' | jq '[.[] | select(.labels.service == "openclaw" and .status.state == "active")] | length'
  ```

  Expected: discord_ws_connected=1, all four channel plugins present at 1.0, probe_success=1, no active openclaw alerts.

- [ ] **Step 2: Tag this as the Phase-A complete checkpoint**

  ```bash
  git tag openclaw-self-heal-phaseA-complete
  git log --oneline -10
  ```

  Phase A committed work covers tasks A1–A7. The self-heal daemon (Phase B) builds on top.

---

## Phase B — Self-heal daemon

This is the new long-running webhook receiver. Built TDD-style.

### Task B1: Reserve port and create skeleton

**Files:**
- Modify: `docs/ports.txt`
- Create: `scripts/openclaw-self-heal/daemon.py`
- Create: `scripts/openclaw-self-heal/tests/test_daemon.py`

**Why:** Lock in the port, scaffold the file, get one passing test.

- [ ] **Step 1: Reserve port 9092**

  Edit `docs/ports.txt`. Insert this line in numerical order (between 9091 Wallabag and 9093 Alertmanager):

  ```
  9092 127.0.0.1 OpenClaw Self-Heal webhook receiver
  ```

- [ ] **Step 2: Create daemon skeleton with version constant**

  Create `scripts/openclaw-self-heal/daemon.py`:

  ```python
  #!/usr/bin/env python3
  """openclaw-self-heal — Alertmanager webhook receiver and remediation runner.

  See docs/superpowers/specs/2026-05-05-openclaw-self-heal-design.md.
  """
  __version__ = "0.1.0"

  ACTION_ALLOWLIST = ("restart_microvm", "doctor_fix", "prune_stale_plugin_deps")
  WEBHOOK_PORT = 9092
  ```

- [ ] **Step 3: Write failing test for ACTION_ALLOWLIST**

  Create `scripts/openclaw-self-heal/tests/test_daemon.py`:

  ```python
  import sys, pathlib
  sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
  import daemon

  def test_allowlist_is_exactly_the_three_authorized_actions():
      assert daemon.ACTION_ALLOWLIST == (
          "restart_microvm", "doctor_fix", "prune_stale_plugin_deps"
      )
  ```

- [ ] **Step 4: Run test to verify it passes**

  ```bash
  cd /etc/nixos
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  ```

  Expected: 1 passed.

- [ ] **Step 5: Commit**

  ```bash
  git add docs/ports.txt scripts/openclaw-self-heal/
  git commit -m "chore(openclaw-self-heal): scaffold daemon and reserve port 9092"
  ```

---

### Task B2: Action allowlist enforcement (pure function, TDD)

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

**Why:** This is the safety floor — even if the AI hallucinates, this rejects.

- [ ] **Step 1: Write failing tests**

  Append to `test_daemon.py`:

  ```python
  import pytest

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

  Run: `python3 -m pytest scripts/openclaw-self-heal/tests/ -v`. Expected: 4 fails (`AttributeError`).

- [ ] **Step 2: Implement `validate_action`**

  In `daemon.py`:

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

- [ ] **Step 3: Run tests**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  ```

  Expected: 5 passed.

- [ ] **Step 4: Commit**

  ```bash
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): action allowlist + validate_action"
  ```

---

### Task B3: Incident state model (pure logic, TDD)

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

**Why:** The correlation rules and the attempt-counter are the heart of the state machine; isolating them as pure functions keeps testing simple.

- [ ] **Step 1: Write failing tests**

  Append:

  ```python
  import time

  def test_correlation_key_groups_by_vm_boot():
      a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000}
      b = {"alert_name": "OpenClawDiscordPluginMissing", "vm_active_enter_ts": 1000}
      assert daemon.correlation_key(a) == daemon.correlation_key(b)

  def test_correlation_key_differs_after_vm_restart():
      a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000}
      b = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 2000}
      assert daemon.correlation_key(a) != daemon.correlation_key(b)

  def test_attempt_n_starts_at_one_for_new_incident():
      inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                                 "vm_active_enter_ts": 1000})
      assert daemon.next_attempt_n(inc) == 1

  def test_attempt_n_increments_with_recorded_attempts():
      inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                                 "vm_active_enter_ts": 1000})
      inc["attempts"].append({"action": "restart_microvm", "result": "ok"})
      assert daemon.next_attempt_n(inc) == 2

  def test_should_escalate_after_three_attempts():
      inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                                 "vm_active_enter_ts": 1000})
      inc["attempts"] = [{"x": 1}, {"x": 2}, {"x": 3}]
      assert daemon.should_escalate(inc) is True

  def test_should_not_escalate_at_attempt_three():
      inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                                 "vm_active_enter_ts": 1000})
      inc["attempts"] = [{"x": 1}, {"x": 2}]
      assert daemon.should_escalate(inc) is False
  ```

- [ ] **Step 2: Implement**

  ```python
  def correlation_key(alert: dict) -> str:
      """Same VM boot + alert name family → same incident."""
      return f"{alert.get('vm_active_enter_ts', 0)}"

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
  ```

  Note: correlation by VM boot timestamp alone (not by alert-name family) is a deliberate simplification — any alert during the same boot is the same incident. The spec calls for ≤5 min correlation window AS WELL — that's the next test.

- [ ] **Step 3: Add 5-min window test and refine**

  ```python
  def test_correlation_separates_after_five_minutes_even_with_same_vm_ts():
      a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000,
           "starts_at": 5000}
      b = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000,
           "starts_at": 5400}  # 400 s later, well past 5-min window
      assert daemon.correlation_key(a, window_s=300) != daemon.correlation_key(b, window_s=300)
  ```

  Refine implementation:

  ```python
  def correlation_key(alert: dict, window_s: int = 300) -> str:
      ts = alert.get("starts_at", 0)
      bucket = ts // window_s
      return f"{alert.get('vm_active_enter_ts', 0)}:{bucket}"
  ```

  Update earlier tests to provide `starts_at` if they're now under-specified.

- [ ] **Step 4: Run tests**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  ```

  Expected: all green.

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): incident state model + correlation"
  ```

---

### Task B4: State persistence (file-locked JSON)

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Tests with tmp_path**

  ```python
  import json

  def test_state_load_returns_default_on_missing_file(tmp_path):
      path = tmp_path / "incidents.json"
      state = daemon.load_state(path)
      assert state == {"active": {}, "history": []}

  def test_state_roundtrip(tmp_path):
      path = tmp_path / "incidents.json"
      state = {"active": {"k": {"x": 1}}, "history": [{"y": 2}]}
      daemon.save_state(path, state)
      assert daemon.load_state(path) == state
  ```

- [ ] **Step 2: Implement using `fcntl.flock`**

  ```python
  import json, fcntl, os, tempfile, pathlib

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

- [ ] **Step 3: Run tests**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): atomic file-locked state persistence"
  ```

---

### Task B5: Action map (deterministic dispatch)

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Tests**

  ```python
  def test_action_map_each_alert_maps_to_known_action_or_wait():
      for action in daemon.ACTION_MAP.values():
          assert action in daemon.ACTION_ALLOWLIST or action == "wait_60s"

  def test_action_map_covers_expected_alerts():
      for a in (
          "OpenClawDiscordWsDown", "OpenClawHttpHealthDown",
          "OpenClawGatewayReadyStale", "OpenClawDiscordPluginMissing",
          "OpenClawPluginInitFailuresPresent", "OpenClawMicroVMDown",
      ):
          assert a in daemon.ACTION_MAP
  ```

- [ ] **Step 2: Implement**

  ```python
  ACTION_MAP = {
      "OpenClawDiscordWsDown":             "restart_microvm",
      "OpenClawHttpHealthDown":            "restart_microvm",
      "OpenClawGatewayReadyStale":         "restart_microvm",
      "OpenClawDiscordPluginMissing":      "doctor_fix",
      "OpenClawPluginInitFailuresPresent": "doctor_fix",
      "OpenClawMicroVMDown":               "wait_60s",
  }

  def first_attempt_action(alert_name: str) -> str:
      return ACTION_MAP.get(alert_name, "restart_microvm")
  ```

- [ ] **Step 3: Tests pass; commit**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): action map for deterministic first attempt"
  ```

---

### Task B6: Action runner — sudo-wrapped execution

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Tests with monkeypatched subprocess**

  ```python
  def test_run_action_invokes_sudo_with_exact_path(monkeypatch):
      calls = []
      def fake_run(cmd, capture_output, text, timeout):
          calls.append(cmd)
          class R: returncode = 0; stdout = '{"ok": true}'; stderr = ""
          return R()
      monkeypatch.setattr(daemon.subprocess, "run", fake_run)
      result = daemon.run_action("restart_microvm")
      assert calls == [[
          "sudo", "-n",
          "/etc/nixos/scripts/openclaw-self-heal/actions/restart_microvm",
      ]]
      assert result["ok"] is True

  def test_run_action_rejects_non_allowlisted(monkeypatch):
      monkeypatch.setattr(daemon.subprocess, "run",
                          lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not call")))
      with pytest.raises(daemon.ActionRejectedError):
          daemon.run_action("rm_rf_slash")

  def test_run_action_handles_nonjson_output(monkeypatch):
      def fake_run(cmd, capture_output, text, timeout):
          class R: returncode = 0; stdout = "not json"; stderr = ""
          return R()
      monkeypatch.setattr(daemon.subprocess, "run", fake_run)
      result = daemon.run_action("restart_microvm")
      assert result["ok"] is False
      assert "non-json" in result["notes"].lower()
  ```

- [ ] **Step 2: Implement**

  ```python
  import subprocess, json
  ACTIONS_DIR = "/etc/nixos/scripts/openclaw-self-heal/actions"

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

- [ ] **Step 3: Tests pass; commit**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): action runner with sudo-allowlisted dispatch"
  ```

---

### Task B7: LiteLLM client + AI prompt assembly

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Tests for prompt rendering**

  ```python
  def test_render_prompt_includes_alert_and_attempts():
      inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                                 "vm_active_enter_ts": 1000,
                                 "starts_at": 5000})
      inc["alerts"] = ["OpenClawDiscordWsDown"]
      inc["attempts"] = [{"action": "restart_microvm", "by": "deterministic",
                          "result": "ok"}]
      msgs = daemon.render_prompt(inc, metrics={"x": 1}, err_log_tail="oops",
                                  out_log_tail="hi")
      assert any("restart_microvm" in m["content"] for m in msgs)
      assert any("OpenClawDiscordWsDown" in m["content"] for m in msgs)
      assert msgs[0]["role"] == "system"

  def test_render_prompt_redacts_discord_token_pattern():
      inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                                 "vm_active_enter_ts": 1, "starts_at": 1})
      tok = "DISCORD_TOKEN_REDACTED"
      msgs = daemon.render_prompt(inc, metrics={}, err_log_tail=f"got token={tok}",
                                  out_log_tail="")
      joined = " ".join(m["content"] for m in msgs)
      assert tok not in joined
      assert "[REDACTED]" in joined
  ```

- [ ] **Step 2: Implement prompt rendering and redaction**

  ```python
  import re

  REDACT_PATTERNS = [
      # Discord bot token: 24-30+ chars . 6 chars . 27+ chars
      re.compile(r"[A-Za-z0-9_-]{24,40}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"),
      # Anthropic
      re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
      # OpenAI
      re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}"),
      # Common bearer headers
      re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"),
      # Generic ?token=... or password=...
      re.compile(r"(?i)(token|password|api[_-]?key)=[^\s&\"]+"),
  ]
  def redact(s: str) -> str:
      for p in REDACT_PATTERNS:
          s = p.sub("[REDACTED]", s)
      return s

  SYSTEM_PROMPT = """You are an SRE for OpenClaw, a Discord-facing AI gateway running as a microVM
  on host vulcan. Your goal is to restore service. You may take exactly ONE of:
    1. restart_microvm
    2. doctor_fix
    3. prune_stale_plugin_deps
  Output STRICTLY this JSON, no other text:
    {"action": "<one of the three>", "reason": "<one sentence>"}
  If you do not believe any of these will help, output:
    {"action": "escalate", "reason": "..."}"""

  def render_prompt(incident, metrics, err_log_tail, out_log_tail):
      attempts_str = "\n".join(
          f"  {i+1}. {a.get('action','?')} ({a.get('by','?')}) → {a.get('result','?')}"
          for i, a in enumerate(incident["attempts"])
      ) or "  (none)"
      metrics_str = "\n".join(f"  {k}={v}" for k, v in metrics.items())
      user = (
          f"[ALERTS] {', '.join(incident['alerts'])}\n"
          f"[ATTEMPTS SO FAR]\n{attempts_str}\n"
          f"[METRICS]\n{metrics_str}\n"
          f"[err.log tail]\n{redact(err_log_tail)}\n"
          f"[gateway.log tail]\n{redact(out_log_tail)}\n"
      )
      return [
          {"role": "system", "content": SYSTEM_PROMPT},
          {"role": "user",   "content": user},
      ]
  ```

- [ ] **Step 3: Tests for LiteLLM call (mocked)**

  ```python
  def test_call_litellm_returns_parsed_action(monkeypatch):
      def fake_post(url, headers, data, timeout):
          class R:
              status = 200
              def read(self): return json.dumps({"choices":[{"message":{"content":'{"action": "doctor_fix", "reason": "stale"}'}}]}).encode()
          return R()
      monkeypatch.setattr(daemon, "_http_post_json", fake_post)
      monkeypatch.setenv("LITELLM_KEY", "x")
      out = daemon.call_litellm([{"role":"system","content":"x"}], model="hera/Qwen3.6-27B")
      assert out == {"action": "doctor_fix", "reason": "stale"}
  ```

- [ ] **Step 4: Implement `_http_post_json` and `call_litellm`**

  ```python
  import os, urllib.request

  LITELLM_URL = "http://127.0.0.1:4000/v1/chat/completions"
  LITELLM_KEY_ENV = "LITELLM_KEY"

  class LitellmUnreachable(RuntimeError): pass

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
      except json.JSONDecodeError as e:
          raise LitellmUnreachable(f"non-json AI response: {content[:200]}")
  ```

- [ ] **Step 5: Tests pass; commit**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): LiteLLM client + redacted prompt rendering"
  ```

---

### Task B8: Webhook receiver + main loop wiring

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Test for handle_alertmanager_payload pure function**

  Alertmanager payload reference:
  ```json
  {"alerts": [{"status": "firing", "labels": {"alertname": "OpenClawDiscordWsDown", ...},
               "startsAt": "2026-05-05T18:30:00Z"}]}
  ```

  ```python
  def test_handle_payload_runs_first_attempt_action(monkeypatch, tmp_path):
      monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "incidents.json")
      monkeypatch.setattr(daemon, "current_metrics", lambda: {"openclaw_microvm_active_enter_timestamp_seconds": 9999})
      ran = []
      monkeypatch.setattr(daemon, "run_action", lambda name: ran.append(name) or {"ok": True})
      monkeypatch.setattr(daemon, "probe_clear", lambda inc: True)
      monkeypatch.setattr(daemon, "_kick_canary", lambda: None)        # hermetic: don't sudo during pytest
      monkeypatch.setattr(daemon.time, "sleep", lambda *_: None)       # hermetic: don't actually sleep 15 s
      payload = {"alerts": [{"status":"firing", "labels":{"alertname":"OpenClawDiscordWsDown","service":"openclaw"},
                            "startsAt":"2026-05-05T18:30:00Z"}]}
      daemon.handle_alertmanager_payload(payload)
      assert ran == ["restart_microvm"]
  ```

- [ ] **Step 2: Implement `handle_alertmanager_payload`**

  ```python
  STATE_PATH = "/var/lib/openclaw-self-heal/incidents.json"

  def current_metrics():
      """Read freshest values from prom textfile collector."""
      out = {}
      path = "/var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom"
      try:
          for line in pathlib.Path(path).read_text().splitlines():
              if line.startswith("#") or not line.strip(): continue
              k, _, v = line.rpartition(" ")
              try: out[k] = float(v)
              except ValueError: pass
      except FileNotFoundError:
          pass
      return out

  def probe_clear(incident):
      m = current_metrics()
      return m.get("openclaw_discord_ws_connected", 0.0) == 1.0

  def handle_alertmanager_payload(payload):
      from datetime import datetime
      state = load_state(STATE_PATH)
      metrics = current_metrics()
      vm_ts = int(metrics.get("openclaw_microvm_active_enter_timestamp_seconds", 0))
      for a in payload.get("alerts", []):
          if a.get("status") != "firing": continue
          alert_meta = {
              "alert_name":         a["labels"]["alertname"],
              "vm_active_enter_ts": vm_ts,
              "starts_at":          int(datetime.fromisoformat(a["startsAt"].replace("Z","+00:00")).timestamp()),
          }
          key = correlation_key(alert_meta)
          inc = state["active"].get(key) or new_incident(alert_meta)
          state["active"][key] = inc
          if inc["status"] != "in_progress": continue
          n = next_attempt_n(inc)
          if n == 1:
              action = first_attempt_action(alert_meta["alert_name"])
              by = "deterministic"
              ai_reason = None
          elif n in (2, 3):
              try:
                  ai_resp = call_litellm(render_prompt(inc, metrics, _err_tail(), _out_tail()))
              except LitellmUnreachable as e:
                  inc["attempts"].append({"action":"none","by":"ai","result":"litellm_unreachable","stderr":str(e)})
                  emit_synthetic_alert(
                      "OpenClawSelfHealLitellmUnreachable",
                      {"alert": alert_meta["alert_name"], "err": str(e)[:200]},
                      severity="warning", duration_s=3600,
                  )
                  inc["status"] = "stuck"
                  save_state(STATE_PATH, state); continue
              if ai_resp.get("action") == "escalate":
                  inc["status"] = "stuck"; save_state(STATE_PATH, state); continue
              try:
                  action = validate_action(ai_resp["action"])
              except (ActionRejectedError, KeyError):
                  inc["status"] = "stuck"; save_state(STATE_PATH, state); continue
              by = "ai"; ai_reason = ai_resp.get("reason")
          else:
              inc["status"] = "stuck"; save_state(STATE_PATH, state); continue
          if action == "wait_60s":
              import time; time.sleep(60)
              result = {"ok": True, "notes": "waited"}
          else:
              result = run_action(action)
          inc["attempts"].append({"ts": int(time.time()), "action": action, "by": by,
                                  "ai_reason": ai_reason, **result})
          save_state(STATE_PATH, state)
          # force fresh metrics via the aux/kick_canary helper
          _kick_canary()
          # short wait, then re-probe
          time.sleep(15)
          if probe_clear(inc):
              inc["status"] = "resolved"
          save_state(STATE_PATH, state)

  AUX_DIR = "/etc/nixos/scripts/openclaw-self-heal/aux"

  def _err_tail(n: int = 80) -> str:
      return _read_log_tail("err", n)

  def _out_tail(n: int = 30) -> str:
      return _read_log_tail("out", n)

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

  def _kick_canary() -> None:
      try:
          subprocess.run(
              ["sudo", "-n", f"{AUX_DIR}/kick_canary"],
              check=False, timeout=10,
          )
      except subprocess.TimeoutExpired:
          pass
  ```

  Note: the daemon invokes `sudo` by bare name. The systemd service unit
  must put the `sudo` setuid wrapper on `PATH` — handled in Task B12.
  All commands sudo runs are absolute paths into `/etc/nixos/scripts/`,
  so the sudoers allowlist matches by exact-path.

- [ ] **Step 3: HTTP server skeleton + `if __name__ == '__main__':`**

  ```python
  from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

  class Handler(BaseHTTPRequestHandler):
      def do_POST(self):
          if self.path != "/alert":
              self.send_response(404); self.end_headers(); return
          n = int(self.headers.get("Content-Length", "0"))
          body = self.rfile.read(n)
          try:
              payload = json.loads(body)
              handle_alertmanager_payload(payload)
              self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}\n')
          except Exception as e:
              self.send_response(500); self.end_headers()
              self.wfile.write(f'{{"ok":false,"err":{json.dumps(str(e))}}}\n'.encode())
      def log_message(self, *a, **kw): pass  # silence default access logs

  def main():
      srv = ThreadingHTTPServer(("127.0.0.1", WEBHOOK_PORT), Handler)
      print(f"openclaw-self-heal listening on 127.0.0.1:{WEBHOOK_PORT}", flush=True)
      srv.serve_forever()

  if __name__ == "__main__":
      main()
  ```

- [ ] **Step 4: Run tests**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): main loop and HTTP webhook receiver"
  ```

---

### Task B9: Heartbeat + self-monitoring metrics

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Test for write_heartbeat**

  ```python
  def test_write_heartbeat_emits_required_metrics(tmp_path):
      out = tmp_path / "openclaw_self_heal.prom"
      daemon.write_heartbeat(out_path=out, active_count=2, action_counts={"restart_microvm": 5})
      text = out.read_text()
      for k in ("openclaw_self_heal_last_heartbeat_seconds",
                "openclaw_self_heal_active_incidents",
                "openclaw_self_heal_attempts_total"):
          assert k in text
  ```

- [ ] **Step 2: Implement**

  ```python
  TEXTFILE_DIR = "/var/lib/prometheus-node-exporter-textfiles"
  HEARTBEAT_PATH = pathlib.Path(TEXTFILE_DIR) / "openclaw_self_heal.prom"

  def write_heartbeat(out_path=HEARTBEAT_PATH, active_count=0, action_counts=None,
                      litellm_unreachable=0):
      action_counts = action_counts or {}
      tmp = pathlib.Path(str(out_path) + ".tmp")
      tmp.parent.mkdir(parents=True, exist_ok=True)
      with tmp.open("w") as f:
          f.write(
              "# HELP openclaw_self_heal_last_heartbeat_seconds Last heartbeat from openclaw-self-heal daemon\n"
              "# TYPE openclaw_self_heal_last_heartbeat_seconds gauge\n"
              f"openclaw_self_heal_last_heartbeat_seconds {time.time()}\n"
              "# HELP openclaw_self_heal_active_incidents Currently in_progress incidents\n"
              "# TYPE openclaw_self_heal_active_incidents gauge\n"
              f"openclaw_self_heal_active_incidents {active_count}\n"
              "# HELP openclaw_self_heal_attempts_total Cumulative attempts by action\n"
              "# TYPE openclaw_self_heal_attempts_total counter\n"
          )
          for a in ACTION_ALLOWLIST:
              f.write(f'openclaw_self_heal_attempts_total{{action="{a}"}} {action_counts.get(a, 0)}\n')
          f.write(
              "# HELP openclaw_self_heal_litellm_unreachable_total Cumulative LiteLLM unreachable events\n"
              "# TYPE openclaw_self_heal_litellm_unreachable_total counter\n"
              f"openclaw_self_heal_litellm_unreachable_total {litellm_unreachable}\n"
          )
      os.replace(tmp, out_path)
  ```

- [ ] **Step 3: Wire heartbeat into main() via background thread**

  ```python
  import threading
  def heartbeat_loop():
      while True:
          try:
              state = load_state(STATE_PATH)
              active = sum(1 for v in state["active"].values() if v["status"] == "in_progress")
              # action counts read from history (cumulative)
              counts = {a: 0 for a in ACTION_ALLOWLIST}
              for inc in list(state["active"].values()) + state["history"]:
                  for att in inc.get("attempts", []):
                      if att.get("action") in counts:
                          counts[att["action"]] += 1
              write_heartbeat(active_count=active, action_counts=counts)
          except Exception as e:
              print(f"heartbeat error: {e}", flush=True)
          time.sleep(60)

  def main():
      threading.Thread(target=heartbeat_loop, daemon=True).start()
      # ... existing server start
  ```

- [ ] **Step 4: Tests; commit**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): heartbeat + self-monitoring metrics"
  ```

---

### Task B10: Synthetic alert injection back to Alertmanager

**Files:**
- Modify: `scripts/openclaw-self-heal/daemon.py`
- Modify: `scripts/openclaw-self-heal/tests/test_daemon.py`

- [ ] **Step 1: Tests with mocked _http_post_json**

  ```python
  def test_emit_synthetic_alert_acted(monkeypatch):
      sent = []
      monkeypatch.setattr(daemon, "_http_post_json",
                          lambda url, headers, data, timeout: sent.append((url, json.loads(data))) or type("R", (), {"read": lambda self: b""})())
      daemon.emit_synthetic_alert("OpenClawSelfHealActed",
                                  {"action": "restart_microvm", "alert": "OpenClawDiscordWsDown"})
      assert sent
      url, payload = sent[0]
      assert "/api/v2/alerts" in url
      assert payload[0]["labels"]["alertname"] == "OpenClawSelfHealActed"
  ```

- [ ] **Step 2: Implement**

  ```python
  ALERTMANAGER_URL = "http://127.0.0.1:9093/api/v2/alerts"

  def emit_synthetic_alert(name, annotations, severity="info", duration_s=300):
      from datetime import datetime, timezone, timedelta
      now = datetime.now(timezone.utc)
      payload = [{
          "labels": {"alertname": name, "severity": severity, "service": "openclaw-self-heal"},
          "annotations": {k: str(v) for k, v in annotations.items()},
          "startsAt": now.isoformat(),
          "endsAt":   (now + timedelta(seconds=duration_s)).isoformat(),
      }]
      try:
          _http_post_json(ALERTMANAGER_URL, {"Content-Type":"application/json"},
                          json.dumps(payload), timeout=10)
      except Exception as e:
          print(f"emit_synthetic_alert failed: {e}", flush=True)
  ```

- [ ] **Step 3: Wire into handle_alertmanager_payload after each action and on stuck**

  ```python
  # After successful action:
  emit_synthetic_alert("OpenClawSelfHealActed",
      {"action": action, "alert": alert_meta["alert_name"], "by": by, "result": result.get("ok")})

  # When marking stuck:
  emit_synthetic_alert("OpenClawSelfHealStuck",
      {"alert": alert_meta["alert_name"], "attempts": len(inc["attempts"])},
      severity="critical", duration_s=14400)

  # When LiteLLM is unreachable mid-incident — Task B8 already implements
  # this in its `except LitellmUnreachable as e` branch (emitting with
  # `str(e)`); this snippet exists only to document the wire-up. B8 is the
  # source of truth.
  emit_synthetic_alert("OpenClawSelfHealLitellmUnreachable",
      {"alert": alert_meta["alert_name"], "err": str(e)[:200]},
      severity="warning", duration_s=3600)
  ```

- [ ] **Step 4: Tests; commit**

  ```bash
  python3 -m pytest scripts/openclaw-self-heal/tests/ -v
  git add scripts/openclaw-self-heal/
  git commit -m "feat(openclaw-self-heal): emit synthetic alerts to Alertmanager"
  ```

---

### Task B11: Action scripts (bash)

**Files:**
- Create: `scripts/openclaw-self-heal/actions/restart_microvm`
- Create: `scripts/openclaw-self-heal/actions/doctor_fix`
- Create: `scripts/openclaw-self-heal/actions/prune_stale_plugin_deps`

- [ ] **Step 1: `restart_microvm`**

  ```bash
  #!/usr/bin/env bash
  # openclaw-self-heal action: restart microvm@openclaw.service.
  # Output: one line of JSON to stdout describing the result.
  set -euo pipefail
  start_ts=$(date +%s)
  /run/current-system/sw/bin/systemctl restart microvm@openclaw.service
  rc=$?
  end_ts=$(date +%s)
  duration=$((end_ts - start_ts))
  if [ "$rc" -eq 0 ]; then
    printf '{"ok": true, "duration_s": %d, "notes": "microvm restarted"}\n' "$duration"
  else
    printf '{"ok": false, "duration_s": %d, "notes": "systemctl restart returned %d"}\n' "$duration" "$rc"
  fi
  ```

- [ ] **Step 2: `doctor_fix`**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  start_ts=$(date +%s)
  notes="ok"
  if [ ! -f /var/lib/openclaw/.openclaw/openclaw.json ]; then
    printf '{"ok": false, "notes": "openclaw.json missing"}\n'
    exit 1
  fi
  PKG=$(/run/current-system/sw/bin/realpath /run/current-system/sw/bin/openclaw 2>/dev/null \
        | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null) || PKG=""
  OPENCLAW_BIN=$(/run/current-system/sw/bin/find /nix/store -maxdepth 1 -type d -name 'openclaw-*' \
                 -not -name '*.drv' 2>/dev/null | sort -V | tail -1)/bin/openclaw
  if [ ! -x "$OPENCLAW_BIN" ]; then
    printf '{"ok": false, "notes": "openclaw binary not found"}\n'; exit 1
  fi
  /run/current-system/sw/bin/sudo -n -u openclaw \
    OPENCLAW_STATE_DIR=/var/lib/openclaw/.openclaw \
    OPENCLAW_CONFIG_PATH=/var/lib/openclaw/.openclaw/openclaw.json \
    HOME=/var/lib/openclaw \
    /run/current-system/sw/bin/timeout 120s "$OPENCLAW_BIN" doctor --fix --non-interactive --yes \
    || notes="doctor exited non-zero (continuing to restart)"
  /run/current-system/sw/bin/systemctl restart microvm@openclaw.service
  end_ts=$(date +%s)
  printf '{"ok": true, "duration_s": %d, "notes": "%s"}\n' "$((end_ts - start_ts))" "$notes"
  ```

- [ ] **Step 3: `prune_stale_plugin_deps`**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  DEPS_DIR=/var/lib/openclaw/.openclaw/plugin-runtime-deps
  start_ts=$(date +%s)
  CURRENT_VER=$(/run/current-system/sw/bin/openclaw --version 2>/dev/null \
                | sed -nE 's/.*OpenClaw ([0-9.]+).*/\1/p' | head -n1)
  if [ -z "$CURRENT_VER" ]; then
    printf '{"ok": false, "notes": "could not determine current openclaw version"}\n'
    exit 1
  fi
  STALE_COUNT=$(find "$DEPS_DIR" -maxdepth 1 -type d -name 'openclaw-*' \
                ! -name "openclaw-${CURRENT_VER}-*" 2>/dev/null | wc -l)
  if [ "$STALE_COUNT" -eq 0 ]; then
    printf '{"ok": true, "duration_s": %d, "notes": "no stale dirs"}\n' "$(($(date +%s) - start_ts))"
    exit 0
  fi
  /run/current-system/sw/bin/systemctl stop microvm@openclaw.service
  BAK_TS=$(date -u +%Y%m%dT%H%M%SZ)
  find "$DEPS_DIR" -maxdepth 1 -type d -name 'openclaw-*' \
       ! -name "openclaw-${CURRENT_VER}-*" \
       -exec sh -c 'mv "$0" "$(dirname "$0")/.bak-'"$BAK_TS"'-$(basename "$0")"' {} \;
  /run/current-system/sw/bin/systemctl start microvm@openclaw.service
  end_ts=$(date +%s)
  printf '{"ok": true, "duration_s": %d, "notes": "moved %d stale dirs aside"}\n' "$((end_ts - start_ts))" "$STALE_COUNT"
  ```

- [ ] **Step 4: `aux/read_log_tail` (read-only helper, hardcoded paths)**

  ```bash
  #!/usr/bin/env bash
  # openclaw-self-heal aux helper: dump tail of a specific gateway log.
  # Usage: read_log_tail (err|out) <N-lines>
  # Path allowlist is hardcoded; no user input ever becomes a file path.
  set -euo pipefail
  WHICH="${1:-}"; N="${2:-80}"
  case "$WHICH" in
    err) LOG=/var/lib/openclaw/.openclaw/logs/gateway-vm.err.log ;;
    out) LOG=/var/lib/openclaw/.openclaw/logs/gateway-vm.log ;;
    *)   echo "usage: read_log_tail (err|out) <N>" >&2; exit 2 ;;
  esac
  case "$N" in
    ''|*[!0-9]*) echo "N must be a positive integer" >&2; exit 2 ;;
  esac
  [ "$N" -gt 0 ] && [ "$N" -le 1000 ] || { echo "N out of range" >&2; exit 2; }
  exec /run/current-system/sw/bin/tail -n "$N" "$LOG"
  ```

- [ ] **Step 5: `aux/kick_canary` (trigger one canary run)**

  ```bash
  #!/usr/bin/env bash
  # openclaw-self-heal aux helper: kick the canary so its *.prom textfile
  # reflects post-action state.  No arguments, no shell expansion.
  set -euo pipefail
  exec /run/current-system/sw/bin/systemctl start --no-block openclaw-canary.service
  ```

- [ ] **Step 6: chmod, shellcheck, smoke**

  ```bash
  chmod 755 scripts/openclaw-self-heal/actions/{restart_microvm,doctor_fix,prune_stale_plugin_deps}
  chmod 755 scripts/openclaw-self-heal/aux/{read_log_tail,kick_canary}
  shellcheck scripts/openclaw-self-heal/actions/* scripts/openclaw-self-heal/aux/* || true   # warnings ok, errors not
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add scripts/openclaw-self-heal/actions/ scripts/openclaw-self-heal/aux/
  git commit -m "feat(openclaw-self-heal): action scripts + aux helpers (read-only)"
  ```

---

### Task B12: NixOS module — user, sudoers, service unit

**Files:**
- Create: `modules/services/openclaw-self-heal.nix`
- Modify: `hosts/vulcan/default.nix`

- [ ] **Step 1: Write the module**

  ```nix
  { config, lib, pkgs, ... }:
  let
    cfg = config.services.openclawSelfHeal;
    daemonScript = pkgs.writeText "openclaw-self-heal-daemon.py"
      (builtins.readFile ../../scripts/openclaw-self-heal/daemon.py);
    user = "openclaw-heal";
    actionsDir = "/etc/nixos/scripts/openclaw-self-heal/actions";
    auxDir     = "/etc/nixos/scripts/openclaw-self-heal/aux";
  in {
    options.services.openclawSelfHeal = {
      enable = lib.mkEnableOption "openclaw self-heal daemon";
      port = lib.mkOption {
        type = lib.types.port; default = 9092;
        description = "Loopback port for the Alertmanager webhook.";
      };
    };

    config = lib.mkIf cfg.enable {
      users.users.${user} = {
        isSystemUser = true; group = user;
        home = "/var/lib/openclaw-self-heal"; createHome = true;
        homeMode = "0700";
        description = "OpenClaw self-heal daemon";
      };
      users.groups.${user} = {};

      # Sudoers allowlist is **only absolute paths to scripts under our
      # control**. No bare commands like `tail` or `systemctl` — those
      # would let the daemon read /etc/shadow or restart arbitrary units.
      # Every script does its own argument validation. The action
      # scripts are state-changing (matched by the L3 allowlist in the
      # daemon); the aux scripts are read-only/trivial helpers.
      security.sudo.extraRules = [{
        users = [ user ];
        commands = [
          { command = "${actionsDir}/restart_microvm";         options = [ "NOPASSWD" ]; }
          { command = "${actionsDir}/doctor_fix";              options = [ "NOPASSWD" ]; }
          { command = "${actionsDir}/prune_stale_plugin_deps"; options = [ "NOPASSWD" ]; }
          { command = "${auxDir}/read_log_tail";               options = [ "NOPASSWD" ]; }
          { command = "${auxDir}/kick_canary";                 options = [ "NOPASSWD" ]; }
        ];
      }];

      sops.secrets."litellm/master-key" = {
        owner = user; mode = "0400";
      };

      systemd.services.openclaw-self-heal = {
        description = "OpenClaw self-heal webhook receiver and remediation runner";
        wantedBy = [ "multi-user.target" ];
        after    = [ "network-online.target" "alertmanager.service" ];
        wants    = [ "network-online.target" ];
        # PATH must include /run/wrappers/bin so the daemon's bare `sudo`
        # invocations resolve to NixOS's setuid sudo wrapper. The daemon
        # never asks sudo to run a bare command — only absolute paths
        # under /etc/nixos/scripts/openclaw-self-heal/{actions,aux}/
        # which are matched by exact path in the sudoers allowlist.
        path = [ "/run/wrappers" pkgs.coreutils pkgs.systemd ];
        environment = {
          PYTHONUNBUFFERED = "1";
        };
        serviceConfig = {
          Type        = "simple";
          User        = user;  Group = user;
          Restart     = "always"; RestartSec = "5s";
          LoadCredential = [
            "litellm-key:${config.sops.secrets."litellm/master-key".path}"
          ];
          # Hardening (mirrors openclaw-canary patterns)
          ProtectSystem            = "strict";
          ProtectHome              = true;
          NoNewPrivileges          = false;  # needs setuid sudo wrapper
          PrivateTmp               = true;
          RestrictSUIDSGID         = false;  # sudo wrapper is setuid
          LockPersonality          = true;
          MemoryDenyWriteExecute   = false;  # python compiles bytecode
          ReadWritePaths = [
            "/var/lib/openclaw-self-heal"
            "/var/lib/prometheus-node-exporter-textfiles"
          ];
        };
        # `script` synthesises ExecStart; do not set ExecStart in serviceConfig
        # when using this attribute. The wrapper just sources the credential
        # into env before exec-ing the python daemon.
        script = ''
          export LITELLM_KEY="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/litellm-key")"
          exec ${pkgs.python3}/bin/python3 ${daemonScript}
        '';
      };

      networking.firewall.allowedTCPPorts = [];  # 127.0.0.1 only — no firewall change needed
    };
  }
  ```

- [ ] **Step 2: Import the module from the host**

  Edit `hosts/vulcan/default.nix`. Add to `imports`:

  ```nix
  ../../modules/services/openclaw-self-heal.nix
  ```

  And in the same file, enable it:

  ```nix
  services.openclawSelfHeal.enable = true;
  ```

- [ ] **Step 3: Build to confirm**

  ```bash
  sudo nixos-rebuild build --flake '/etc/nixos#vulcan'
  ```

  Expected: builds. Fix any module errors before continuing.

- [ ] **Step 4: Switch and verify the service starts**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  systemctl status openclaw-self-heal --no-pager
  curl -sS -X POST http://127.0.0.1:9092/alert -d '{"alerts":[]}' -H 'Content-Type: application/json'
  ```

  Expected: service is `active (running)`; curl returns `{"ok":true}`.

- [ ] **Step 5: Commit**

  ```bash
  git add modules/services/openclaw-self-heal.nix hosts/vulcan/default.nix
  git commit -m "feat(openclaw-self-heal): NixOS module wrapping daemon, user, sudo"
  ```

---

## Phase C — Wire-up

### Task C1: Alertmanager route + receiver

**Files:**
- Modify: wherever Alertmanager config lives — check `modules/monitoring/services/prometheus-server.nix` first (or `grep -rn 'route:\|receivers:' modules/monitoring/`)

- [ ] **Step 1: Find the Alertmanager config**

  ```bash
  grep -rn 'receivers:\|alertmanager.config' /etc/nixos/modules/monitoring/ | head
  ```

- [ ] **Step 2: Add a receiver and route**

  In the Alertmanager config block, add receiver:

  ```yaml
  receivers:
    - name: openclaw-self-heal
      webhook_configs:
        - url: http://127.0.0.1:9092/alert
          send_resolved: false
  ```

  And under `route.routes`:

  ```yaml
  - match:
      service: openclaw
    receiver: openclaw-self-heal
    group_wait: 10s
    group_interval: 5m
    repeat_interval: 4h
    continue: true     # so existing notification path also receives a copy
  ```

  `continue: true` means alerts are still delivered to the default receiver (your existing notification channel), so you also see them.

- [ ] **Step 3: Build, switch, verify**

  ```bash
  sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  curl -sS http://127.0.0.1:9093/api/v1/status | jq '.data.configYAML' -r | grep -A 3 'openclaw-self-heal'
  ```

  Expected: receiver block is present.

- [ ] **Step 4: Commit**

  ```bash
  git add -A
  git commit -m "feat(alertmanager): route service=openclaw alerts to self-heal webhook"
  ```

---

## Phase D — Validation

### Task D1: Inject a fake alert and observe the action

- [ ] **Step 1: Send a synthetic firing alert directly to the webhook**

  ```bash
  curl -sS -X POST http://127.0.0.1:9092/alert -H 'Content-Type: application/json' -d '{
    "alerts": [{
      "status": "firing",
      "labels": {"alertname": "OpenClawDiscordWsDown", "service": "openclaw"},
      "startsAt": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
    }]
  }'
  ```

- [ ] **Step 2: Observe the daemon takes the deterministic action**

  ```bash
  sudo journalctl -u openclaw-self-heal --since '2 min ago' | tail -30
  cat /var/lib/openclaw-self-heal/incidents.json | jq
  ```

  Expected: one incident in `active`, one attempt with `action=restart_microvm`, `by=deterministic`, status `resolved` after probe-clear (or `in_progress` if the gateway is taking longer to come back up).

- [ ] **Step 3: Confirm a synthetic OpenClawSelfHealActed alert reached Alertmanager**

  ```bash
  curl -sS http://127.0.0.1:9093/api/v2/alerts | jq '[.[] | select(.labels.alertname == "OpenClawSelfHealActed")]'
  ```

  Expected: at least one entry with `annotations.action == "restart_microvm"`.

### Task D2: Stuck escalation path

- [ ] **Step 1: Manually craft a 4th-attempt incident state and re-trigger**

  ```bash
  sudo cp /var/lib/openclaw-self-heal/incidents.json /tmp/incidents.bak
  sudo jq '.active[(.active | keys[0])].attempts = [{"x":1},{"x":2},{"x":3}]' /tmp/incidents.bak | sudo tee /var/lib/openclaw-self-heal/incidents.json
  curl -sS -X POST http://127.0.0.1:9092/alert -d '{"alerts":[{"status":"firing","labels":{"alertname":"OpenClawDiscordWsDown","service":"openclaw"},"startsAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}]}'
  ```

- [ ] **Step 2: Verify status moves to "stuck" and a critical alert was emitted**

  ```bash
  sudo jq '.active' /var/lib/openclaw-self-heal/incidents.json
  curl -sS http://127.0.0.1:9093/api/v2/alerts | jq '[.[] | select(.labels.alertname == "OpenClawSelfHealStuck")]'
  ```

  Expected: incident `status: "stuck"`, one critical alert.

- [ ] **Step 3: Restore real state**

  ```bash
  sudo cp /tmp/incidents.bak /var/lib/openclaw-self-heal/incidents.json
  ```

### Task D3: Self-monitoring heartbeat alarm

- [ ] **Step 1: Stop the daemon and wait 11 minutes**

  ```bash
  sudo systemctl stop openclaw-self-heal
  ```

  Wait until `time() - openclaw_self_heal_last_heartbeat_seconds > 600`.

- [ ] **Step 2: Verify OpenClawSelfHealDown fires**

  ```bash
  curl -sS http://127.0.0.1:9093/api/v2/alerts | jq '[.[] | select(.labels.alertname == "OpenClawSelfHealDown")]'
  ```

  Expected: alert in `active` state, `service: openclaw-self-heal` (NOT `openclaw`, so it doesn't loop back to itself).

- [ ] **Step 3: Restart and confirm clears**

  ```bash
  sudo systemctl start openclaw-self-heal
  ```

### Task D4: Final commit and tag

- [ ] **Step 1: Tag completion**

  ```bash
  cd /etc/nixos
  git tag openclaw-self-heal-complete
  git log --oneline openclaw-self-heal-phaseA-complete..HEAD
  ```

- [ ] **Step 2: Save a project memory marker**

  Update `/home/johnw/.claude/projects/-etc-nixos/memory/project_openclaw_migration.md` to note the self-heal layer is live, with the alert vocabulary and action allowlist documented.

---

## Out of scope (do not do as part of this plan)

- Round-trip "DM the bot, expect a reply" probing (would be option C; user picked B).
- Auto-bumping flake inputs (would be L5; user picked L3).
- Adding new schema migrations to the preStart jq pipeline as new openclaw versions break — humans do that.
- Removing the `openclaw-canary.timer` polling — keep it; the heartbeat metric also depends on the periodic `*.prom` write rhythm.
- Replacing `http.server` with a real web framework. The webhook handles ≤1 RPS by design.
