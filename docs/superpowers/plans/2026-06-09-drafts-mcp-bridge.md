# Drafts MCP Bridge (hera) — Execution Plan

> **Archival — 2026-06-09.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/drafts-mcp.nix`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a host-side `drafts-mcp.service` on vulcan that bridges the remote *stdio* Drafts.app MCP server on hera (`drafts-mcp-server`, already packaged) to a loopback *SSE* endpoint on `127.0.0.1:9082`, then wire it to three consumers: host Claude Code (`claude-vulcan`, full toolset via SSH-stdio), OpenClaw (read-only via a stdio filter shim), and Hermes (default-deny `tools.include` allowlist) — with probe-driven self-heal and no new LAN exposure.

**Spec:** [`docs/superpowers/specs/2026-06-09-drafts-mcp-bridge-spec.md`](../specs/2026-06-09-drafts-mcp-bridge-spec.md) (implementation-ready successor to the approved design `docs/superpowers/specs/2026-06-08-drafts-mcp-bridge-design.md`). Read the spec first — every file body, diff, and anchor (`path:line`) lives there; this plan is the ordered execution wrapper.

---

## Conventions for the executor

- **Phases are strictly ordered.** Each phase ends with a **VERIFICATION GATE** that MUST fully pass before the next phase begins. A red gate halts the plan — fix or roll back, do not advance.
- **Three independent git trees:** `/Users/johnw/src/nixos` (vulcan), `/Users/johnw/src/nix` (hera/darwin), `/Users/johnw/src/promptdeploy`, plus `/etc/nixos/secrets` (sops tree). Commits to each are separate. Never `git add` across trees.
- **User-gated actions (BLOCK and ask John; never self-run):**
  - **Every `git commit`** — gpgsign key is on a YubiKey; non-interactive commits fail. Have John warm/run pinentry. **Never** `--no-gpg-sign` / `--no-verify`.
  - **`nixos-rebuild switch`** and **`darwin-rebuild switch`** (state-changing).
  - **`sops` secret edits** and **secrets-tree push**.
  - `nixos-rebuild build` / `nix flake check` / `nix fmt` / `promptdeploy validate` are safe to run unprompted (read-only / no activation).
- **Fail-closed by design:** the §5 assertion in `drafts-mcp.nix` makes `nixos-rebuild build` FAIL until the real Phase-1 hera host key replaces the `REPLACE_ME` placeholder AND the sops secret exists. Land the real host key + secret in the SAME commit as `services.drafts-mcp.enable = true`. This is why Phase 1 (capture key) precedes Phase 2 (enable).
- **No secrets in any committed file or in output.** Private key material lives only in `/etc/nixos/secrets/secrets.yaml` (sops) and the per-unit credential dir at runtime.
- **`name: drafts-hera` everywhere on vulcan** (host entry + both VM registries). The Mac-local `mcp/drafts.yaml` keeps `name: drafts`. A second `drafts` fails promptdeploy's global `(item_type,name)` dedup gate.

---

## Phase 0 — Host Claude Code quick-win (promptdeploy, no NixOS change)

Delivers Drafts to the operator immediately over plain SSH-stdio. Independent of the bridge; touches only the `promptdeploy` tree. `claude-vulcan` authenticates as johnw via the normal Yubikey/keyFiles identity (unrestricted shell) and selects the server with an explicit remote-command arg — it does NOT use the dedicated forced-command key.

### Task 0.1: Create `mcp/drafts-hera.yaml`

**Files:** CREATE `/Users/johnw/src/promptdeploy/mcp/drafts-hera.yaml`

- [ ] **Step 1:** Write the file verbatim from spec §10.3 — `name: drafts-hera`, `command: ssh`, the hardened arg superset (`-T`, `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes`, `ConnectTimeout=10`, `ServerAliveInterval=30`, `ServerAliveCountMax=3`, `johnw@hera.lan`, `/etc/profiles/per-user/johnw/bin/drafts-mcp-server`), `scope: user`, `enabled: true`, `only: [claude-vulcan]`. NO key material.

### Task 0.2: Update `mcp/drafts.yaml` comment

**Files:** EDIT `/Users/johnw/src/promptdeploy/mcp/drafts.yaml`

- [ ] **Step 1:** Apply the spec §10.4 comment-only diff at `:17-18` — remove `claude-vulcan` from the NEVER list and add the `drafts-hera.yaml` NOTE. Confirm `name: drafts` and `only: [claude-personal]` (`:23-24`) are UNCHANGED.

### Task 0.3: Validate

- [ ] **Step 1:** Run `promptdeploy validate` and confirm exit 0. This is the gate that proves the `drafts` / `drafts-hera` two-file coexistence is legal (D6 dedup).

### Task 0.4: Deploy + commit

- [ ] **Step 1:** Deploy the `claude-vulcan` profile (`promptdeploy deploy --only claude-vulcan`, or the repo's standard deploy invocation).
- [ ] **Step 2 (USER-GATED COMMIT):** Ask John to warm the YubiKey pinentry, then commit in the promptdeploy tree: `feat(mcp): add drafts-hera SSH-stdio entry for claude-vulcan; note vulcan path in drafts.yaml`.

### ✅ VERIFICATION GATE — Phase 0 (must pass before Phase 1)

- [ ] `promptdeploy validate` exits **0**.
- [ ] In a fresh host Claude Code (`claude-vulcan`) session, the MCP server list includes **`drafts-hera`** and it connects (no auth/host-key prompt — the existing johnw key + `~/.ssh/known_hosts` for hera must already be trusted).
- [ ] `drafts_search` (or `drafts_list_workspaces`) returns real hera Drafts content — proves macOS Automation grant is intact for an interactive ssh-as-johnw session.

**Rollback:** revert/remove `mcp/drafts-hera.yaml` + revert the `drafts.yaml` comment; re-run `promptdeploy validate` and redeploy `claude-vulcan`. No NixOS/hera state touched.

---

## Phase 1 — Capture hera host key + generate the dedicated bridge key (no service yet)

Produces the two artifacts the bridge needs to build (the pinned `known_hosts` body and the dedicated keypair) and re-confirms TCC in the dedicated-key + forced-command context BEFORE any NixOS change. All steps run on vulcan; nothing is committed to NixOS yet (the host-key body lands in Phase 2's enable commit).

### Task 1.1: Capture the hera ed25519 host key

- [ ] **Step 1:** On vulcan: `ssh-keyscan -t ed25519 hera.lan` and save the single resulting `hera.lan ssh-ed25519 AAAA...` line. This becomes the body of `pinnedKnownHosts` in `drafts-mcp.nix` (replaces `REPLACE_ME_WITH_HERA_ED25519_HOST_KEY_FROM_PHASE_1`). Keep it for the Phase-2 module edit; do NOT commit yet.

### Task 1.2: Generate the dedicated bridge keypair

- [ ] **Step 1:** On vulcan: `ssh-keygen -t ed25519 -N "" -C "drafts-bridge@vulcan" -f /tmp/drafts-bridge-ed25519`.
- [ ] **Step 2:** `cat /tmp/drafts-bridge-ed25519.pub` — save the **public** half for the Phase-2 `config/darwin.nix` forced-command literal. Keep the **private** half in `/tmp` only until it is sealed into sops in Phase 2, then `shred -u /tmp/drafts-bridge-ed25519*`. NEVER paste either half into a committed file or into output.

### Task 1.3: Re-confirm TCC in the dedicated-key + forced-command context

This validates the locked decision (design §6.3 PASS) against the *actual* key/command path the bridge will use, before building anything. Done by hand on vulcan/hera; no NixOS module involved.

- [ ] **Step 1 (USER-GATED, hera):** Temporarily authorize the new public key on hera with the forced-command `command="/etc/profiles/per-user/johnw/bin/drafts-mcp-server",restrict ...` (either a manual `authorized_keys` line for the test, or apply the Phase-2 §10.1 edit early via a hera `darwin-rebuild switch` — John's choice). If applied early, this also de-risks Phase 2.
- [ ] **Step 2:** From vulcan, drive one read tool through the dedicated key end-to-end with the hardened ssh flags from spec §5 `sshWrapper` (`-T -i /tmp/drafts-bridge-ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<file containing the Task 1.1 line> -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 johnw@hera.lan`) piping an MCP `initialize` + `tools/call drafts_search` (or `drafts_list_workspaces`) and reading the result envelope.

### ✅ VERIFICATION GATE — Phase 1 (must pass before Phase 2)

- [ ] `ssh-keyscan -t ed25519 hera.lan` produced exactly one `ed25519` line, saved for Phase 2.
- [ ] The dedicated keypair exists; the **public** half is saved for `config/darwin.nix`; the **private** half is still uncommitted (sops not yet edited).
- [ ] A `drafts_search` / `drafts_list_workspaces` `tools/call` over the **dedicated forced-command key** returns valid hera Drafts content with **NO `-1743`**, **no `isError:true`**, and a real `result` (e.g. `"id":2`) — confirms the Automation grant is origin-agnostic + session-bound for the systemd-bound key path.
- [ ] The forced-command ignored `SSH_ORIGINAL_COMMAND` (the remote arg was omitted and `drafts-mcp-server` still ran).

**Rollback:** if the test key was authorized on hera by hand, remove it (`darwin-rebuild switch` reverting the §10.1 line, or delete the manual `authorized_keys` line). `shred -u /tmp/drafts-bridge-ed25519*`. Nothing else changed.

---

## Phase 2 — Bridge service + secret + DNAT (the load-bearing NixOS phase)

Seals the private key, authorizes the public key on hera, builds the `drafts-mcp.service` + filter shim, opens the single DNAT port on both bridges, and enables the bridge on vulcan. The §5 assertion guarantees this phase cannot build green until the real host key (Phase 1) + secret are in place — so land them together.

### Task 2.1: Seal the private key into sops (secrets tree)

**Files:** EDIT `/etc/nixos/secrets/secrets.yaml`

- [ ] **Step 1 (USER-GATED):** `sops /etc/nixos/secrets/secrets.yaml` and add `drafts: { hera-ssh-private-key: |  <private key> }` from spec §10.2. The `.*\.yaml$` rule auto-covers it (no `.sops.yaml` edit). Confirm `/etc/nixos/secrets/secrets.yaml` is the **subdir** path (flake.nix:25 / system.nix:74 / vulcan default.nix:287) — NOT the bare `/etc/nixos/secrets.yaml`.
- [ ] **Step 2 (USER-GATED COMMIT + PUSH):** `git -C /etc/nixos/secrets add secrets.yaml && git -C /etc/nixos/secrets commit -m "Add drafts/hera-ssh-private-key for drafts-mcp bridge" && git -C /etc/nixos/secrets push`.
- [ ] **Step 3:** `shred -u /tmp/drafts-bridge-ed25519*` (the private half now lives only in sops).

### Task 2.2: Authorize the forced-command pubkey on hera (darwin)

**Files:** EDIT `/Users/johnw/src/nix/config/darwin.nix`

- [ ] **Step 1:** Apply the spec §10.1 diff at `:34-38` — insert the `command="/etc/profiles/per-user/johnw/bin/drafts-mcp-server",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 <REAL PUBKEY> drafts-bridge@vulcan` literal (escaped-double-quote form, after the two card keys). Paste the **real** Phase-1.2 pubkey (replaces `AAAA...PLACEHOLDER`).
- [ ] **Step 2 (USER-GATED SWITCH):** `darwin-rebuild switch --flake '/Users/johnw/src/nix#hera'` on hera (de-risked already if done in Phase 1.3).
- [ ] **Step 3 (USER-GATED COMMIT):** Commit in the nix tree: `feat(darwin): authorize drafts-mcp bridge forced-command key on hera`.

### Task 2.3: Add the bridge module + filter shim (vulcan)

**Files:** CREATE `/Users/johnw/src/nixos/modules/services/drafts-mcp.nix`; CREATE `/Users/johnw/src/nixos/pkgs/drafts-tool-filter/default.nix`

- [ ] **Step 1:** Write `pkgs/drafts-tool-filter/default.nix` verbatim from spec §6 (the `writePython3Bin` stdio filter; 9-tool DENY set; fail-closed on unparseable client→child lines; `tools/call` deny + `tools/list` strip; batch/notification/ping pass-through).
- [ ] **Step 2:** Write `modules/services/drafts-mcp.nix` verbatim from spec §5. Replace the `pinnedKnownHosts` `REPLACE_ME...` body with the **real Phase-1.1 host-key line**. Confirm `LoadCredential` id `hera-ssh-key` matches the `sshWrapper`'s `$CREDENTIALS_DIRECTORY/hera-ssh-key`; confirm the single `ExecStart` is the `lib.escapeShellArgs` filter-shim form (mcp-proxy → `drafts-tool-filter` → `sshWrapper`) with NO competing no-shim form.

### Task 2.4: Import + enable the bridge (vulcan host wiring)

**Files:** EDIT `/Users/johnw/src/nixos/hosts/vulcan/default.nix`

- [ ] **Step 1:** Apply spec §5 EDIT 1 — insert `../../modules/services/drafts-mcp.nix` AND `../../modules/services/drafts-mcp-self-heal.nix` after the `hermes-mcp.nix` import (`:152`). (The self-heal module body lands in Phase 4; importing it here is harmless because its `enable` defaults false — but to keep Phase 2 building, either create the §9.5 file now as part of this step OR defer this single import line to Phase 4. **Recommended: create `drafts-mcp-self-heal.nix` now** so the import resolves; it stays inert until its enable flag flips in Phase 4.)
- [ ] **Step 2:** Apply spec §5 EDIT 2 — add `services.drafts-mcp.enable = true;` after `services.hermes-mcp.enable` (`:192`). Defer `services.draftsMcpCheck.enable` and `services.draftsMcpSelfHeal.enable` to Phase 4 (their modules are imported/created but not enabled yet).

### Task 2.5: Open DNAT port 9082 on both bridges

**Files:** EDIT `/Users/johnw/src/nixos/modules/services/openclaw-microvm.nix`; EDIT `/Users/johnw/src/nixos/modules/services/hermes-microvm.nix`

- [ ] **Step 1:** OpenClaw (spec §7 EDIT 1): add `9082 # drafts-mcp ...` after `9081` (`:137`). Do NOT touch the `", "` WITH-space join at `:141`. Optionally add the `builtins.elem 9082 dnatPorts` assertion after the `2525` assertion (`:359`).
- [ ] **Step 2:** Hermes (spec §7 EDIT 2): add bare `9082` after `8123` (`:70`). Do NOT alter the NO-SPACE `concatStringsSep ","` join at `:78` (iptables `--dports` rejects spaces). No assertion block here.

### Task 2.6: Record port 9082 in ports.txt

**Files:** EDIT `/Users/johnw/src/nixos/docs/ports.txt`

- [ ] **Step 1:** Apply spec §7 EDIT 3 — insert the single `9082 127.0.0.1 drafts-mcp (...)` loopback line after the `openclaw-hermes-smoke` line (`:126`). One loopback line only (no `10.99.x.1` mirrors — matches the 9081 precedent).

### Task 2.7: Re-verify ports free against LIVE state

- [ ] **Step 1:** On vulcan, BEFORE switch: `ss -ltnp | grep -E ':9082|:9085'` returns nothing; `nft list ruleset | grep 9082` shows no pre-existing rule. (9085 is the Phase-4 self-heal port; verify both now while you're here.) If 9082 is taken, STOP and re-allocate before proceeding.

### Task 2.8: Build, format, commit, switch

- [ ] **Step 1:** `nix fmt` on all new/edited Nix files (clean).
- [ ] **Step 2:** `nix flake check` (exercises the new module + package; must pass).
- [ ] **Step 3:** `nixos-rebuild build --flake '/Users/johnw/src/nixos#vulcan'` — must succeed (the §5 assertion now passes because the real host key + sops secret exist).
- [ ] **Step 4 (USER-GATED COMMIT):** Commit in the nixos tree (one logically-atomic commit, or split bridge / DNAT / ports): `feat(drafts-mcp): host SSE bridge to Drafts on hera + filter shim + 9082 DNAT`.
- [ ] **Step 5 (USER-GATED SWITCH):** `nixos-rebuild switch --flake '/Users/johnw/src/nixos#vulcan'`, then `systemctl restart microvm@openclaw microvm@hermes` (so the new guest OUTPUT DNAT rules land).

### ✅ VERIFICATION GATE — Phase 2 (must pass before Phase 3)

- [ ] `nix flake check` + `nixos-rebuild build --flake '.#vulcan'` + `nix fmt` all clean.
- [ ] `promptdeploy validate` still exits 0 (unchanged from Phase 0).
- [ ] **SSE bind is loopback-only:** `ss -ltnp | grep 9082` shows `127.0.0.1:9082` ONLY (no LAN/`0.0.0.0` bind); `curl -sN http://127.0.0.1:9082/sse` opens a stream and emits an endpoint event.
- [ ] **e2e over SSE:** an MCP `initialize` + `tools/call drafts_search` (or `drafts_list_workspaces`) against `http://127.0.0.1:9082/sse` returns real hera Drafts content with no `isError` (proves mcp-proxy → filter shim → ssh forced-command → drafts-mcp-server → Drafts).
- [ ] `systemctl status drafts-mcp.service` is active; `journalctl -u drafts-mcp` shows the ssh child connected (no `StrictHostKeyChecking` abort, no "no such identity").
- [ ] **DNAT landed:** `iptables -t nat -S PREROUTING | grep 9082` shows the rule on BOTH `br-openclaw` and `hermes-br0`.

**Rollback:** `git revert` the bridge/DNAT/ports/import/enable commits + `nixos-rebuild switch` + `systemctl restart microvm@openclaw microvm@hermes` (removing 9082 from each `dnatPorts` closes the egress; removing `services.drafts-mcp.enable` stops the unit). On hera, revert the §10.1 `authorized_keys` line + `darwin-rebuild switch` (instantly de-authorizes the key). The sops secret is inert once the pubkey is gone; rotate if exposure is suspected.

---

## Phase 3 — Register the autonomous VMs (OpenClaw read-only + Hermes allowlist)

Wires `drafts-hera` into both guest MCP registries. Register ONLY after Phase 2's bridge + DNAT exist, else the VMs target a dead `127.0.0.1:9082`. OpenClaw is gated by the bridge's filter shim (hard); Hermes by a `tools.include` default-deny allowlist (client-side).

### Task 3.1: Register OpenClaw (mcporter `drafts-hera`, READ-ONLY description)

**Files:** EDIT `/Users/johnw/src/nixos/modules/services/openclaw-vm.nix`

- [ ] **Step 1:** Apply spec §8 EDIT 1 at `:861-862` — replace the `del(.mcpServers["drafts"])` line with the `apply_mcporter_jq` add for `mcpServers["drafts-hera"] = { url, description }`. The description is **READ-ONLY** (lists only the 11 read tools; states all write tools incl. `drafts_run_action` are filtered out) — do NOT advertise writes (the shim strips them; advertising would cause wasted denied calls). 14-space indent.
- [ ] **Step 2:** Confirm `tests/openclaw/expected-keys.txt` needs NO change: `grep -c mcpServers tests/openclaw/expected-keys.txt` → **0** (it snapshots the guarded template, not the runtime `mcporter.json` injected in preStart).

### Task 3.2: Register Hermes (`tools.include` default-deny allowlist)

**Files:** EDIT `/Users/johnw/src/nixos/modules/services/hermes-vm.nix`

- [ ] **Step 1:** Apply spec §8 EDIT 2 — insert the `drafts-hera = { url, connect_timeout, timeout, tools.include = [...] }` entry after the `org-db` block (`:749`), before the `mcpServers` close (`:750`). 6-space indent. **NO `description` field** (submodule rejects it — `:660-668` NOTE). The allowlist is 7 reads + 3 benign writes (`create_draft`, `update_draft`, `add_tags`) — and deliberately EXCLUDES `drafts_run_action` and the destructive set (`flag`, `archive`, `inbox`, `trash`, `open_workspace`).

### Task 3.3: Build, format, commit, switch

- [ ] **Step 1:** `nix fmt` clean; `nixos-rebuild build --flake '/Users/johnw/src/nixos#vulcan'` succeeds (exercises the Hermes `tools` submodule).
- [ ] **Step 2 (USER-GATED COMMIT):** `feat(openclaw,hermes): register drafts-hera (read-only shim / default-deny allowlist)`.
- [ ] **Step 3 (USER-GATED SWITCH):** `nixos-rebuild switch --flake '.#vulcan'` then `systemctl restart microvm@openclaw microvm@hermes` (re-injects `mcporter.json` / restarts the Hermes agent with the new server).

### ✅ VERIFICATION GATE — Phase 3 (must pass before Phase 4)

- [ ] From inside the **OpenClaw** VM: the agent lists `drafts-hera`; its `tools/list` **EXCLUDES all 9 write tools**; a direct `tools/call drafts_run_action` returns `isError:true` (shim deny); a read tool (`drafts_search`) round-trips via the two-stage DNAT.
- [ ] From inside the **Hermes** VM: the agent lists `drafts-hera`; `tools/call drafts_run_action` is **refused CLIENT-SIDE** (not merely absent from `tools/list`) — proves `tools.include` default-deny enforcement; a read tool round-trips via `hermes-br0` DNAT. (If client-side refusal cannot be proven, STOP and route the Hermes leg through its own filter-shim instance per spec §8.)
- [ ] `grep -c mcpServers tests/openclaw/expected-keys.txt` → 0 (snapshot unchanged); `nixos-rebuild build` still green.
- [ ] No `drafts_run_action` reachable from EITHER VM by any path.

**Rollback:** `git revert` the two registration commits + `nixos-rebuild switch` + restart both microVMs (OpenClaw's preStart re-runs the now-`del` form; Hermes drops the server). Bridge + host CC remain functional.

---

## Phase 4 — Monitoring + probe-driven self-heal

Adds the read-only e2e probe, alerts, and the single-action self-heal webhook receiver. Recovery is `systemctl restart drafts-mcp.service` ONLY — never a Drafts tool call (orthogonal to `run_action`). Self-heal port is **9085** (the 9097→9085 MailArchiver-collision fix).

### Task 4.1: Add the health-check module

**Files:** CREATE `/Users/johnw/src/nixos/modules/monitoring/services/drafts-mcp-check.nix`; EDIT `/Users/johnw/src/nixos/modules/monitoring/services/default.nix`

- [ ] **Step 1:** Write `drafts-mcp-check.nix` verbatim from spec §9.1 (6 metrics; read-only `drafts_list_workspaces` probe; `_is_tcc_failure` envelope inference; `DynamicUser` writing the 1777 textfile dir; no credentials).
- [ ] **Step 2:** Apply spec §9.2 import edit — add `./drafts-mcp-check.nix` after `hermes-health-check.nix` (`:50`) in `default.nix`.

### Task 4.2: Add the alerts

**Files:** CREATE `/Users/johnw/src/nixos/modules/monitoring/alerts/drafts.yaml`

- [ ] **Step 1:** Write `drafts.yaml` verbatim from spec §9.3 — four alerts (`DraftsMcpBridgeDown`, `DraftsMcpAskFailing`, `DraftsMcpTccAutomationLost`, `DraftsMcpCheckStale`). All carry `service: drafts-mcp` (the load-bearing routing label, M2); only `BridgeDown`/`AskFailing` carry `self_heal_eligible: "true"`. `DraftsMcpTccAutomationLost` is intentionally NOT self-healed (lost hera GUI session — pages a human).

### Task 4.3: Add the self-heal receiver + action

**Files:** CREATE `/Users/johnw/src/nixos/scripts/drafts-mcp-self-heal/actions/restart_drafts_mcp` (chmod 0755); CREATE `/Users/johnw/src/nixos/modules/services/drafts-mcp-self-heal.nix` (created already in Phase 2.4 Step 1 if you took the recommended path — confirm body matches spec §9.5)

- [ ] **Step 1:** Write the action script `scripts/drafts-mcp-self-heal/actions/restart_drafts_mcp` verbatim from spec §9.4 and `chmod 0755` (`git update-index --chmod=+x` so it ships executable). It is pure `systemctl restart drafts-mcp.service` — never a Drafts tool call.
- [ ] **Step 2:** Ensure `modules/services/drafts-mcp-self-heal.nix` exists with the spec §9.5 body (port **9085**, `HEALABLE = {DraftsMcpBridgeDown, DraftsMcpAskFailing}`, 300s debounce, sudoers allowlist for the one action path). If it was stubbed/created in Phase 2.4, confirm it matches §9.5 exactly.

### Task 4.4: Wire Alertmanager route + receiver

**Files:** EDIT `/Users/johnw/src/nixos/modules/services/alertmanager.nix`

- [ ] **Step 1:** Insert the `match { service = "drafts-mcp"; } → receiver = "drafts-mcp-self-heal"` route after the hermes self-heal route (`:91`), with the M2 carve-out + watchdog-loop comment (spec §9.6). `continue = true`.
- [ ] **Step 2:** Insert the `drafts-mcp-self-heal` receiver (`url = http://127.0.0.1:9085/alert`, `send_resolved = true`) after the `hermes-self-heal` receiver (`:245`). Confirm `send_resolved = true` matches the two existing self-heal receivers (`:233`, `:242`) and the port matches `services.draftsMcpSelfHeal.port` (9085).

### Task 4.5: Enable the monitoring + self-heal flags

**Files:** EDIT `/Users/johnw/src/nixos/hosts/vulcan/default.nix`

- [ ] **Step 1:** Add `services.draftsMcpCheck.enable = true;` and `services.draftsMcpSelfHeal.enable = true;` (spec §5 EDIT 2 — the deferred half). Confirm `../../modules/services/drafts-mcp-self-heal.nix` is imported (Phase 2.4) and `./drafts-mcp-check.nix` is in `monitoring/services/default.nix` (Task 4.1).

### Task 4.6: Record the self-heal port in ports.txt

**Files:** EDIT `/Users/johnw/src/nixos/docs/ports.txt`

- [ ] **Step 1:** Add `9085 127.0.0.1 Drafts MCP Self-Heal webhook receiver` in the 909x self-heal band (near `:141`/`:145`), per spec §9.7.

### Task 4.7: (OPTIONAL, deferred) OpenClaw mcporter-check EXPECTED_SERVERS

**Files:** EDIT `/Users/johnw/src/nixos/modules/monitoring/services/openclaw-mcporter-check.nix`

- [ ] **Step 1:** Only AFTER Phase 3's OpenClaw registration has switched and verified: add `"drafts-hera"` to `EXPECTED_SERVERS` (`:40-48`, spec §9.8). Skipping this is fine; adding it before Phase 3 lands would flag `drafts-hera` missing (=0).

### Task 4.8: Build, alerts-lint, format, commit, switch

- [ ] **Step 1:** `promtool check rules modules/monitoring/alerts/drafts.yaml` (validates the `or absent(...)` expr).
- [ ] **Step 2:** `nix fmt` clean; `nix flake check` (alert auto-discovery + the alertmanager route/receiver); `nixos-rebuild build --flake '.#vulcan'` succeeds.
- [ ] **Step 3 (USER-GATED COMMIT):** `feat(monitoring): drafts-mcp e2e probe + alerts + probe-driven self-heal`.
- [ ] **Step 4 (USER-GATED SWITCH):** `nixos-rebuild switch --flake '.#vulcan'`.

### ✅ VERIFICATION GATE — Phase 4 (final)

- [ ] On vulcan: `ss -ltnp | grep 9085` shows `127.0.0.1:9085` ONLY (loopback); `systemctl status drafts-mcp-check.timer` active; `systemctl status drafts-mcp-self-heal.service` active.
- [ ] After one probe cycle: `cat /var/lib/prometheus-node-exporter-textfiles/drafts_mcp.prom` shows all **6** metrics with `drafts_mcp_e2e_ok 1` and `drafts_mcp_tcc_automation_ok 1`.
- [ ] **Self-heal loop:** stop hera's `drafts-mcp-server` → within ~10m `DraftsMcpAskFailing` fires → Alertmanager delivers to `127.0.0.1:9085/alert` → `drafts-mcp.service` restarts → `drafts_mcp_e2e_ok` returns to 1. `journalctl -u drafts-mcp-self-heal` confirms delivery + the 300s debounce.
- [ ] **TCC-lost signal (optional):** logging johnw OUT of hera's GUI briefly yields `drafts_mcp_ssh_hera_ok 1 ∧ drafts_mcp_tcc_automation_ok 0` → `DraftsMcpTccAutomationLost` fires (category=integration) and is NOT auto-healed; logging back in returns it to 1.
- [ ] **No secrets** in any committed file or in any console output across all phases.

**Rollback:** `git revert` the monitoring commit + `nixos-rebuild switch`. Removing the enable flags stops `drafts-mcp-check` and `drafts-mcp-self-heal`; the alerts/receiver disappear from Alertmanager on the next switch. The bridge (Phase 2) and VM registrations (Phase 3) keep working; only observability/auto-recovery is removed.

---

## Post-implementation

- [ ] Update the spec's §15 residual notes with anything observed during rollout (cold-Drafts latency → decide whether to ship the optional §10.5 launchd `KeepAlive` agent; `MemoryMax=256M` headroom under large `drafts_search`).
- [ ] If a real `-1743` `tools/call` envelope was captured over the bridge during Phase 1/4, confirm `_is_tcc_failure()` matches it; tighten the matcher if the envelope shape differs from `isError` / `-1743` / `not authorized`.
- [ ] (Phase-2 follow-up, optional) Extract `is_denied_call`/`strip_tools_list`/`deny_result` into `scripts/drafts_tool_filter.py`, `builtins.readFile` it (depth `../../scripts`), and add the spec §6.3 pytest + a NixOS-VM integration test.
- [ ] Key-rotation runbook is spec §14 (add-new → cut-over → remove-old; reversed order crash-loops the bridge). Host-key rotation is spec §11/§14.

---

## Sequencing traps (do not violate)

- **Capture key (Phase 1) before enable (Phase 2):** the §5 assertion fails the build until the real hera host key replaces `REPLACE_ME`. Land the host key + sops secret in the SAME commit as `services.drafts-mcp.enable = true`.
- **Bridge + DNAT (Phase 2) before VM registration (Phase 3) before monitoring (Phase 4):** registering VMs or starting the probe against a non-existent `127.0.0.1:9082` produces false-red. Strict order only.
- **hera authorize FIRST on key rotation:** the sops `restartUnits` cuts the service onto a new key on rebuild; the matching pubkey must already be on hera or the bridge auth-fails and crash-loops (spec §14).
- **Never touch the join formatting in the DNAT files:** OpenClaw `:141` is a WITH-space `", "` join; Hermes `:78` is a NO-SPACE `","` join (iptables `--dports`). Adding the integer is the complete edit; reformatting the join breaks the rules.
