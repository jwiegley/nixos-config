# OpenClaw High-Availability Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 2026-04-22 plugin-init regression (OpenClaw 2026.4.21 + `workspace:*` npm protocol) at the package level, and add defense-in-depth monitoring so a similar regression trips an alert within 5 minutes instead of going unnoticed.

**Architecture:** Four independent layers — (1) a `overrideAttrs` postFixup that strips `devDependencies` from every bundled plugin `package.json` so runtime `npm install` cannot fail on workspace-protocol references; (2) a Loki recording + alert rule on the literal failure pattern; (3) a systemd-timer-driven canary that parses OpenClaw's gateway log for the "gateway ready" plugin line and emits Prometheus textfile metrics; (4) Alertmanager rules on those metrics plus a stale-canary rule. Nothing in this plan requires OpenClaw upstream changes or new external credentials.

**Tech Stack:** Nix/NixOS modules (`overrideAttrs`, systemd services/timers, tmpfiles.rules), Loki LogQL, PromQL, Prometheus textfile collector, Python for the canary parser.

**Scope notes:** The uncommitted `models.nix` agent-model swap (`Qwen3.5-397B` → `Qwen3.6-35B`) is orthogonal to this outage and is deliberately left alone by this plan. It will take effect on the next rebuild. No rollback of system generation is performed — Task 1 fixes the running package by rebuilding with the patch, which is preferable to reverting and losing the intended model change.

---

## File Structure

**Modify:**
- `/etc/nixos/modules/services/openclaw-microvm.nix` — add `overrideAttrs` on `openclawPkg` (around line 46) with a `postFixup` that patches plugin `package.json` files.

**Create:**
- `/etc/nixos/modules/monitoring/loki-rules/openclaw-plugin-errors.yaml` — Loki alert rule matching `plugin(s) failed to initialize` in OpenClaw's log stream.
- `/etc/nixos/modules/monitoring/services/openclaw-canary.nix` — systemd service + timer wrapping a Python canary script that parses OpenClaw's gateway log and writes Prometheus textfile metrics.
- `/etc/nixos/modules/monitoring/alerts/openclaw.yaml` — Alertmanager/Prometheus alert rules on the canary metrics and the microVM systemd unit state.

**Modify to register:**
- `/etc/nixos/modules/services/loki.nix` — add a tmpfiles symlink for the new Loki rule file.
- `/etc/nixos/modules/monitoring/default.nix` (or the nearest imports list) — import `openclaw-canary.nix`.
- `/etc/nixos/modules/monitoring/services/alerting.nix` — pick up `openclaw.yaml` (its existing `alertRuleFiles` loop auto-discovers `alerts/*.yaml`; verify this first).

---

## Task 1: Patch OpenClaw package to strip `workspace:*` from plugin manifests

**Files:**
- Modify: `/etc/nixos/modules/services/openclaw-microvm.nix:46`

**Rationale:** `/nix/store/3yqdgvl2jxzkq7nlaw3rdpblikclz2i3-openclaw-2026.4.21/lib/openclaw/extensions/*/package.json` contain `"@openclaw/plugin-sdk": "workspace:*"` and `"openclaw": "workspace:*"` in `devDependencies`. At runtime OpenClaw invokes `npm install <pkg>` inside each extension directory (to pull provider-specific optional deps like `@mariozechner/pi-ai`). `npm` then tries to resolve the *existing* `devDependencies` in that `package.json` and dies with `EUNSUPPORTEDPROTOCOL` because `workspace:*` is pnpm-only. The installer needs devDependencies for nothing at runtime, so removing the whole `devDependencies` block is safe and sufficient.

- [ ] **Step 1: Write the patch as an `overrideAttrs` on `openclawPkg`**

Edit `/etc/nixos/modules/services/openclaw-microvm.nix`. Replace the single line at 46:

```nix
  openclawPkg = inputs.llm-agents.packages.${system}.openclaw;
```

with:

```nix
  # Strip `devDependencies` from every bundled plugin's package.json.
  # Why: OpenClaw runs `npm install <provider-sdk>` inside each extension
  # directory at runtime; npm then re-resolves the package.json's existing
  # devDependencies and crashes on `"workspace:*"` (pnpm-only protocol),
  # bringing down acpx/brave/discord/lobster/whatsapp with EUNSUPPORTEDPROTOCOL.
  # The devDependencies are build-time only — Nix already supplied the real
  # deps via pnpm — so stripping them fixes the runtime install without
  # affecting functionality.
  openclawPkg = (inputs.llm-agents.packages.${system}.openclaw).overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      if [ -d "$out/lib/openclaw/extensions" ]; then
        for pkg in "$out"/lib/openclaw/extensions/*/package.json; do
          [ -f "$pkg" ] || continue
          ${pkgs.jq}/bin/jq 'del(.devDependencies)' "$pkg" > "$pkg.new"
          mv "$pkg.new" "$pkg"
        done
      fi
    '';
  });
```

- [ ] **Step 2: Dry-build to verify the patch applies**

```
sudo nixos-rebuild build --flake '.#vulcan' 2>&1 | tail -20
```

Expected: build succeeds, no error. If the build hits a `jq: not found` or syntax error, read `.#vulcan` trace and fix.

- [ ] **Step 3: Verify the built package has the patch applied**

Find the new OpenClaw path and grep for `workspace:`:

```
NEW=$(readlink -f ./result/sw/bin 2>/dev/null | head -1 || \
  sudo nix-store -qR /run/current-system | grep -E 'openclaw-[0-9]' | head -1)
# Better: inspect the result symlink directly after build
OC=$(sudo nix-store -qR $(readlink -f /nix/var/nix/profiles/system) | grep -E '^/nix/store/[a-z0-9]+-openclaw-20' | sort -u)
echo "$OC"
for p in $OC; do
  if [ -d "$p/lib/openclaw/extensions/discord" ]; then
    echo "Checking $p"
    grep -c '"workspace:' "$p"/lib/openclaw/extensions/*/package.json 2>/dev/null | awk -F: '$2>0' | head -5
  fi
done
```

Expected after switch: zero files show any `"workspace:` string (if the new package is in the current system closure).

A simpler verification that works pre-switch — inspect the build output before deploying:

```
nix build --no-link --print-out-paths '.#nixosConfigurations.vulcan.config.services.openclaw.package' 2>/dev/null || true
# Fall back: search all extension package.json in all locally-built openclaw derivations
for p in /nix/store/*-openclaw-2026.4.*; do
  [ -d "$p/lib/openclaw/extensions" ] || continue
  n=$(grep -rh '"workspace:' "$p"/lib/openclaw/extensions/*/package.json 2>/dev/null | wc -l)
  echo "$p workspace-refs=$n"
done | sort -u
```

Expected: the newest openclaw store path shows `workspace-refs=0`.

- [ ] **Step 4: Deploy the fix and restart the microVM**

```
sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tail -5
# The new package produces a new VM kernel/initrd closure, so microvm@openclaw
# will NOT restart automatically via systemd (microvm.nix opts out of auto-restart
# on config change). Bounce it explicitly:
sudo systemctl restart microvm@openclaw.service
```

- [ ] **Step 5: Verify plugins load correctly**

Wait ~2 minutes for VM boot + OpenClaw startup, then:

```
# Wait for gateway ready marker
for i in $(seq 1 60); do
  if sudo grep -q '^[^[:space:]]*.*\[gateway\] ready.*plugins' /var/lib/openclaw/.openclaw/logs/gateway-vm.log 2>/dev/null; then
    break
  fi
  sleep 2
done
sudo tail -40 /var/lib/openclaw/.openclaw/logs/gateway-vm.err.log | grep -iE 'fail.*initialize|workspace:' || echo "NO PLUGIN INIT FAILURES (good)"
sudo grep '\[gateway\] ready' /var/lib/openclaw/.openclaw/logs/gateway-vm.log | tail -1
```

Expected output includes: `NO PLUGIN INIT FAILURES (good)` AND a line like `[gateway] ready (5 plugins: acpx, discord, lobster, memory-qdrant, whatsapp; ...)`.

If Discord is in the plugin list and there are no init failures, the fix worked and DMs should now round-trip.

- [ ] **Step 6: Commit**

```
cd /etc/nixos
git add modules/services/openclaw-microvm.nix
git commit -m "$(cat <<'EOF'
Strip devDependencies from OpenClaw plugin package.json files

OpenClaw 2026.4.21 (pulled via f28f416 flake.lock bump) invokes
`npm install <provider-sdk>` inside each bundled extension directory
at runtime. npm then re-resolves the existing package.json's
devDependencies and dies on `"workspace:*"` (pnpm-only protocol),
taking out the acpx, brave, discord, lobster, and whatsapp plugins
with EUNSUPPORTEDPROTOCOL — which is why Discord DMs stopped
responding today.

The devDependencies are build-time only (pnpm already supplied the
real dependencies via openclaw-pnpm-deps during the Nix build), so
stripping them entirely is safe and makes the runtime npm call
succeed regardless of which future version introduces workspace:*
idioms.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add Loki alert rule for plugin-init failures

**Files:**
- Create: `/etc/nixos/modules/monitoring/loki-rules/openclaw-plugin-errors.yaml`
- Modify: `/etc/nixos/modules/services/loki.nix` (add tmpfiles symlink at line ~125)

**Rationale:** Even with Task 1's patch, OpenClaw runtime bugs in plugins are an ongoing risk. A Loki rule on the literal `plugin(s) failed to initialize` string catches the failure pattern within one rule-evaluation interval (1 minute here).

- [ ] **Step 1: Create the rule file**

Create `/etc/nixos/modules/monitoring/loki-rules/openclaw-plugin-errors.yaml`:

```yaml
groups:
  - name: openclaw_plugin_errors
    interval: 1m
    rules:
      - alert: OpenClawPluginInitFailure
        expr: |
          sum(count_over_time(
            {unit="microvm@openclaw.service"}
            |~ "plugin\\(s\\) failed to initialize"
            [5m]
          )) > 0
        for: 2m
        labels:
          severity: critical
          category: logs
          service: openclaw
        annotations:
          summary: "OpenClaw plugins failed to initialize"
          description: |
            OpenClaw logged one or more plugin initialization failures in the
            last 5 minutes. This typically means a chat channel (Discord,
            WhatsApp, etc.) is not answering. Check
            /var/lib/openclaw/.openclaw/logs/gateway-vm.err.log.

      - alert: OpenClawNpmWorkspaceProtocolError
        expr: |
          sum(count_over_time(
            {unit="microvm@openclaw.service"}
            |~ "EUNSUPPORTEDPROTOCOL.*workspace"
            [5m]
          )) > 0
        for: 0m
        labels:
          severity: critical
          category: logs
          service: openclaw
        annotations:
          summary: "OpenClaw regression: npm workspace:* protocol unsupported"
          description: |
            This is the 2026-04-22 regression pattern. An OpenClaw upgrade
            introduced extensions with workspace:* in package.json. Check
            modules/services/openclaw-microvm.nix (the overrideAttrs
            postFixup) and make sure the new extensions are covered.
```

- [ ] **Step 2: Add tmpfiles symlink in `loki.nix`**

Locate the block in `/etc/nixos/modules/services/loki.nix` around line 125 (the two existing `L+ /var/lib/loki/rules/fake/...` entries) and add a third entry right after them:

```nix
    "L+ /var/lib/loki/rules/fake/openclaw-plugin-errors.yaml - - - - /etc/nixos/modules/monitoring/loki-rules/openclaw-plugin-errors.yaml"
```

- [ ] **Step 3: Deploy**

```
sudo nixos-rebuild switch --flake '.#vulcan'
sudo systemctl restart loki.service
```

(Loki does not honour `systemctl reload`, as documented in memory 301.)

- [ ] **Step 4: Verify the rule loaded**

```
curl -sk https://loki.vulcan.lan/loki/api/v1/rules 2>/dev/null | \
  python3 -c 'import sys, yaml; d = yaml.safe_load(sys.stdin); print([g["name"] for groups in d.values() for ns in groups.values() for g in ns])' 2>&1 | grep -o openclaw_plugin_errors
```

Expected: `openclaw_plugin_errors` printed.

- [ ] **Step 5: Commit**

```
cd /etc/nixos
git add modules/monitoring/loki-rules/openclaw-plugin-errors.yaml modules/services/loki.nix
git commit -m "Add Loki alert rules for OpenClaw plugin init failures"
```

---

## Task 3: Add OpenClaw gateway canary (Prometheus textfile metric)

**Files:**
- Create: `/etc/nixos/modules/monitoring/services/openclaw-canary.nix`
- Modify: the `monitoring/default.nix` (or whichever file imports the `monitoring/services/*.nix` modules) to include the new file.

**Rationale:** The current in-VM `health-check.txt` greps for "client initialized" which is printed very early in OpenClaw's startup; it remained in the log buffer across the VM-restart and gave a false-positive PASS today. A better signal is OpenClaw's `[gateway] ready (N plugins: ...)` line — it's printed *after* plugin validation succeeds. The canary reads the last few lines of `/var/lib/openclaw/.openclaw/logs/gateway-vm.log` (host-visible via virtiofs share), parses the most recent `[gateway] ready` line, and emits Prometheus metrics.

- [ ] **Step 1: Create the canary module**

Create `/etc/nixos/modules/monitoring/services/openclaw-canary.nix`:

```nix
# OpenClaw gateway canary
#
# Parses /var/lib/openclaw/.openclaw/logs/gateway-vm.log for the most recent
# `[gateway] ready (N plugins: ...)` line and emits three Prometheus metrics
# via the node-exporter textfile collector:
#
#   openclaw_gateway_ready_plugins_total{names="acpx,discord,..."}
#   openclaw_gateway_ready_timestamp_seconds
#   openclaw_gateway_ready_age_seconds
#
# Also emits 0/1 booleans per expected channel plugin
# (openclaw_channel_plugin_loaded{channel="discord"}) so alerting on specific
# channel failures is trivial.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  expectedChannels = [
    "discord"
    "whatsapp"
    "lobster"
    "acpx"
    "memory-qdrant"
  ];

  canaryScript = pkgs.writeScript "openclaw-canary.py" ''
    #!${pkgs.python3}/bin/python3
    """
    OpenClaw gateway log parser → Prometheus textfile exporter.

    Reads the tail of gateway-vm.log looking for:
      [gateway] ready (N plugins: a, b, c; TTTms)

    Also scans gateway-vm.err.log for recent plugin-init failures in the
    last hour so a stale `ready` line followed by a crash is still caught.
    """

    import os
    import pathlib
    import re
    import subprocess
    import sys
    import time

    LOG_PATH = pathlib.Path("/var/lib/openclaw/.openclaw/logs/gateway-vm.log")
    ERR_PATH = pathlib.Path("/var/lib/openclaw/.openclaw/logs/gateway-vm.err.log")
    OUT_FINAL = pathlib.Path("${textfileDir}/openclaw_canary.prom")
    OUT_TMP = OUT_FINAL.with_suffix(".prom.tmp")
    EXPECTED = ${builtins.toJSON expectedChannels}

    READY_RE = re.compile(
      r"^(?P<ts>\S+)\s+\[gateway\]\s+ready\s+\((?P<n>\d+)\s+plugin[s]?:\s*(?P<list>[^;]+);"
    )
    FAIL_RE = re.compile(
      r"^(?P<ts>\S+)\s+\[plugins\]\s+(?P<n>\d+)\s+plugin\(s\)\s+failed\s+to\s+initialize.*validation:\s*(?P<list>[^)]+)"
    )

    def iso_to_epoch(s):
      # OpenClaw prints RFC3339 with microseconds and `+00:00` offset.
      # Python 3.11+ fromisoformat handles it; be defensive for older prints.
      from datetime import datetime
      try:
        return datetime.fromisoformat(s).timestamp()
      except ValueError:
        # Fallback: try stripping a trailing Z or matching date only
        try:
          return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").timestamp()
        except Exception:
          return 0.0

    def tail(path, lines=500):
      if not path.exists():
        return []
      # Use `tail` for speed on the 10+MB log file instead of slurping in Python.
      try:
        out = subprocess.check_output(
          ["${pkgs.coreutils}/bin/tail", "-n", str(lines), str(path)],
          text=True, errors="replace",
        )
        return out.splitlines()
      except subprocess.CalledProcessError:
        return []

    def find_last(regex, lines):
      for line in reversed(lines):
        m = regex.search(line)
        if m:
          return m
      return None

    def write_metrics(payload: dict[str, float], labeled: dict[str, dict[str, float]]):
      OUT_FINAL.parent.mkdir(parents=True, exist_ok=True)
      with OUT_TMP.open("w") as f:
        f.write("# HELP openclaw_gateway_ready_plugins_total Plugin count from the most recent [gateway] ready line\n")
        f.write("# TYPE openclaw_gateway_ready_plugins_total gauge\n")
        f.write(f"openclaw_gateway_ready_plugins_total {payload['plugins_total']}\n")
        f.write("# HELP openclaw_gateway_ready_timestamp_seconds Unix timestamp of the most recent [gateway] ready line\n")
        f.write("# TYPE openclaw_gateway_ready_timestamp_seconds gauge\n")
        f.write(f"openclaw_gateway_ready_timestamp_seconds {payload['ready_ts']}\n")
        f.write("# HELP openclaw_gateway_ready_age_seconds Seconds since the most recent [gateway] ready line\n")
        f.write("# TYPE openclaw_gateway_ready_age_seconds gauge\n")
        f.write(f"openclaw_gateway_ready_age_seconds {payload['ready_age']}\n")
        f.write("# HELP openclaw_plugin_init_failures_recent_total Plugin init failures seen in the log tail\n")
        f.write("# TYPE openclaw_plugin_init_failures_recent_total gauge\n")
        f.write(f"openclaw_plugin_init_failures_recent_total {payload['init_failures']}\n")
        f.write("# HELP openclaw_canary_parse_ok 1 if the canary successfully parsed a recent ready line\n")
        f.write("# TYPE openclaw_canary_parse_ok gauge\n")
        f.write(f"openclaw_canary_parse_ok {payload['parse_ok']}\n")
        f.write("# HELP openclaw_canary_last_run_timestamp_seconds When the canary last ran\n")
        f.write("# TYPE openclaw_canary_last_run_timestamp_seconds gauge\n")
        f.write(f"openclaw_canary_last_run_timestamp_seconds {time.time()}\n")
        f.write("# HELP openclaw_channel_plugin_loaded 1 if the channel plugin is present in the most recent [gateway] ready list\n")
        f.write("# TYPE openclaw_channel_plugin_loaded gauge\n")
        for name, present in labeled["channel_plugin"].items():
          f.write(f'openclaw_channel_plugin_loaded{{channel="{name}"}} {present}\n')
      os.replace(OUT_TMP, OUT_FINAL)

    def main() -> int:
      now = time.time()
      lines = tail(LOG_PATH, 800)
      err_lines = tail(ERR_PATH, 800)

      ready = find_last(READY_RE, lines)
      fail_count = sum(1 for l in err_lines if FAIL_RE.search(l))

      loaded = {c: 0.0 for c in EXPECTED}
      if ready:
        plugin_list = [p.strip() for p in ready["list"].split(",") if p.strip()]
        for c in EXPECTED:
          loaded[c] = 1.0 if c in plugin_list else 0.0
        ready_ts = iso_to_epoch(ready["ts"])
        payload = dict(
          plugins_total=float(int(ready["n"])),
          ready_ts=ready_ts,
          ready_age=max(0.0, now - ready_ts) if ready_ts else 0.0,
          init_failures=float(fail_count),
          parse_ok=1.0,
        )
      else:
        payload = dict(
          plugins_total=0.0,
          ready_ts=0.0,
          ready_age=0.0,
          init_failures=float(fail_count),
          parse_ok=0.0,
        )

      write_metrics(payload, {"channel_plugin": loaded})
      return 0

    if __name__ == "__main__":
      sys.exit(main())
  '';
in
{
  systemd.services.openclaw-canary = {
    description = "OpenClaw gateway log → Prometheus textfile metrics";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${canaryScript}";
      # Runs as nobody:nogroup — only reads the shared virtiofs log dir (group
      # readable) and writes into the textfile dir (which node_exporter runs
      # as its own user; the file must be world-readable).
      User = "nobody";
      Group = "nogroup";
      UMask = "0022";
      ReadOnlyPaths = [ "/var/lib/openclaw/.openclaw/logs" ];
      ReadWritePaths = [ textfileDir ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.timers.openclaw-canary = {
    description = "Run the OpenClaw gateway canary every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      Persistent = true;
      Unit = "openclaw-canary.service";
    };
  };

  # Make sure the textfile dir exists with the right permissions.
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
  ];
}
```

- [ ] **Step 2: Wire the new module into the imports list**

Identify which file imports the monitoring/services modules:

```
grep -rn 'openclaw-canary\|monitoring/services' /etc/nixos/modules/monitoring/default.nix 2>&1
grep -rn 'monitoring/services' /etc/nixos/configuration.nix /etc/nixos/modules/**/default.nix 2>&1 | head
```

Then add `./services/openclaw-canary.nix` (relative to the file's directory) to the `imports` list in the correct module.

- [ ] **Step 3: Deploy**

```
sudo nixos-rebuild switch --flake '.#vulcan'
sudo systemctl start openclaw-canary.service
sudo systemctl status openclaw-canary.service --no-pager | head -20
```

- [ ] **Step 4: Verify metrics**

```
cat /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom
```

Expected: non-empty, `openclaw_canary_parse_ok 1.0`, `openclaw_gateway_ready_plugins_total 5.0` (or however many plugins Task 1's rebuild produced), and `openclaw_channel_plugin_loaded{channel="discord"} 1.0`.

Then verify Prometheus is scraping it:

```
curl -s 'http://localhost:9100/metrics' | grep -E 'openclaw_(gateway|channel|canary)_' | head
```

- [ ] **Step 5: Commit**

```
cd /etc/nixos
git add modules/monitoring/services/openclaw-canary.nix modules/monitoring/default.nix
git commit -m "Add OpenClaw gateway canary → Prometheus textfile metrics"
```

---

## Task 4: Add Alertmanager rules for the canary metrics

**Files:**
- Create: `/etc/nixos/modules/monitoring/alerts/openclaw.yaml`

**Rationale:** The canary is only useful if Prometheus alerts when the metrics turn red. Rules:
- `OpenClawDiscordPluginMissing`: the discord plugin is not in the most-recent ready line for 10 minutes.
- `OpenClawPluginInitFailureMetric`: the plugin init failure counter is > 0 for 5 minutes.
- `OpenClawCanaryStale`: the canary hasn't run in 10 minutes (the canary itself is broken or nobody is running it).
- `OpenClawGatewayReadyStale`: the last gateway-ready line is older than 30 minutes while the microVM unit is active (OpenClaw crashed on start and never became ready).
- `OpenClawMicroVMDown`: the microVM systemd unit failed.

- [ ] **Step 1: Create the rules file**

Create `/etc/nixos/modules/monitoring/alerts/openclaw.yaml`:

```yaml
groups:
  - name: openclaw_availability
    interval: 60s
    rules:
      - alert: OpenClawDiscordPluginMissing
        expr: openclaw_channel_plugin_loaded{channel="discord"} == 0
        for: 10m
        labels:
          severity: critical
          category: availability
          service: openclaw
        annotations:
          summary: "OpenClaw discord plugin has been missing for 10 minutes"
          description: |
            The most recent [gateway] ready line did not include `discord`
            in its plugin list. This is the exact symptom of the 2026-04-22
            workspace:* regression. Check
            /var/lib/openclaw/.openclaw/logs/gateway-vm.err.log.

      - alert: OpenClawChannelPluginMissing
        expr: openclaw_channel_plugin_loaded{channel!="discord"} == 0
        for: 15m
        labels:
          severity: warning
          category: availability
          service: openclaw
        annotations:
          summary: "OpenClaw {{ $labels.channel }} plugin has been missing for 15 minutes"
          description: |
            The most recent [gateway] ready line did not include
            `{{ $labels.channel }}` in its plugin list.

      - alert: OpenClawPluginInitFailuresPresent
        expr: openclaw_plugin_init_failures_recent_total > 0
        for: 5m
        labels:
          severity: critical
          category: availability
          service: openclaw
        annotations:
          summary: "OpenClaw recent plugin init failures detected"
          description: |
            {{ $value }} plugin init failure lines in the last ~hour of
            gateway-vm.err.log. Indicates a recent broken restart.

      - alert: OpenClawCanaryStale
        expr: (time() - openclaw_canary_last_run_timestamp_seconds) > 600
        for: 5m
        labels:
          severity: warning
          category: monitoring
          service: openclaw
        annotations:
          summary: "OpenClaw canary hasn't run in >10 minutes"
          description: |
            openclaw-canary.timer is not firing or the script is erroring.
            Check `systemctl status openclaw-canary.service`.

      - alert: OpenClawGatewayReadyStale
        expr: |
          openclaw_gateway_ready_age_seconds > 1800
          and on() (systemd_unit_state{name="microvm@openclaw.service", state="active"} == 1)
        for: 10m
        labels:
          severity: critical
          category: availability
          service: openclaw
        annotations:
          summary: "OpenClaw microVM is active but gateway hasn't logged 'ready' in 30 minutes"
          description: |
            Either OpenClaw crashed during startup after Task 1's fix and is
            restarting in a loop, or the log file is stale. Inspect
            `systemctl status microvm@openclaw` and gateway-vm.err.log.

      - alert: OpenClawMicroVMDown
        expr: |
          systemd_unit_state{
            name="microvm@openclaw.service",
            state="failed",
            type="service"
          } == 1
        for: 2m
        labels:
          severity: critical
          category: availability
          service: openclaw
        annotations:
          summary: "OpenClaw microVM systemd unit is in failed state"
          description: "`systemctl status microvm@openclaw.service` for details."
```

- [ ] **Step 2: Verify the rules file is picked up**

`/etc/nixos/modules/monitoring/services/alerting.nix:23` reads `alertRuleFiles` — check that it globs `alerts/*.yaml` automatically. If not, register the new file explicitly.

```
grep -n 'alertRuleFiles\|alerts/\*' /etc/nixos/modules/monitoring/services/alerting.nix | head -20
```

- [ ] **Step 3: Deploy and verify**

```
sudo nixos-rebuild switch --flake '.#vulcan'
sudo systemctl reload prometheus.service 2>/dev/null || sudo systemctl restart prometheus.service
curl -s http://localhost:9090/api/v1/rules | \
  python3 -c 'import sys,json; d=json.load(sys.stdin); print([g["name"] for gs in d["data"]["groups"] for g in [gs]])' 2>&1 | \
  grep -o openclaw_availability
```

Expected: `openclaw_availability` printed once.

- [ ] **Step 4: Commit**

```
cd /etc/nixos
git add modules/monitoring/alerts/openclaw.yaml
git commit -m "Add Prometheus alert rules for OpenClaw availability"
```

---

## Task 5: End-to-end smoke test

- [ ] **Step 1: Verify Discord works by DMing the bot**

This is the only test that can't be automated from the host side without adding Discord API credentials. The user should send a DM to the Claw bot and confirm it replies. If it does, the break is resolved.

- [ ] **Step 2: Synthetic failure test — inject a fake failure into the log and verify the Loki alert fires**

Send a marker line to Loki via the microvm journal (systemd-cat as a harmless user) to verify the rule pipeline:

```
# This will fire OpenClawPluginInitFailure briefly and then clear. Uses the
# `openclaw-canary-test` unit so it doesn't pollute the real unit's journal.
echo "canary-test: [plugins] 1 plugin(s) failed to initialize (validation: test)" | \
  sudo systemd-cat -t openclaw-canary-test
```

Wait 2–3 minutes, then:

```
curl -s 'http://localhost:9093/api/v2/alerts' | \
  python3 -c 'import json,sys; [print(a["labels"].get("alertname"), a["status"]["state"]) for a in json.load(sys.stdin) if "openclaw" in a["labels"].get("alertname","").lower()]'
```

(NB: this alert uses the `microvm@openclaw.service` unit-label filter, so the test message will NOT trigger it unless you extend the rule temporarily. This test is optional; the Loki rule is validated by UI inspection instead.)

- [ ] **Step 3: Verify Alertmanager routing**

Confirm the openclaw alerts route to the same receiver as other critical alerts:

```
curl -s http://localhost:9093/api/v2/status | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("config", {}).get("original", "")[:1000])'
```

(Look for a receiver that handles `severity: critical` and `category: availability`.)

---

## Rollback

If Task 1's patch causes a different failure (the rewrite logic breaks some plugin), roll back the single commit and use the previous system generation:

```
cd /etc/nixos
git revert HEAD
sudo nixos-rebuild switch --flake '.#vulcan'
```

Or boot-time rollback (does not require rebuild):

```
sudo /nix/var/nix/profiles/system-1797-link/bin/switch-to-configuration switch
```

Generation 1797 is the last known-good system from 2026-04-21 before the breaking flake.lock bump.
