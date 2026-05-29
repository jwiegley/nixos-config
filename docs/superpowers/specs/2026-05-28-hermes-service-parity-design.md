# Hermes Agent ↔ OpenClaw Service Parity — Design

**Date:** 2026-05-28
**Status:** Approved (design), pending spec review + user sign-off
**Author:** Claude (Opus 4.8) with John Wiegley
**Topic slug:** `hermes-service-parity`

## 1. Goal

Give the **Hermes Agent microVM** (NousResearch `hermes-agent`, `10.99.1.2`) access to the
**same set of host services** that the **OpenClaw microVM** (`10.99.0.2`) can reach today.
The explicit trigger was "use the SearXNG service for web search like OpenClaw does," but
the agreed scope is **full parity** across all seven services OpenClaw reaches.

Non-goal: refactoring OpenClaw, changing OpenClaw's behavior, or introducing a shared
host-side MCP gateway (considered as Approach B, deferred).

## 2. Background / current state

### OpenClaw (reference implementation)
- Runs in a microVM on bridge `br-openclaw` (`10.99.0.1/30`).
- Reaches host loopback services via a **two-stage DNAT**:
  - guest nftables OUTPUT: `127.0.0.1:PORT → 10.99.0.1:PORT`
  - host iptables PREROUTING (on `br-openclaw`): `10.99.0.1:PORT → 127.0.0.1:PORT`
  - host sysctl `route_localnet=1` on the bridge.
  - `dnatPorts = [ 443 993 2525 4000 5232 5432 6333 6334 6335 8123 9081 ]`.
- Secrets are staged by `openclaw-prepare-secrets.service` into
  `/var/lib/microvms/openclaw/secrets/`, shared into the VM via virtiofs as
  `/run/openclaw-secrets`.
- The agent reaches services through **MCP servers** registered in `mcporter.json`
  (mcporter is OpenClaw's MCP transport tool). Stdio MCP servers are wrapper scripts
  (`pkgs.writeShellScript`) that exec a Python interpreter on an absolute store path.
- MCP scripts live in `/etc/nixos/scripts/`: `searxng-mcp.py`, `vane-mcp.py`,
  `stock-trader-mcp.py`, `email-contacts-mcp.py`. Home Assistant uses an
  `mcp-proxy` stdio→streamableHTTP bridge (`pkgs.mcp-proxy`) with a static Bearer token.
- Web search built-in = Perplexity (needs `PERPLEXITY_API_KEY`); `searxng` and `vane`
  are MCP servers.

### Hermes (current)
- Runs in a microVM on bridge `hermes-br0` (`10.99.1.1/30`), deliberately minimal.
- `dnatPorts = [ 4000 ]` (LiteLLM only). Egress FORWARD restricted to TCP/UDP 443 + 53.
- Only `hermes/env` is staged, copied to `${stateDir}/env` (`/var/lib/hermes/env`) and
  consumed via `services.hermes-agent.environmentFiles`. There is **no dedicated secrets
  share** and no `/etc/hosts` overrides.
- Native capabilities (verified against the flake source, rev `ea5a6c2` ≈ v0.15.0):
  - **Native SearXNG web backend**: setting `SEARXNG_URL` is sufficient to register the
    `web_search` tool; `web.search_backend = "searxng"` forces it. No API key, no extra
    deps (uses core `httpx`). The SearXNG backend is search-only.
  - **Native MCP client**: `services.hermes-agent.mcpServers.<name>` accepts
    `{ command, args, env }` (stdio) or `{ url, headers }` (HTTP/StreamableHTTP). It maps
    to `settings.mcp_servers`. Requires `extraDependencyGroups = [ "mcp" ]`.
  - **Gotcha (not applicable here):** `extraPlugins` need `plugins.enabled` opt-in, but
    `mcpServers` is a separate mechanism (`mcp_servers` config key) and does NOT.
  - **Gotcha (verify in impl):** MCP tools must land in an enabled toolset for the model
    to see them; the `web` toolset is high-probability by default. The implementation
    must confirm the model is actually offered the MCP tools.

### Existing SOPS secrets to be reused (NO new secrets, NO `sops` edits)
| Purpose | Existing SOPS key |
|---|---|
| IMAP/SMTP password | `email-tester-imap-password` |
| Radicale CardDAV password | `vdirsyncer-johnw/radicale-password` |
| Home Assistant long-lived token | `openclaw/home-assistant-token` |
| org PostgreSQL password (read-only role `openclaw`) | `openclaw/org-db-password` |
| Perplexity API key | `openclaw/perplexity-api-key` |

All five already exist and are used by OpenClaw. The Hermes staging service copies their
**content** into the Hermes secrets share; `secrets.yaml` is never edited or decrypted.

## 3. Service → Hermes mechanism mapping

| Service | Hermes mechanism | Script | Secret |
|---|---|---|---|
| SearXNG (raw web search) | **Native backend** (`SEARXNG_URL` + `web.search_backend="searxng"`) | — | none |
| Vane (cited AI research) | `mcpServers.vane` (stdio) | existing `vane-mcp.py` | none |
| Home Assistant | `mcpServers.home-assistant` (stdio via `mcp-proxy` bridge) | existing bridge pattern | `openclaw/home-assistant-token` |
| stock-trader | `mcpServers.stock-trader` (stdio) | existing `stock-trader-mcp.py` | none |
| email + contacts | `mcpServers.email-contacts` (stdio) + khard/vdirsyncer setup | existing `email-contacts-mcp.py` | `email-tester-imap-password`, `vdirsyncer-johnw/radicale-password` |
| Perplexity | `mcpServers.perplexity` (stdio) | **NET-NEW** `perplexity-mcp.py` | `openclaw/perplexity-api-key` |
| org PostgreSQL (sherlock + semantic search) | `mcpServers.org-db` (stdio, read-only) | **NET-NEW** `org-db-mcp.py` | `openclaw/org-db-password` |

**Net-new code = exactly two small MCP scripts**, both following the existing script idiom
(stdio MCP server reading config from env / a secret file path). Everything else reuses
OpenClaw's shipped scripts and secrets.

### Rationale for the two net-new wrappers
- **Perplexity**: Hermes has no native Perplexity web backend (its backend list is
  firecrawl→parallel→tavily→exa→searxng→brave-free→ddgs). To honor "Perplexity parity"
  we add a thin stdio MCP that calls `https://api.perplexity.ai/chat/completions`. It is
  functionally adjacent to Vane; including it is for explicit parity. Reachable over the
  already-allowed egress 443.
- **org-DB**: rather than enabling broad shell-exec in the Hermes VM (OpenClaw exposes
  `sherlock`/`org-db-search` as PATH CLIs the agent runs via exec), we wrap **read-only**
  org access as an MCP (`org_sql(query)` + `org_search(query)` semantic search). This keeps
  the uniform MCP interface and avoids giving the 27B model a general shell. The semantic
  search path reuses `org-jw`'s `db search` against LiteLLM embeddings (`hera/bge-m3`).

## 4. Implementation plan (files & changes)

### 4.1 `modules/services/hermes-microvm.nix` (host side)
- Extend `dnatPorts`:
  `[ 4000 ] → [ 443 993 2525 4000 5232 5432 8123 ]`.
  - 443 nginx (searxng.vulcan.lan, vane.vulcan.lan, trader.vulcan.lan)
  - 993 Dovecot IMAPS, 2525 Postfix SMTP, 5232 Radicale, 5432 PostgreSQL, 8123 HA.
  - **Excluded:** 6333/6334/6335 (Qdrant — OpenClaw-memory-specific; Hermes has its own
    memory) and 9081 (the OpenClaw↔Hermes bridge — Hermes *is* Hermes).
  - The existing `dnatPorts`-parameterized host PREROUTING, INPUT accepts, and
    `hermes-isolate` RETURN rules propagate automatically.
- Add a secrets staging dir constant `secretsStagingDir =
  "/var/lib/microvms/hermes/secrets"` and stage it.
- Expand `hermes-prepare-secrets.service` to copy the five reused secrets' content into
  `${secretsStagingDir}/{imap-password,radicale-password,home-assistant-token,
  org-db-password,perplexity-api-key}` at `0400 hermes:hermes`. Runs as root (PID 1)
  before the VM starts, same as OpenClaw. Add `restartUnits`/`restartTriggers` so secret
  rotation re-stages and restarts `microvm@hermes`.
- Pass `secretsStagingDir` to the guest via `_module.args`.

### 4.2 `modules/services/hermes-vm.nix` (guest side)
- Add virtiofs share `hermes-secrets` → `/run/hermes-secrets` (read-only is fine; mirrors
  OpenClaw's secrets share). Because it is read-only, `hermes-tools-setup` must write all
  generated config files under `~/.config` (the read-write state share), never into
  `/run/hermes-secrets`.
- Add `/etc/hosts` overrides → `bridgeAddr` for: `searxng.vulcan.lan`, `vane.vulcan.lan`,
  `trader.vulcan.lan`, `imap.vulcan.lan`, `smtp.vulcan.lan`, `radicale.vulcan.lan`,
  `hass.vulcan.lan`. (The HA `mcp-proxy` bridge connects to `http://127.0.0.1:8123/api/mcp`
  by IP, reached via the 8123 DNAT — the `hass.vulcan.lan` hosts entry is included for
  consistency but is unused by the HA path. The searxng/vane/trader/imap/smtp/radicale
  entries ARE load-bearing, since those scripts use the `*.vulcan.lan` hostnames.)
- Parameterize the guest OUTPUT-DNAT port set: replace hardcoded `tcp dport { 4000 }`
  with `dnatPortList` threaded from `_module.args` (mirrors openclaw-vm.nix).
- `microvm.mem = 2048` (was 1024 — concurrent stdio MCP servers add memory pressure;
  Hermes previously OOM-killed at 512).
- `services.hermes-agent`:
  - `extraDependencyGroups = [ "messaging" "mcp" ]`.
  - `environment.SEARXNG_URL = "https://searxng.vulcan.lan"` (reached via 443 DNAT; the VM
    trusts the Vulcan root CA already). NOTE: SearXNG provider GETs `/search?format=json`,
    which the host SearXNG already enables (`formats = [ "html" "json" ]`).
  - `settings.web.search_backend = "searxng"`.
  - **`services.hermes-agent.mcpServers.{vane,home-assistant,stock-trader,email-contacts,
    perplexity,org-db}`** — this is the **top-level** module option (NOT
    `settings.mcpServers`, which is freeform YAML and would be silently ignored). The
    module maps it internally to `settings.mcp_servers`. Each entry sets `command` to an
    absolute store-path wrapper script (defined in a `let` block as
    `pkgs.writeShellScript`, mirroring openclaw-vm.nix's `*McpServer` wrappers and
    `homeAssistantMcpBridge`), plus `args`/`env` as needed.
- Define two python envs in the guest `let` block:
  - `lightPython = pkgs.python312.withPackages (ps: [ ps.mcp ps.requests ps.simplejson
    ps.psycopg2 ])` — for vane, email-contacts, perplexity, and org-db. (SearXNG is the
    native backend, not a script.) `psycopg2` is required by `org-db-mcp.py`'s read-only
    `org_sql` — `requests` cannot speak the PostgreSQL wire protocol.
  - `financialPython` (heavy: `mcp pandas numpy scipy matplotlib requests yahooquery
    py_vollib simplejson`) — **only** for `stock-trader-mcp.py`. Reuse the same definition
    as openclaw-microvm.nix (consider hoisting to a shared module/overlay to avoid drift —
    see §6).
  - `khardFixed` for email-contacts (khard on PATH in its wrapper). The email-contacts
    wrapper must export `EMAIL_PASSWORD_FILE=/run/hermes-secrets/imap-password` (matching
    the staged filename) plus the IMAP/SMTP host/port env the script expects.
- Add a `hermes-tools-setup` oneshot service (`before = [ "hermes-agent.service" ]`,
  `after` state mount) that writes the config files the email-contacts + org-db servers
  need and runs the initial contact sync. This is the relevant slice of OpenClaw's giant
  preStart, factored out:
  - `~/.config/khard/khard.conf`, `~/.config/vdirsyncer/config`, `~/.config/sherlock/
    config.json` (org-db-password injected via jq), `~/.config/org/config.yaml`.
  - run `vdirsyncer discover && sync` (best-effort, logged) to populate local vCards.
  - reads secrets from `/run/hermes-secrets/*`.

### 4.3 New scripts in `/etc/nixos/scripts/`
- `perplexity-mcp.py`: stdio MCP exposing `web_search(query, ...)` →
  `https://api.perplexity.ai/chat/completions` (model e.g. `sonar`), reading
  `PERPLEXITY_API_KEY` from env (wrapper exports it from the staged file). ~80 lines,
  modeled on `searxng-mcp.py`'s structure (FastMCP / `mcp` server, `requests`).
- `org-db-mcp.py`: stdio MCP exposing read-only `org_sql(query, limit)` and
  `org_search(query, n)`.
  - **`org_sql`** connects with **`psycopg2`** (in `lightPython`) to PostgreSQL as the
    existing **read-only role `openclaw`** (the role that owns `openclaw/org-db-password`;
    confirmed by OpenClaw's sherlock config + `orgDbSearch` using `PGUSER=openclaw`). The
    wrapper exports `PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=org PGUSER=openclaw` and
    `PGPASSWORD` from the staged `/run/hermes-secrets/org-db-password`. Reachable via the
    new 5432 DNAT. Read-only: the tool rejects any statement that is not a single `SELECT`.
  - **`org_search`** shells `org-jw db search` (like OpenClaw's `orgDbSearch` wrapper). That
    path needs **three** things, not just the PG password: `--base-url http://127.0.0.1:4000`
    (LiteLLM, via the existing 4000 DNAT), `-m hera/bge-m3` (embedding model from
    models.nix), and `--api-key <LiteLLM key>`. **Reuse `OPENROUTER_API_KEY`** for the
    api-key — it is already in Hermes's env (`hermes/env`) and is the LiteLLM virtual key
    Hermes uses for the `hera/*` route, so **no new secret needs to be staged** for org
    search. The MCP server inherits this env from its parent `hermes-agent` process.
    - **Runtime assumption to verify (advisory from spec review):** the inheritance holds
      only if Hermes injects its dotenv (`$HERMES_HOME/.env`, loaded by
      `load_hermes_dotenv()`) into `os.environ` *process-wide* before spawning stdio MCP
      children — the hermes-agent unit sets no systemd `EnvironmentFile`. The existing
      model-routing config relies on the same `os.environ` expansion, so this is likely
      true, but §5 must probe `org_search` end-to-end (an empty `--api-key` fails fast).
      **Fallback if inheritance does not hold:** set `env.OPENROUTER_API_KEY` explicitly on
      the `org-db` mcpServers entry, or have the wrapper read the key from a staged file —
      do NOT widen the secret surface beyond the LiteLLM virtual key Hermes already holds.

### 4.4 Docs / registry
- `docs/ports.txt`: note that the Hermes VM bridge (`10.99.1.1`) now DNATs
  443/993/2525/5232/5432/8123 in addition to 4000. (These host ports already exist; this
  records the new reachability path, not new listeners.)
- Update `project_hermes_agent.md` memory + any Hermes runbook docs to describe the new
  service surface.
- Consider extending `hermes-health-check` / nightly report to probe the new MCP servers
  (parity with `openclaw-mcporter-check`) — optional follow-up, flagged not required.

## 5. Verification (must pass before "done")
1. `nixos-rebuild build --flake '.#vulcan'` evaluates and builds clean.
2. After switch + VM restart: `microvm@hermes` healthy, `hermes-agent` starts without OOM
   (`systemctl status`, check `MemoryMax`/no oom-kill in journal).
3. Each MCP server process spawns and is listed by Hermes (`hermes`-side MCP/tool dump or
   log line). Confirm the model is actually offered the tools (toolset gotcha).
4. Functional probes (from inside the VM or via the api_server e2e path), with secret-safe
   output only — never paste tokens/passwords/PII:
   - SearXNG: `web_search` returns hits.
   - Vane: returns a cited synthesis.
   - HA: lists an entity/state (no token in output).
   - stock-trader: a quote.
   - email-contacts: folder list / contact count (no message bodies/PII).
   - Perplexity: an answer.
   - org-db: a trivial `SELECT count(*)` and a semantic search.
5. Egress/isolation unchanged for the deny path: VM still cannot reach arbitrary
   `192.168.0.0/16` hosts; `hermes-egress-rejected` log not flooded.
6. `nix fmt` clean; no secrets in any committed file or in the conversation.

## 6. Risks, trade-offs, and notes
- **Security posture (explicit):** this widens the Hermes VM's reach. A local 27B model
  with code execution will now reach HA (actuation), email send, Postgres, and the trader.
  Mitigations: the microVM remains the kernel-level isolation boundary; egress stays
  restricted (only the enumerated DNAT ports + 443/53 internet); the org-DB role is
  read-only and the MCP rejects non-SELECT; secrets are staged `0400 hermes:hermes`; **no
  new plaintext enters `secrets.yaml`**; the HA token is the existing scoped long-lived
  token (no new grant).
- **`financialPython` duplication:** defined in `openclaw-microvm.nix` and would be
  duplicated for stock-trader. Prefer hoisting it (and `khardFixed`, the MCP wrapper
  helpers) into a shared module or overlay so the two VMs can't drift. If hoisting is too
  invasive for this change, duplicate with a comment pointing at the canonical definition.
- **Memory:** 2048 MiB is an estimate. If stdio servers idle-load heavy imports, watch for
  OOM and tune. Lightweight python for the simple servers keeps RSS down.
- **HA bridge transport:** default to the proven `mcp-proxy` stdio bridge (OpenClaw's
  approach) because mcporter's auto-OAuth broke direct connection. Hermes's own MCP client
  *may* honor static `url` + `headers.Authorization` directly (no auto-OAuth); the
  implementation should try direct first and fall back to `mcp-proxy` if Hermes also probes
  OAuth. Either way the token comes from the staged file.
- **Contacts sync** is the heaviest single sub-piece (vdirsyncer + khard). If it proves
  flaky, email (IMAP/SMTP) parity can ship without contact lookup as a fallback.
- **Approach B (host-side shared MCP gateway)** remains the cleaner long-term architecture
  (de-dupes scripts/secrets, smaller VM surface) but is deferred to avoid a risky refactor
  of the working OpenClaw setup.

## 7. Execution model
Implementation will be driven as a **Workflow** (multi-agent orchestration): parallel
per-service implementation stages feeding an adversarial security + correctness review
pass, then a single consolidated build/verify. This matches the user's explicit request
for a workflow and the session's ultracode setting.
