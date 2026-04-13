# OpenClaw Comprehensive Health Check System

**Date:** 2026-04-13
**Status:** Approved design, pending implementation
**Approach:** A -- Single NixOS module with systemd oneshot services

## Overview

A two-tier health check system for the OpenClaw microVM:

1. **Build-time assertions** in the host NixOS module catch configuration errors before deploy
2. **Post-deploy connectivity checks** run automatically on every VM boot
3. **Full round-trip functional tests** run on demand via `sudo openclaw-health --full`

The system replaces the existing `openclaw-tool-test` service (which only covers a subset of integrations) with a comprehensive test suite covering all 10 integration points.

---

## System Context

### Architecture

```
Host (vulcan, aarch64-linux)              Guest microVM (openclaw-vm)
br-openclaw 10.99.0.1/30  <--TAP-->      eth0 10.99.0.2/30
      |                                        |
      +-- DNAT to 127.0.0.1:PORT               +-- nftables DNAT
      |   (route_localnet=1)                    |   127.0.0.1:PORT -> 10.99.0.1:PORT
      |                                        |
Services on host loopback:                 OpenClaw gateway :18789
  - LiteLLM :4000 (Podman)                   - memory-qdrant plugin (Qdrant client)
  - Qdrant :6333/:6334/:6335                  - whatsapp plugin (bundled)
  - PostgreSQL :5432                          - discord plugin (bundled)
  - Dovecot IMAPS :993                        - acpx plugin (Claude Code)
  - Postfix SMTP :2525                        - himalaya CLI (IMAP/SMTP)
  - Radicale CardDAV :5232                    - sherlock-db CLI (PostgreSQL)
  - Home Assistant :8123                      - org-db-search CLI (pgvector)
  - nginx :443 (TLS proxy)                   - email-contacts MCP server
```

### Key Files

| File | Role |
|------|------|
| `modules/services/openclaw-microvm.nix` | Host-side VM definition, DNAT, secrets staging (~605 lines) |
| `modules/services/openclaw-vm.nix` | Guest-side NixOS config, services, preStart (~1163 lines) |
| `modules/services/openclaw.nix` | Legacy standalone service (NOT imported, ignore) |
| `modules/services/qdrant.nix` | Qdrant vector DB service |
| `modules/services/qdrant-inference-bridge.nix` | Qdrant inference -> LiteLLM embeddings bridge |
| `modules/services/databases.nix` | PostgreSQL with openclaw user, org DB grants |
| `modules/containers/litellm-quadlet.nix` | LiteLLM Podman container |
| `scripts/email-contacts-mcp.py` | MCP server for IMAP/SMTP/contacts |
| `overlays/sherlock.nix` | Sherlock DB CLI overlay |

### DNAT Port Map

All ports use two-stage DNAT: guest 127.0.0.1:PORT -> 10.99.0.1:PORT -> host 127.0.0.1:PORT

| Port | Service | Auth |
|------|---------|------|
| 443 | nginx HTTPS | TLS certs (Step-CA) |
| 993 | Dovecot IMAPS | SASL (password from SOPS `email-tester-imap-password`) |
| 2525 | Postfix SMTP | SASL via Dovecot |
| 4000 | LiteLLM | Bearer token (master key in openclaw.json) |
| 5232 | Radicale CardDAV | HTTP Basic (password from SOPS `vdirsyncer-johnw/radicale-password`) |
| 5432 | PostgreSQL | scram-sha-256 (password from SOPS `openclaw/org-db-password`) |
| 6333 | Qdrant HTTP | api-key header (from SOPS `qdrant/api-key`) |
| 6334 | Qdrant gRPC | api-key header |
| 6335 | Qdrant inference bridge | Bearer token `sk-1234` |
| 8123 | Home Assistant | Long-lived access token |

### Current State of Integrations (as of 2026-04-13)

All verified from logs and live queries:

| Integration | Status | Evidence |
|-------------|--------|----------|
| LiteLLM | Running | Host :4000 active, used by memory-qdrant for embeddings |
| Qdrant | Working | 66 points in `openclaw_memories` collection, connection verified in logs |
| PostgreSQL/Sherlock | Working | Existing tool-test passes `SELECT count(*) FROM entries` |
| Perplexity | Configured | API key staged to VM, loaded as env var |
| org-db-search | Working | Existing tool-test passes semantic search |
| IMAP | Working | Existing tool-test lists envelopes and searches |
| SMTP | Working | Existing tool-test sends via himalaya |
| WhatsApp | Active | Log: `[whatsapp] Listening for personal WhatsApp inbound messages` |
| Discord | Active | Log: `[discord] client initialized as 1477036366138445905 (Claw)` |
| Stocks/Options | Configured | `financialPython` package in PATH (pandas, yahooquery, py_vollib) |

### Important Finding

OpenClaw falsely reported to the user that memory-qdrant was using "in-memory mode." The logs and Qdrant collection data prove it IS using the external persistent Qdrant. The health checks should verify this authoritatively so the user doesn't have to trust OpenClaw's self-report.

---

## Design

### New Files

1. **`modules/services/openclaw-health-check.nix`** -- Guest-side health check module (imported by `openclaw-vm.nix`)
2. **`scripts/openclaw-health`** -- Host-side wrapper script (installed to system PATH)

### Removed Code

- The existing `openclaw-tool-test` service in `openclaw-vm.nix` (lines 949-1156) is **replaced** by the new module. Delete it entirely.

### Module: `openclaw-health-check.nix`

This module is imported by `openclaw-vm.nix` and defines two systemd services inside the guest VM.

#### Service 1: `openclaw-health.service` (connectivity, runs on boot)

- **Type:** oneshot, `RemainAfterExit = true`
- **After:** `openclaw.service`
- **WantedBy:** `multi-user.target`
- **User:** openclaw
- **Output:** `${openclawDir}/logs/health-check.txt`
- **Exit code:** 0 if all checks pass, 1 if any fail

Connectivity checks (TCP + auth handshake where possible):

| # | Test | Method | Pass Criteria |
|---|------|--------|---------------|
| 1 | LiteLLM reachable | `curl http://127.0.0.1:4000/health` | HTTP 200 |
| 2 | Qdrant reachable | `curl http://127.0.0.1:6333/healthz` | HTTP 200 |
| 3 | Qdrant authenticated | `curl -H "api-key: $KEY" http://127.0.0.1:6333/collections` | HTTP 200, JSON parseable |
| 4 | Qdrant collection exists | Parse collections response | `openclaw_memories` present with points_count > 0 |
| 5 | Qdrant inference bridge | `curl http://127.0.0.1:6335/health` or TCP connect :6335 | Connection succeeds |
| 6 | PostgreSQL reachable | `sherlock -c org query "SELECT 1"` | Exit 0 |
| 7 | PostgreSQL org data | `sherlock -c org query "SELECT count(*) FROM entries"` | Exit 0, count > 0 |
| 8 | IMAP TCP connect | `/dev/tcp/imap.vulcan.lan/993` | TCP handshake succeeds |
| 9 | IMAP login | `himalaya envelope list --account johnw --folder INBOX -s 1 -p 1` | Exit 0 |
| 10 | SMTP TCP connect | `/dev/tcp/smtp.vulcan.lan/2525` | Banner starts with `220` |
| 11 | CardDAV Radicale | `curl -X PROPFIND -H "Depth: 0" -u user:pass http://radicale.vulcan.lan:5232/johnw/` | HTTP 207 |
| 12 | khard contacts | `khard list` | Exit 0, count > 0 |
| 13 | Perplexity API key | `test -n "$PERPLEXITY_API_KEY"` | Non-empty |
| 14 | Financial tools | `python3 -c "import yahooquery; import py_vollib"` | Exit 0 |
| 15 | WhatsApp plugin | `grep -q "whatsapp.*Listening" $GATEWAY_LOG` | Match found |
| 16 | Discord plugin | `grep -q "discord.*client initialized" $GATEWAY_LOG` | Match found |
| 17 | LiteLLM models | `curl http://127.0.0.1:4000/v1/models` | HTTP 200, at least 1 model |
| 18 | OpenClaw gateway | `curl -s http://127.0.0.1:18789/health` or similar endpoint | HTTP 200 |

#### Service 2: `openclaw-health-full.service` (round-trip, manual only)

- **Type:** oneshot
- **After:** `openclaw.service`
- **WantedBy:** (none -- manual trigger only)
- **User:** openclaw
- **Output:** `${openclawDir}/logs/health-check-full.txt`
- **Exit code:** 0 if all checks pass, 1 if any fail

Round-trip functional tests (in addition to all connectivity checks):

| # | Test | Method | Pass Criteria |
|---|------|--------|---------------|
| 1 | LiteLLM completion | `curl POST /v1/chat/completions` with model `hera/gpt-4o-mini` (cheapest), prompt "Reply with the word PONG" | Response contains "PONG" |
| 2 | LiteLLM embeddings | `curl POST /v1/embeddings` with model `hera/bge-m3`, input "test" | Response has embedding array of length 1024 |
| 3 | Qdrant store+retrieve | Store a test vector with known payload, search for it, verify similarity > 0.9, then delete it | Full CRUD cycle succeeds |
| 4 | Sherlock rich query | `sherlock -c org query "SELECT id, title FROM entries LIMIT 5 -f json"` | Valid JSON with rows |
| 5 | org-db-search | `org-db-search "home automation" -n 3` | Exit 0, non-empty output |
| 6 | SMTP send | `himalaya message send` a test email to `johnw@vulcan.lan` | Exit 0 |
| 7 | IMAP search | `himalaya envelope list --folder INBOX "from wiegley"` | Exit 0, results returned |
| 8 | Perplexity search | `curl POST https://api.perplexity.ai/chat/completions` with a simple query | HTTP 200, response has content |
| 9 | Financial: stock quote | `python3 -c "from yahooquery import Ticker; t = Ticker('AAPL'); print(t.price['AAPL']['regularMarketPrice'])"` | Prints a number |
| 10 | Financial: options | `python3 -c "from yahooquery import Ticker; t = Ticker('AAPL'); print(len(t.option_chain))"` | Prints a number > 0 |
| 11 | CardDAV full sync | `vdirsyncer sync` + `khard email --search "Wiegley"` | Both succeed, search returns results |

**Notes on test costs:**
- Test 1 (LiteLLM completion): Uses cheapest model, ~$0.001 per run
- Test 8 (Perplexity): Costs one API call, ~$0.005 per run
- All other tests: No external API cost

### Host-Side Wrapper Script: `openclaw-health`

Installed to system PATH via `environment.systemPackages`. Provides a clean CLI for the user.

```bash
#!/usr/bin/env bash
# Usage: sudo openclaw-health [--full] [--quiet]

set -euo pipefail

FULL=false
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --full) FULL=true ;;
    --quiet) QUIET=true ;;
    *) echo "Usage: openclaw-health [--full] [--quiet]"; exit 1 ;;
  esac
done

VM_NAME="openclaw"

# Check VM is running
if ! systemctl is-active --quiet "microvm@${VM_NAME}"; then
  echo "FAIL: microvm@${VM_NAME} is not running"
  exit 1
fi

if $FULL; then
  SERVICE="openclaw-health-full"
  LOG="/var/lib/openclaw/.openclaw/logs/health-check-full.txt"
else
  SERVICE="openclaw-health"
  LOG="/var/lib/openclaw/.openclaw/logs/health-check.txt"
fi

# Trigger the test inside the VM via machinectl
machinectl shell "${VM_NAME}" /run/current-system/sw/bin/systemctl start "${SERVICE}" 2>&1

# Display results
if [ -f "$LOG" ]; then
  if $QUIET; then
    # Just show PASS/FAIL summary
    grep -E "^(PASS|FAIL|SKIP):" "$LOG"
  else
    cat "$LOG"
  fi

  # Exit with failure if any FAIL lines exist
  if grep -q "^FAIL:" "$LOG"; then
    exit 1
  fi
else
  echo "FAIL: Log file not found at $LOG"
  exit 1
fi
```

**Note:** The `machinectl shell` approach requires that the microVM is registered as a systemd machine. If that doesn't work for QEMU microVMs, an alternative is to use `ssh openclaw@10.99.0.2 systemctl start ...` (requires SSH key setup) or to read the log file directly after triggering via a host-side mechanism. The implementer should verify which method works with the current microVM setup and adjust accordingly. A simpler fallback: have the host script just `systemctl start microvm-openclaw-health-trigger` which writes a flag file to the shared virtiofs, and a guest-side path unit watches for it.

### Build-Time Assertions

Add to `openclaw-microvm.nix`:

```nix
config.assertions = [
  {
    assertion = config.services.qdrant.enable;
    message = "OpenClaw requires Qdrant to be enabled";
  }
  {
    assertion = config.services.postgresql.enable;
    message = "OpenClaw requires PostgreSQL to be enabled";
  }
  {
    assertion = builtins.elem 6333 dnatPorts;
    message = "OpenClaw DNAT ports must include 6333 (Qdrant HTTP)";
  }
  {
    assertion = builtins.elem 6334 dnatPorts;
    message = "OpenClaw DNAT ports must include 6334 (Qdrant gRPC)";
  }
  {
    assertion = builtins.elem 4000 dnatPorts;
    message = "OpenClaw DNAT ports must include 4000 (LiteLLM)";
  }
  {
    assertion = builtins.elem 5432 dnatPorts;
    message = "OpenClaw DNAT ports must include 5432 (PostgreSQL)";
  }
  {
    assertion = builtins.elem 993 dnatPorts;
    message = "OpenClaw DNAT ports must include 993 (Dovecot IMAPS)";
  }
  {
    assertion = builtins.elem 2525 dnatPorts;
    message = "OpenClaw DNAT ports must include 2525 (Postfix SMTP)";
  }
  {
    assertion = config.sops.secrets ? "qdrant/api-key";
    message = "OpenClaw requires SOPS secret 'qdrant/api-key'";
  }
  {
    assertion = config.sops.secrets ? "openclaw/org-db-password";
    message = "OpenClaw requires SOPS secret 'openclaw/org-db-password'";
  }
  {
    assertion = config.sops.secrets ? "openclaw/perplexity-api-key";
    message = "OpenClaw requires SOPS secret 'openclaw/perplexity-api-key'";
  }
];
```

### Output Format

Both services produce structured output for easy parsing:

```
=== OpenClaw Health Check (connectivity) ===
Time: 2026-04-13T12:00:00Z
Mode: connectivity

--- LiteLLM ---
PASS: LiteLLM health endpoint (HTTP 200)
PASS: LiteLLM models available (14 models)

--- Qdrant ---
PASS: Qdrant health endpoint (HTTP 200)
PASS: Qdrant authenticated (HTTP 200)
PASS: openclaw_memories collection exists (66 points)
PASS: Qdrant inference bridge reachable

--- PostgreSQL / Sherlock ---
PASS: PostgreSQL reachable (SELECT 1)
PASS: org database has entries (count: 12847)

--- IMAP ---
PASS: IMAP TCP port 993 reachable
PASS: IMAP login + envelope list succeeded

--- SMTP ---
PASS: SMTP banner received (220 vulcan.lan ESMTP)

--- CardDAV ---
PASS: Radicale PROPFIND succeeded (HTTP 207)
PASS: khard contacts available (342 contacts)

--- Perplexity ---
PASS: PERPLEXITY_API_KEY is set (53 chars)

--- Financial Tools ---
PASS: yahooquery importable
PASS: py_vollib importable

--- Chat Channels ---
PASS: WhatsApp plugin active (listening for messages)
PASS: Discord plugin active (client initialized)

--- OpenClaw Gateway ---
PASS: Gateway responding on :18789

=== Summary: 18/18 PASS, 0 FAIL, 0 SKIP ===
```

### Integration with Existing Service

The existing `openclaw-tool-test` service in `openclaw-vm.nix` (lines 949-1156) should be **deleted** and replaced by importing the new module. The new module covers all tests from the old service plus many more.

In `openclaw-vm.nix`, replace:
```nix
# DELETE the entire systemd.services.openclaw-tool-test block (lines 949-1156)
```

And add an import:
```nix
imports = [
  ./openclaw-health-check.nix
];
```

The new module needs the same `openclawVmArgs` passed through, so it should use the same `specialArgs` pattern.

### Module Interface

`openclaw-health-check.nix` should accept the following from `openclawVmArgs`:
- `stateDir` -- `/var/lib/openclaw`
- `openclawDir` -- computed as `${stateDir}/.openclaw` (or passed directly)
- `servicePort` -- `18789`
- `bridgeAddr` -- `10.99.0.1`

And needs access to these packages (already in the VM's service PATH):
- `curl`, `jq`, `coreutils`, `gnugrep`, `socat`
- `himalaya`, `sherlock-db`, `orgDbSearch`
- `khardFixed` (khard with vCard4 fix)
- `financialPython` (Python with yahooquery, py_vollib)
- `vdirsyncer`

### Secrets Access

The health check service runs as `openclaw` and reads secrets from:
- `/run/openclaw-secrets/imap-password` -- IMAP auth test
- `/run/openclaw-secrets/radicale-password` -- CardDAV auth test
- `/run/openclaw-secrets/perplexity-api-key` -- Perplexity key presence check
- Qdrant API key is read from `openclaw.json` via jq (already in the deployed config)
- LiteLLM master key is read from `openclaw.json` via jq

The full test additionally needs:
- LiteLLM key for `/v1/chat/completions` and `/v1/embeddings` calls
- Perplexity key for the search API call

### Triggering on Config Changes

To ensure tests run when relevant services change, add `After=` and `Wants=` dependencies. The connectivity test already runs on boot via `wantedBy = ["multi-user.target"]`, so any rebuild that restarts the VM will trigger it.

For the host-side, add to `openclaw-microvm.nix`:

```nix
# Re-run health check whenever the VM restarts
systemd.services."openclaw-health-trigger" = {
  description = "Trigger OpenClaw health check after VM restart";
  after = [ "microvm@openclaw.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    # Wait for the VM to fully boot and OpenClaw to start
    ExecStartPre = "${pkgs.coreutils}/bin/sleep 30";
    ExecStart = "${openclaw-health-script}/bin/openclaw-health --quiet";
  };
};
```

This means every `nixos-rebuild switch` that changes OpenClaw, Qdrant, PostgreSQL, LiteLLM, Dovecot, or Postfix config will restart the VM (or relevant services), which triggers the health check automatically.

---

## Implementation Checklist

1. Create `modules/services/openclaw-health-check.nix`
   - Define connectivity test service (boot-time)
   - Define full round-trip test service (manual)
   - Accept `openclawVmArgs` via specialArgs
   - Structured output format with PASS/FAIL/SKIP

2. Create `scripts/openclaw-health` wrapper
   - `--full` flag for round-trip tests
   - `--quiet` flag for summary-only output
   - Verify VM is running before triggering
   - Parse and display results from log file
   - Exit code reflects test results

3. Modify `modules/services/openclaw-vm.nix`
   - Delete `openclaw-tool-test` service (lines 949-1156)
   - Import new `openclaw-health-check.nix` module
   - Pass required args through specialArgs

4. Modify `modules/services/openclaw-microvm.nix`
   - Add build-time assertions for required services and DNAT ports
   - Add build-time assertions for required SOPS secrets
   - Install `openclaw-health` script to system PATH
   - Add optional `openclaw-health-trigger` service for post-restart auto-check

5. Test
   - `nixos-rebuild build` -- verify assertions pass
   - `nixos-rebuild switch` -- verify connectivity tests run on VM boot
   - `sudo openclaw-health` -- verify wrapper shows results
   - `sudo openclaw-health --full` -- verify round-trip tests work
   - Intentionally break a DNAT port and verify assertion catches it
   - Verify log files are written to expected locations

---

## Edge Cases and Considerations

### WhatsApp and Discord Detection

These plugins initialize asynchronously after OpenClaw starts. The health check must wait or retry:
- Parse `gateway-vm.log` for initialization messages
- WhatsApp: look for `[whatsapp] Listening for personal WhatsApp inbound messages`
- Discord: look for `[discord] client initialized`
- Allow up to 60 seconds of log scanning (these plugins may take time to connect)
- If no log entry found within timeout, report SKIP (not FAIL) since these depend on external services

### Qdrant "In-Memory Mode" Detection

The health check should explicitly verify the plugin is NOT using in-memory mode:
- Check `gateway-vm.log` for `using Qdrant at http://127.0.0.1:6333` (PASS)
- Check for `using in-memory storage` (FAIL -- this means external Qdrant connection failed)
- Check for `Qdrant connection verified` (PASS)
- Check for `Qdrant health check failed` (FAIL)

### LiteLLM Container Startup

LiteLLM runs as a Podman Quadlet container and may take 30-60 seconds to start. The health check should retry the `/health` endpoint with exponential backoff (3 attempts, 5/10/20 second delays).

### Financial Tools Test Isolation

The full test for stock quotes (`yahooquery`) makes external API calls to Yahoo Finance. These are free but may be rate-limited or fail if the network is down. Mark as SKIP (not FAIL) if the error is a network timeout, but FAIL if the Python imports fail (which indicates a package issue).

### Perplexity Full Test

The full Perplexity round-trip test costs ~$0.005 per call. Use the cheapest model (`sonar`) and a minimal prompt. The test should use a deterministic query that produces a short response.

### machinectl vs Alternative Triggering

The QEMU-based microVM may not register with `machinectl` the same way container-based VMs do. If `machinectl shell` doesn't work, alternatives:

1. **Shared virtiofs signal file:** Host writes `/var/lib/openclaw/.openclaw/run-health-check` flag, guest path unit watches for it
2. **SSH:** Configure SSH key auth for the openclaw user, use `ssh -o ... openclaw@10.99.0.2 systemctl start ...`
3. **Direct log reading:** Host script just reads the log file produced by the boot-time service (no need to trigger; it already ran)

The implementer should test `machinectl list` to see if `openclaw-vm` appears, and fall back to option 3 (simplest) if it doesn't.

### Log Rotation

Health check logs are written to `${openclawDir}/logs/`. Since these are small (a few KB each) and overwritten on each run, no rotation is needed. The full test log should overwrite (not append) to avoid unbounded growth.
