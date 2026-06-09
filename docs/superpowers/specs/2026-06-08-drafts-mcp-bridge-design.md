# Drafts MCP Bridge (hera) → OpenClaw / Hermes / Host Claude Code — Design

**Date:** 2026-06-08
**Status:** Approved (design), pending spec review + user sign-off — STOPS BEFORE the implementation spec/plan
**Author:** Claude (Opus 4.8) with John Wiegley
**Topic slug:** `drafts-mcp-bridge`
**Repos touched:** `/Users/johnw/src/nixos` (vulcan/NixOS), `/Users/johnw/src/nix` (hera/darwin), `/Users/johnw/src/promptdeploy`

---

## 1. Goal

Let three consumers drive the **Drafts.app** MCP tools, where Drafts runs **only** on the macOS host **hera**:

1. **Host Claude Code** (`claude-vulcan` — runs on the vulcan *host*, not a VM) — plain SSH-stdio to hera.
2. **OpenClaw** agentic microVM (`10.99.0.2`) — remote MCP-SSE through a host-side bridge, reached via the existing two-stage DNAT chain.
3. **Hermes** agentic microVM (`10.99.1.2`) — same SSE bridge, reached via the `hermes-br0` DNAT chain.

The deliverable is a host-side **`drafts-mcp.service`** on vulcan that bridges a remote **stdio** MCP server on hera (`drafts-mcp-server`, already packaged) to an **SSE** endpoint on `127.0.0.1`, plus the two-repo wiring (SSH key authorization on hera, MCP registration in each consumer) and monitoring — while preserving microVM egress isolation and giving autonomous agents a **least-privilege, write-gated** tool surface.

## 2. Non-goals / Scope

- **NOT** packaging a new long-lived Python service like `hermes-mcp` *unless* tool-filtering forces it (see Decision D2; a thin stdio shim is preferred over a full FastMCP rewrite).
- **NOT** widening guest egress beyond a single new loopback DNAT port per bridge.
- **NOT** giving the agentic VMs direct SSH/LAN access to hera.
- **NOT** porting the `hermes-mcp` 30 s progress-heartbeat or SQLite session store — Drafts ops are fast and stateless.
- **NOT** authoring the implementation spec or the phased execution plan with code — this document precedes them.

## 3. Constraints & established facts

### 3.1 Verified this session (primary sources)

| Fact | Evidence |
|---|---|
| `pkgs.mcp-proxy` is **0.10.0** and supports SSE **server mode** | `nix eval nixpkgs#mcp-proxy.version` → `"0.10.0"`; `--help` shows `--port`/`--host` (default `127.0.0.1`) + positional `command_or_url`; example `mcp-proxy --port 8080 -- your-command`. CORS off unless `--allow-origin`. |
| Server mode serves `/sse` **and** `/mcp` simultaneously; `--transport` is **client-only** | `mcp_server.py:128-136` mounts `Route("/mcp")`, `Route("/sse")`, `Mount("/messages/")`, `Route("/status")` unconditionally. `--transport` consumed only in the client branch. |
| mcp-proxy spawns **ONE** stdio child at startup, never per-session, never respawns | `mcp_server.py:154,170` — `AsyncExitStack` + single `stdio_client(default_server_params)` for the uvicorn lifetime. |
| A dead backend leaves a **silent green zombie** | `proxy_server.py:93-104` — `_call_tool` catches `Exception` and returns `isError=True`; the proxy process does **not** exit, so `Restart=on-failure` never fires for steady-state backend death. |
| hermes-agent locked rev is **`fd1e7c2bc356d773589320051853f8e058ca636e`** (not `c47b9d12`) | `flake.lock` line 1006-1027. |
| hermes-agent `mcpServers` submodule: `url`/`headers`/`auth`/`enabled`/`timeout`/`connect_timeout`/`tools.{include,exclude}`/`sampling`; **NO `description` field** | `nixosModules.nix:333-430` at the locked rev. `tools` is `nullOr (submodule { include=[…]; exclude=[…]; })`, default `null`. |
| promptdeploy `validate` dedups `(item_type, name)` **globally, BEFORE** only/except filtering; the yaml `name:` field overrides the filename stem | `validate.py:62-78`; `source.py:140` (`name = metadata.get("name", base_name)`). Two files both `name: drafts` → **`validate` errors out** (and the lefthook pre-commit gate fails). The runtime `deploy` path is unaffected (per-target `should_deploy_to`). |
| `drafts-mcp-server` is **v1.0.12**, exposes **20 tools** | `/Users/johnw/src/nix/overlays/30-ai-mcp.nix:198-219`; upstream `src/index.ts` at tag `v1.0.12`. |
| `drafts_run_action` exists and is **NOT read-only** | `index.ts:277` `name: 'drafts_run_action'`, `readOnlyHint: false`. |
| OpenClaw `del(.mcpServers["drafts"])` is at `openclaw-vm.nix:862`; hermes SSE entry pattern at `:877` | grep. |
| `9082` is free; ports.txt bridge format is a **single loopback line** (no `10.99.x.1` mirror lines) | `docs/ports.txt:124-126` — 9081 has exactly two `127.0.0.1` lines (bridge + smoke), no bridge-IP entries. |

**Drafts tool surface (v1.0.12), classified by `readOnlyHint`:**

| Read-only (11) | Mutating / state-changing (9) |
|---|---|
| `drafts_list_workspaces`, `drafts_list_tags`, `drafts_get_tag`, `drafts_get_current_workspace`, `drafts_get_current`, `drafts_get_workspace_drafts`, `drafts_get_drafts`, `drafts_get_draft`, `drafts_search`, `drafts_list_actions`, `drafts_open` | `drafts_create_draft`, `drafts_update_draft`, `drafts_add_tags`, `drafts_flag`, `drafts_archive`, `drafts_inbox`, `drafts_trash`, `drafts_open_workspace`, **`drafts_run_action`** ⚠️ |

`drafts_run_action` runs a **named, already-installed Drafts action**; Drafts actions can contain Script steps with JS + shell-out, so it is effectively **code-exec as johnw on hera**, bounded to johnw's action library.

### 3.2 Proven SSH/AppleScript facts

- vulcan host → hera SSH works non-interactively (BatchMode key auth).
- AppleScript over SSH to hera works **when run as the interactive GUI user johnw** (`osascript "count drafts"` → 120). hera never sleeps (`pmset sleep 0`).

### 3.3 UNPROVEN — the #1 risk (TCC/Automation-as-a-service)

macOS TCC Automation (`kTCCServiceAppleEvents`) is keyed on **(user, responsible-process, target-app)** and requires an active **Aqua** (console GUI) session. It is **NOT validated** whether a **long-lived, boot-spawned, non-GUI** SSH session as johnw — originated by a hardened systemd service — retains the Drafts grant, or returns `-1743 (not authorized)`. TCC grants do **not** propagate across users; a dedicated service user would almost certainly fail. See §6.

### 3.4 Network / isolation

- vulcan = `192.168.1.2` (LAN); hera = `hera.lan` on the same `192.168.1.0/24`. vulcan is **not** on the tailnet, so vulcan↔hera is over the LAN.
- microVM bridges are loopback-bound: openclaw gw `10.99.0.1`/`br-openclaw`; hermes gw `10.99.1.1`/`hermes-br0`. Guest egress is restricted to enumerated host-loopback DNAT ports + 443/53. A microVM **cannot** SSH to hera; it reaches host-loopback services only via the two-stage DNAT chain.

## 4. Architecture

```
                         ┌──────────────────────────── hera (macOS, johns-mac-studio) ───────────────────────────┐
                         │  sshd ──(authorized_keys forced-command, key drafts-bridge@vulcan)──► drafts-mcp-server │
                         │                                          │ (stdio MCP, 20 tools)                        │
                         │                                          ▼  osascript / AppleEvents                     │
                         │                                       Drafts.app  (johnw's Aqua GUI session)            │
                         └───────────────────────────────────────────▲──────────────────────────────────────────┘
                                                                      │  SSH-stdio over LAN 192.168.1.0/24
                                                                      │  (dedicated ed25519 key, BatchMode, pinned known_hosts)
   ┌───────────────────────────── vulcan (NixOS host, 192.168.1.2) ──┼───────────────────────────────────────────┐
   │                                                                  │                                            │
   │   claude-vulcan (host Claude Code) ─── plain SSH-stdio ──────────┘   (NO bridge; full toolset; operator)      │
   │                                                                                                               │
   │   drafts-mcp.service  ── mcp-proxy 0.10.0 server mode ──► single shared `ssh … drafts-mcp-server` child       │
   │      binds 127.0.0.1:9082   (serves /sse + /mcp)                                                              │
   │      [+ optional drafts-tool-filter stdio shim between mcp-proxy and ssh — drops write tools for VMs]         │
   │            ▲                                                                                                   │
   │   host PREROUTING DNAT (br-openclaw 10.99.0.1:9082 → 127.0.0.1:9082; hermes-br0 10.99.1.1:9082 → 127.0.0.1)   │
   │            ▲                                                                                                   │
   └────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┘
                │ two-stage DNAT (guest OUTPUT 127.0.0.1:9082 → bridge gw → host PREROUTING → 127.0.0.1:9082)
        ┌───────┴────────┐                                   ┌──────────────────┐
        │ OpenClaw VM    │ mcporter.json:                    │ Hermes VM        │ services.hermes-agent.mcpServers:
        │ 10.99.0.2      │   "drafts-hera": {url:.../sse}     │ 10.99.1.2        │   drafts-hera = { url=.../sse; tools.exclude=[…]; }
        └────────────────┘                                   └──────────────────┘
```

### End-to-end data flow (VM leg)

1. Agent (OpenClaw/Hermes) issues an MCP `tools/call` to `http://127.0.0.1:9082/sse`.
2. Guest nftables OUTPUT DNAT rewrites `127.0.0.1:9082 → <bridge-gw>:9082`; host PREROUTING DNAT rewrites back to `127.0.0.1:9082`.
3. `drafts-mcp.service` (mcp-proxy) forwards JSON-RPC over the **single shared** `ssh johnw@hera.lan` child.
4. hera's `authorized_keys` forced-command execs `drafts-mcp-server` (ignoring `SSH_ORIGINAL_COMMAND`); it drives Drafts via osascript.
5. Result returns up the same path. If the optional filter shim is present, write tools (esp. `drafts_run_action`) are stripped from `tools/list` and rejected on `tools/call` for the VM-facing endpoint.

### Host Claude Code leg

`claude-vulcan` (on the vulcan host, has LAN/SSH egress) bypasses the bridge entirely with a command-based ssh-stdio MCP entry — full toolset, operator-driven.

## 5. Decisions

| # | Decision | Choice | Rationale | Alternatives rejected |
|---|---|---|---|---|
| D1 | **Transport (bridge endpoint)** | MCP **SSE** at `http://127.0.0.1:9082/sse` | Byte-identical to the live, proven `hermes`@9081 consumer registration in both OpenClaw mcporter and Hermes `url`. mcp-proxy serves `/sse` **and** `/mcp` simultaneously, so streamable-HTTP is available free if ever needed. A plain loopback `http://…/sse` also sidesteps the mcporter 0.10.1 OAuth-metadata auto-probe that an HTTPS origin can trigger. | Streamable-HTTP-only (`/mcp`): diverges from the established registration shape for no Drafts-relevant benefit. |
| D2 | **Bridge tool** | `pkgs.mcp-proxy` **0.10.0 server mode** as the SSE adapter. **Conditionally** prefix a thin stdio **filter shim** between mcp-proxy and ssh **iff** write-tool denial to VMs is required (see D7). | mcp-proxy is already in-tree (`openclaw-vm.nix:117`, `hermes-vm.nix:209`), verified to bind `127.0.0.1` and serve `/sse`. `drafts-mcp-server` is already a complete 20-tool stdio server → only transport adaptation needed. The filter shim is ~15 lines of stdio JSON-RPC (a `writers.writePython3Bin`, no `pkgs/` dir / overlay / flake entry) and is the **only** enforcement point for OpenClaw. | **Custom FastMCP package** (`hermes-mcp` clone): rejected as default — `hermes-mcp` is custom only for Bearer auth + OpenAI translation + SQLite + heartbeat, none of which Drafts needs; a full `buildPythonApplication` adds a versioned, CI-built dependency surface for no gain over a shim. **supergateway**: rejected — not in nixpkgs, needs Node 24, **no `--host` flag** (binds `0.0.0.0`), violating loopback-only. |
| D3 | **VM transport path** | **New dedicated loopback DNAT port 9082** on both bridges. | 1:1 with hermes-mcp/9081: loopback-only, no nginx round-trip, no TLS cert, no CA-bundle plumbing in guests, no OAuth-probe risk. Widens egress by exactly **one** minimal port per bridge (the constraint's ceiling). All four derived rules (guest OUTPUT DNAT, host PREROUTING, INPUT allow, isolate RETURN) auto-derive from `dnatPorts`. | **`drafts.vulcan.lan` over 443/nginx**: zero new port but adds an nginx vhost + step-ca cert + `networking.hosts` in both guests + `REQUESTS_CA_BUNDLE` plumbing + OAuth-probe exposure — strictly more surface. Kept as documented fallback only. |
| D4 | **SSH identity** | **ssh as johnw** with a **dedicated ed25519 key** pinned by an `authorized_keys` **forced-command**. | TCC grants are per-user and require johnw's Aqua session; johnw is the only GUI user holding the Drafts grant. Least-privilege is enforced at the **key** layer, not by a Unix identity. | **Dedicated non-johnw service user on hera**: rejected — no Aqua session → almost certainly `-1743`. **Reusing `keyFiles`/Yubikey path**: rejected — grants unrestricted shell; no `id_vulcan.pub` exists. |
| D5 | **Port number** | **9082** (`127.0.0.1`). | Verified free in `docs/ports.txt` (9081 taken; 9082 unused), adjacent to the bridge band. Record as a **single** loopback line per the file's format. | 9083+: unnecessary. Re-verify against live `ss -ltnp` on vulcan before commit. |
| D6 | **MCP server name / collision** | Name the **vulcan host entry `drafts-hera`** (distinct from the Mac-local `drafts`). VM registries also use **`drafts-hera`**. The existing `mcp/drafts.yaml` stays `name: drafts`, `only: [claude-personal]`. | **CRITIQUE-DRIVEN REVERSAL of the proposals:** `promptdeploy validate` dedups `(item_type, name)` **globally before** only/except filtering (`validate.py:62-78`), so two files both `name: drafts` **error out** the validate + pre-commit gate. A distinct name is the only way to pass `validate`. Cost: cross-environment tool-name parity (agent calls `drafts-hera` on vulcan, `drafts` on the Mac) — acceptable and explicit. | **Two files both `name: drafts`, disjoint `only`**: rejected — fails `validate`. **Patching `validate.py` to dedup post-filter**: rejected — larger blast radius in a shared tool. |
| D7 | **`drafts_run_action` (and write tools) for autonomous VMs** | **Default: deny all 9 write tools (incl. `drafts_run_action`) to BOTH VMs.** Hermes: `tools.exclude` (or `tools.include` allowlist) at registration. OpenClaw: the **filter shim** (D2) is the sole enforcement point. Host Claude Code: **full toolset** (operator). | `drafts_run_action` = code-exec as johnw on hera; autonomous agents are the threat model. The `authorized_keys` forced-command does **NOT** restrict tools (the call flows as JSON-RPC over the pinned binary's stdin) — so denial MUST happen in the bridge for OpenClaw, since mcporter has no per-server tool filter and mcp-proxy is transparent. Filtering must be **unconditional on the SSE endpoint** (the bridge cannot authenticate "VM vs host"); any host-local process reaching `127.0.0.1:9082` gets the filtered set. | **Generic mcp-proxy with no filter (proposals' default)**: rejected — silently hands `run_action` to OpenClaw. **Forced-command as the gate**: rejected — pins the binary, not the tool. **Hermes `tools.exclude` alone**: insufficient — client-side advisory only; bridge is authoritative. |
| D8 | **SSE vs streamable-HTTP at the consumer** | **SSE** for VMs; SSH-stdio (command-based) for host Claude. | Matches the only proven-working consumer shape; mcp-proxy mounts both, so no lock-in. | — (covered by D1). |
| D9 | **Lifecycle / recovery** | Single shared ssh child (mcp-proxy default-server) + **`ssh ConnectTimeout=10`, `ServerAliveInterval=30`, `ServerAliveCountMax=3`** + a **health-probe-triggered `systemctl restart`** as the load-bearing recovery (NOT `Restart=on-failure` alone). | **VERIFIED:** mcp-proxy spawns one child at startup and a dead backend leaves a green zombie returning tool errors forever (`proxy_server.py:100`), so `Restart=on-failure` does not cover the dominant outage (hera reboot while bridge is up). It *over*-fires at boot if hera is down (crash-on-init → crash-loop). | **"Per-session ssh, reap on disconnect" (production-robust/security-first claim)**: physically impossible with mcp-proxy. **`Restart=on-failure` as sole recovery**: rejected per the zombie finding. |

## 6. The TCC / Automation-as-a-service risk — validation plan & fallback

This is the make-or-break unknown and is **Phase 1**, run **before** any bridge/key commit.

### 6.1 Why the existing proof is insufficient

The proven `count drafts → 120` ran as **interactive** johnw. The bridge's ssh is **boot-spawned, non-GUI, long-lived** (one child for the proxy's lifetime). TCC attribution differs by responsible-process chain and session type, so the interactive proof does not establish the service-context grant.

### 6.2 Validation gate (must pass before Phase 2)

1. Generate the dedicated keypair; add the pubkey to hera's `authorized_keys` with the forced-command (Phase 2a is pulled forward only for this test, or test with a temporary unrestricted key first).
2. From vulcan **root, BatchMode, the same non-interactive context the unit uses**:
   ```sh
   ssh -i <key> -o BatchMode=yes -o IdentitiesOnly=yes johnw@hera.lan \
       /etc/profiles/per-user/johnw/bin/drafts-mcp-server   # then drive drafts_search via MCP
   ```
   Also directly: `osascript -e 'tell application "Drafts" to count drafts'` (success = a number; failure = `-1743`).
3. **Long-lived test:** start the actual hardened `drafts-mcp.service`, exercise `drafts_search` over the SSE endpoint **repeatedly over >1 h, including across a johnw screen-lock** (not logout). hera never sleeps; lock preserves the Aqua session, logout does not.
4. On hera, during a call, trace attribution:
   ```sh
   log stream --debug --predicate 'subsystem == "com.apple.TCC" AND eventMessage BEGINSWITH "AttributionChain"'
   ```

### 6.3 Outcomes

> **VALIDATED 2026-06-09 (Phase-1 partial — PASS).** Three representative tests passed with **zero** `-1743`/`isError`:
> (1) vulcan→hera **fresh, non-multiplexed** (`ControlMaster=no ControlPath=none`) ssh-as-johnw running `osascript "count drafts"` → live count `125`;
> (2) loopback fresh sshd → **`drafts-mcp-server` → node → osascript** → clean MCP `tools/call drafts_list_workspaces` result envelope;
> (3) **gold-standard** — vulcan-origin fresh ssh → `drafts-mcp-server` → `drafts_get_drafts` → valid `"id":2` response, no TCC-fail signatures.
> Conclusion: the Automation grant is **session-bound, not connection-bound** (it survives brand-new connections and the node-wrapped responsible-process chain), and is **origin-agnostic** (TCC only sees the hera-side johnw-via-sshd process, so a systemd `DynamicUser` + dedicated key initiating from vulcan is covered). **The SSH-stdio architecture is GO; the launchd-Aqua fallback is NOT required.**
> **Still unverified (operational, non-blocking, for the spec's monitoring section):** >1 h longevity; behaviour across johnw **logout** (logout tears down the Aqua session → grant lost — detected by `drafts_mcp_tcc_automation_ok`); a dedicated forced-command key end-to-end (Phase 2). hera never sleeps; screen-lock preserves the session.

- **PASS** (count returns, no `-1743`, grant survives >1 h + screen-lock): proceed with the SSH-stdio architecture as designed.
- **FAIL** (`-1743`): adopt the **fallback** — a hera **launchd user-agent** with `LimitLoadToSessionType = Aqua` running `drafts-mcp-server` inside johnw's GUI session; the ssh session merely **relays** into it (a localhost socket the agent serves). Model on `/Users/johnw/src/nix/config/launchd.nix`. The vulcan-side bridge is unchanged; only the hera-side execution target changes.

### 6.4 Ongoing observability

Split **transport health** (`drafts_mcp_ssh_hera_ok`) from **grant health** (`drafts_mcp_tcc_automation_ok`, a **read-only** `drafts_search` probe — never `run_action`). `ssh_ok=1 ∧ tcc_ok=0` is the precise fingerprint of a lost Automation grant (e.g. johnw logout) and pages distinctly.

## 7. File-by-file change map

### Repo A — `/Users/johnw/src/nixos` (vulcan)

| File | Change |
|---|---|
| `modules/services/drafts-mcp.nix` | **CREATE.** Hardened systemd unit. Hardening block cloned from `hermes-mcp.nix:146-187`. `mkEnableOption` + `host`(127.0.0.1)/`port`(9082) options. **`DynamicUser = true`** + `LoadCredential` (stateless service; prefer the `stock-trader.nix:206` template over hermes-mcp's static user — there is no DB to own). Declares `sops.secrets."drafts/hera-ssh-private-key"` (`mode="0400"; owner="root"; group="root"; restartUnits=["drafts-mcp.service"];`). `RestrictAddressFamilies=[AF_INET AF_INET6 AF_UNIX]` (ssh needs AF_INET over LAN). `ProtectHome=true` with `Environment=HOME=%t/drafts-mcp` (writable private HOME under RuntimeDirectory so ssh has no `~/.ssh` write error). `StartLimitIntervalSec`/`StartLimitBurst` + `RestartSec≈30s` (connect-once upstream — avoid boot crash-loop). `after`/`wants` `network-online.target` and `sops-install-secrets.service`. NO StateDirectory/SQLite/EnvironmentFile/heartbeat. |
| ExecStart (in the above) | `mcp-proxy --host 127.0.0.1 --port 9082 -- <ssh-wrapper>` (**no `--transport`** — it is a client-only no-op). The `<ssh-wrapper>` is a `pkgs.writeShellScript`: `exec ssh -T -i "$CREDENTIALS_DIRECTORY/hera-ssh-key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pinnedKnownHosts} -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 johnw@hera.lan` (NO remote-command arg; rely on the forced-command). `${pinnedKnownHosts}` = a `pkgs.writeText` store file holding hera's host key, captured during Phase 1. |
| `pkgs/drafts-tool-filter/` *(conditional, D7)* | **CREATE (if write-tool denial via shim).** `writers.writePython3Bin` stdio JSON-RPC filter: strips the 9 write tools from `tools/list` and returns a policy error on their `tools/call`, transparently piping everything else to the child ssh. Inserted as `mcp-proxy … -- drafts-tool-filter ssh …`. No overlay/flake entry. |
| `hosts/vulcan/default.nix` | Import `modules/services/drafts-mcp.nix` (~line 152) and `services.drafts-mcp.enable = true;` (~line 192), beside hermes-mcp. |
| `modules/services/openclaw-microvm.nix` | Append `9082 # drafts-mcp — OpenClaw→Drafts(hera) bridge (SSE)` to `dnatPorts` (`:126-138`). Keep the `", "` join. Optional: `assert builtins.elem 9082 dnatPorts` (mirror `:336-359`). |
| `modules/services/hermes-microvm.nix` | Append `9082` to `dnatPorts` (`:63-71`). **Do NOT alter the NO-SPACE `concatStringsSep ","` join (`:78`)** — it feeds `iptables -m multiport`. |
| `modules/services/openclaw-vm.nix` | **Replace** `apply_mcporter_jq 'del(.mcpServers["drafts"])'` (`:862`) with an add (jq below), keyed **`drafts-hera`**. |
| `modules/services/hermes-vm.nix` | Add `drafts-hera` to `services.hermes-agent.mcpServers` (`:669-750`) — `url` + `tools.exclude` (snippet below). **No `description` field.** |
| `modules/monitoring/services/drafts-mcp-check.nix` | **CREATE.** Oneshot + timer (`OnBootSec≈3m`, `OnUnitActiveSec=300s`, `RuntimeMaxSec=120s`), modeled on `hermes-health-check.nix`. Emits `drafts_mcp_bridge_up`, `drafts_mcp_sse_open_ok`, `drafts_mcp_ssh_hera_ok`, `drafts_mcp_tcc_automation_ok` (read-only `drafts_search`), `drafts_mcp_e2e_ok`, `drafts_mcp_check_last_run_timestamp_seconds`. **Probe-driven recovery:** on `e2e_ok=0`/`tcc_ok=0` it triggers (or its alert triggers) `systemctl restart drafts-mcp.service` (the zombie fix). |
| `modules/monitoring/services/default.nix` | Import `drafts-mcp-check.nix`. |
| `modules/monitoring/alerts/drafts.yaml` | **CREATE** (auto-discovered). `DraftsMcpBridgeDown` (sse_open_ok=0 5m), `DraftsMcpAskFailing` (e2e_ok=0 5m, **`self_heal_eligible="true"`** → restart), `DraftsMcpTccAutomationLost` (ssh_ok=1 ∧ tcc_ok=0 5m, `category=integration`), `DraftsMcpCheckStale` (last_run>1200s/absent 10m). |
| `scripts/drafts-self-heal/actions/restart_drafts_mcp` *(or reuse hermes self-heal harness)* | **CREATE.** A pure `systemctl restart drafts-mcp.service` — orthogonal to `run_action`, so the "no autonomous remediator" objection does not apply. |
| `docs/ports.txt` | **Single** line under `# microVM Bridge Services`: `9082 127.0.0.1 drafts-mcp (Drafts(hera) MCP SSE bridge; OpenClaw via br-openclaw 10.99.0.1:9082→127.0.0.1:9082, Hermes via hermes-br0 10.99.1.1:9082)`. No `10.99.x.1` mirror lines. |
| `docs/openclaw-hermes-integration.md` | Extend topology, "where to make changes", verification recipes, failure modes for the drafts bridge + TCC gate. |
| `tests/openclaw/expected-keys.txt` | **NO CHANGE** (verified: zero `mcpServers` keys; mcporter is preStart-injected, outside the guarded `openclaw-config-template`). |

**Repo A — separate `secrets` input** (`git+file:///etc/nixos/secrets`):

| File | Change |
|---|---|
| `secrets.yaml` (third git tree) | Add `drafts/hera-ssh-private-key` via `sops /etc/nixos/secrets.yaml`. Auto-covered by the `.*\.yaml$` rule (no `.sops.yaml` edit). Commit + push this repo independently. |

### Repo B — `/Users/johnw/src/nix` (hera/darwin)

| File | Change |
|---|---|
| `config/darwin.nix` | Add the bridge **public** key to `users.users.johnw.openssh.authorizedKeys.keys` (`:35-37`) as an inline literal with a forced-command (snippet below). **Not** via `key-files.nix` (grants full shell). Then darwin switch on hera. |
| `config/launchd.nix` *(only if Phase 1 fails)* | Add a `LimitLoadToSessionType = Aqua` user-agent running `drafts-mcp-server` inside johnw's GUI session (TCC fallback). |

### Repo C — `/Users/johnw/src/promptdeploy`

| File | Change |
|---|---|
| `mcp/drafts-hera.yaml` | **CREATE.** `name: drafts-hera`; `only: [claude-vulcan]`; command-based ssh-stdio (snippet below). Distinct name (D6) so `validate` passes. |
| `mcp/drafts.yaml` | Edit the comment block: remove `claude-vulcan` from the "NEVER add" list; note vulcan now reaches Drafts via `drafts-hera.yaml` (SSH-stdio to hera over LAN; the prohibition on a *local* osascript binary still holds). `name: drafts`, `only: [claude-personal]` unchanged. |

### Copy-usable snippets (confidence-gated)

**OpenClaw mcporter (replace `openclaw-vm.nix:862`):**
```sh
# Drafts on hera via the host drafts-mcp SSE bridge (re-added 2026-06; write tools gated by the bridge for autonomous agents)
apply_mcporter_jq '
  .mcpServers["drafts-hera"] = {
    "url": "http://127.0.0.1:9082/sse",
    "description": "Drafts.app (macOS, on hera) via the host drafts-mcp SSE bridge. Read tools + create/update/search/tag/flag/archive/inbox/trash. drafts_run_action is NOT available here."
  }
'
```

**Hermes (`hermes-vm.nix` `mcpServers`) — NO `description`, default-deny writes via allowlist:**
```nix
# drafts-hera: Drafts.app on hera via the host SSE bridge (read + safe writes; run_action and destructive tools excluded for the autonomous agent)
drafts-hera = {
  url = "http://127.0.0.1:9082/sse";
  connect_timeout = 10;
  timeout = 60;
  # Prefer an allowlist (include) over exclude so a future upstream tool is denied by default:
  tools.include = [
    "drafts_search" "drafts_get_draft" "drafts_get_drafts" "drafts_list_tags"
    "drafts_list_workspaces" "drafts_get_current" "drafts_list_actions"
    "drafts_create_draft" "drafts_update_draft" "drafts_add_tags"
  ];
};
```

**hera `authorized_keys` (`config/darwin.nix`):**
```nix
# drafts-mcp bridge (vulcan) — pinned to exec drafts-mcp-server only; ignores SSH_ORIGINAL_COMMAND
''command="/etc/profiles/per-user/johnw/bin/drafts-mcp-server",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... drafts-bridge@vulcan''
```

**promptdeploy `mcp/drafts-hera.yaml`:**
```yaml
name: drafts-hera
description: Drafts.app on hera via SSH-stdio (host Claude Code, operator context — full toolset).
only: [claude-vulcan]
command: ssh
args:
  - "-o"
  - "BatchMode=yes"
  - "-o"
  - "IdentitiesOnly=yes"
  - "-o"
  - "StrictHostKeyChecking=yes"
  - "johnw@hera.lan"
  - "/etc/profiles/per-user/johnw/bin/drafts-mcp-server"
```

## 8. Phased implementation plan (with verification gates)

| Phase | Work | Gate (must pass to proceed) |
|---|---|---|
| **0 — Host CC quick-win** | `promptdeploy/mcp/drafts-hera.yaml` + edit `drafts.yaml` comment. Deploy to `claude-vulcan`. | `promptdeploy validate` exits 0 (the D6 name fix is what makes this pass). Host Claude Code lists `drafts-hera` tools and a `drafts_search` returns results from hera. |
| **1 — Validate TCC-as-service** | Run §6.2 with a temporary key, then the dedicated key + forced-command. Capture hera's host key for the pinned `known_hosts`. | `drafts_search`/`osascript count` succeed (no `-1743`) in the boot-spawned, long-lived, screen-locked context. **If FAIL → build the launchd Aqua fallback first**, then re-gate. |
| **2 — Bridge service + DNAT + key** | `secrets.yaml` key; darwin authorized_keys (forced-command); `drafts-mcp.nix` (+ filter shim if D7-shim chosen); enable on vulcan; add 9082 to both `dnatPorts`; `ports.txt`. | `nixos-rebuild build --flake '.#vulcan'` clean; `nix flake check` (eval) clean; `nix fmt` clean. On vulcan: `curl -sN http://127.0.0.1:9082/sse` opens an SSE stream; `ss -ltnp` shows 9082 bound to `127.0.0.1` only. End-to-end `drafts_search` via the SSE endpoint succeeds. |
| **3 — Register OpenClaw + Hermes** | Replace OpenClaw `del()` with the `drafts-hera` add; add Hermes `drafts-hera` (allowlist). | From inside each VM, the agent lists `drafts-hera` tools (verify `drafts_run_action` is **absent**). A read tool succeeds via DNAT. `expected-keys.txt` unchanged (confirm `nix flake check`). |
| **4 — Monitoring** | `drafts-mcp-check.nix` + import + `drafts.yaml` alerts + self-heal action. | Probe emits all metrics; `drafts_mcp_tcc_automation_ok=1`. Simulate a hera-down event → `DraftsMcpAskFailing` fires and the self-heal restart recovers (or pages). Add (optional) `drafts-hera` to `openclaw-mcporter-check.nix:EXPECTED_SERVERS`. |

Build/switch/commit are **user-gated** at every phase (per repo conventions; commits require the YubiKey pinentry per memory).

## 9. Test / verification & rollback

**Verification (must pass before "done"):**
1. `nixos-rebuild build --flake '.#vulcan'` evaluates and builds clean.
2. `nix flake check` (eval) — exercises the Hermes `tools` submodule and the new module/package; `expected-keys.txt` unchanged.
3. `promptdeploy validate` exits 0 (name-collision gate).
4. SSE probe: `curl -sN http://127.0.0.1:9082/sse` streams; bind is `127.0.0.1` only (LAN cannot reach it).
5. From-VM probe: agent in each VM lists `drafts-hera`, `run_action` **absent**, a read tool round-trips via DNAT.
6. End-to-end: `drafts_search` returns hera content through every leg; a **secret-safe** assertion the VM endpoint's `tools/list` excludes the 9 write tools.
7. `nix fmt` clean; no secrets in any committed file or in conversation output.

**Rollback:** Pure-additive across all three repos.
- vulcan: `git revert` the module/DNAT/registration commits + `nixos-rebuild switch` + `systemctl restart microvm@openclaw microvm@hermes`. Removing 9082 from `dnatPorts` closes the egress.
- hera: revert the `authorized_keys` line + darwin switch (instantly de-authorizes the key).
- promptdeploy: revert/remove `drafts-hera.yaml` + redeploy.
- Secret: leaving `drafts/hera-ssh-private-key` in `secrets.yaml` is inert once the pubkey is removed; rotate if exposure is suspected.

**Key-rotation runbook** (cross-repo ordering matters): (1) add new pubkey to hera authorized_keys (keep old valid) + darwin switch; (2) update `secrets.yaml` + nixos switch (the `restartUnits` restart cuts onto the new key — tolerable since Drafts ops are short); (3) remove old pubkey. Doing it in the reverse order crash-loops the bridge on auth failure.

## 10. Open questions the FULL SPEC must close

1. **TCC outcome (BLOCKING):** does the boot-spawned, long-lived, screen-locked johnw ssh retain the grant (Phase 1)? Determines SSH-stdio vs launchd-Aqua-agent. If the launchd relay is needed, specify the trigger mechanism (localhost socket vs `launchctl asuser 501`).
2. **D7 enforcement for OpenClaw:** ship the stdio **filter shim** (hard denial) or accept write-tool exposure behind the bridge? Recommendation: ship the shim — it is small and is the only OpenClaw enforcement point. Confirm the shim correctly proxies `notifications`/`initialize` and only filters `tools/*`.
3. **Single shared ssh + concurrency:** Drafts.app is a single osascript serialization point, so concurrent calls from OpenClaw+Hermes+host head-of-line block. Confirm acceptable; specify a host-side per-call deadline (OpenClaw mcporter has no per-server timeout knob).
4. **Cold Drafts.app:** does `drafts-mcp-server` auto-launch Drafts if quit, and does an auto-launched instance inherit the grant? Consider a launchd `KeepAlive` agent keeping Drafts resident. Specify a bounded first-call deadline.
5. **`tools.include` vs `tools.exclude` for Hermes:** allowlist (`include`) is default-deny-safe against future upstream tools — confirm this is the desired posture (this design recommends `include`).
6. **Pinned `known_hosts` lifecycle:** a store-path pin breaks on a hera host-key change (reinstall) → bridge crash-loop until rebuild. Decide pinned-yes vs `accept-new` fallback; document host-key-rotation.
7. **Self-heal scope:** confirm a probe-driven `systemctl restart` (not any Drafts tool call) is the only automated remediation — safe and orthogonal to `run_action`.
8. **Port 9082 liveness:** re-verify free against a live `ss -ltnp` / `nft list ruleset` on vulcan before commit (read-only research env cannot confirm the running host).
9. **Whether to author the matching execution plan** (`docs/superpowers/plans/2026-06-08-drafts-mcp-bridge.md`) now, or stop at this design (mission says stop before the implementation spec — default: design-only).
