# OpenClaw ↔ Hermes MCP Bridge Implementation Plan

> **Archival — 2026-05-12.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `pkgs/hermes-mcp/`, `modules/services/hermes-mcp.nix`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Hermes Agent invokable from OpenClaw as a multi-tool MCP server, exposing six tools (`ask_hermes`, `start_session`, `continue_session`, `list_sessions`, `summarize_session`, `delete_session`) over HTTPS/SSE, with conversation state persisted across calls.

**Architecture:** A new Python package `hermes-mcp` runs as a host-side systemd service. It speaks the official MCP protocol over SSE and is fronted by nginx at `https://hermes-mcp.vulcan.lan/sse` (Vulcan CA cert, mirroring the existing `drafts-mcp.vulcan.lan` pattern). Internally it stores session metadata in SQLite at `/var/lib/hermes-mcp/sessions.db` and proxies to Hermes' aiohttp `api_server` Platform (newly enabled inside the Hermes VM at `http://10.99.1.2:8080`, bridge-IP-only). OpenClaw learns about it via the existing `apply_mcporter_jq` preStart helper in `openclaw-vm.nix`.

**Tech Stack:** Python 3.12 · official `mcp` SDK (SSE server transport) · `httpx` (async HTTP to Hermes) · `aiosqlite` (async SQLite) · `pytest` + `pytest-asyncio` + `respx` (httpx mocking) · NixOS (`buildPythonPackage`) · nginx · sops-nix · existing Vulcan CA at `certs/renew-certificate.sh`.

---

## Scope Check

This plan covers one cohesive subsystem (the MCP bridge). Components touch four areas — the Hermes VM (open one port), the host (new Python package + nginx + systemd), the OpenClaw VM (one new MCP server entry), and ports.txt — but they're a single integration with one acceptance test (OpenClaw can call `ask_hermes` and get a Hermes reply). No split into multiple plans needed.

Out of scope (defer to a later phase):
- Streaming MCP responses (sync responses are sufficient for the chosen tool surface).
- Reverse direction (Hermes calling OpenClaw as a tool).
- Federated long-term memory between the two agents (each keeps its own).
- Hermes' `POST /v1/responses` (stateful Responses API) — we use `/v1/chat/completions` only.
- The `/v1/runs/{run_id}/approval` HITL approval flow — not needed for chat passthrough.

---

## File Structure

### Files to CREATE

```
pkgs/hermes-mcp/
├── default.nix                          # Nix derivation (buildPythonApplication)
├── pyproject.toml                       # Python project metadata
├── README.md                            # Operational notes
├── src/hermes_mcp/
│   ├── __init__.py                      # Package init; __version__
│   ├── __main__.py                      # CLI entrypoint (python -m hermes_mcp)
│   ├── config.py                        # Env-based config dataclass
│   ├── session_store.py                 # SQLite session persistence (async)
│   ├── hermes_client.py                 # Typed async client for Hermes /v1/* HTTP API
│   ├── tools.py                         # The six MCP tool implementations
│   └── server.py                        # MCP SSE server + tool wiring
└── tests/
    ├── conftest.py                      # Shared fixtures (tmp SQLite path, mock Hermes)
    ├── test_session_store.py            # Unit tests for the SQLite layer
    ├── test_hermes_client.py            # Unit tests for the HTTP client (respx mocks)
    ├── test_tools.py                    # Unit tests for each tool (mocked client + store)
    └── test_integration.py              # Optional gated integration test (env-flag)

modules/services/hermes-mcp.nix          # NixOS module: systemd unit + nginx vhost + tmpfiles

docs/openclaw-hermes-integration.md      # User-facing operational notes
```

### Files to MODIFY

| File | What changes |
|---|---|
| `flake.nix` | Add `pkgs/hermes-mcp` to the package set (`callPackage ./pkgs/hermes-mcp { }`) so it's reachable as `pkgs.hermes-mcp` |
| `hosts/vulcan/default.nix` | Import `./modules/services/hermes-mcp.nix` |
| `modules/services/hermes-vm.nix` | (a) Add `gateway.platforms = [ "discord" "api_server" ]` to settings (b) Pass `API_SERVER_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, `API_SERVER_PORT=8080`, `API_SERVER_KEY=…` via the env file (c) Open guest firewall port 22→ extend to also allow `${bridgeAddr}` source on 8080 |
| `modules/services/openclaw-vm.nix` | Add a 7th `apply_mcporter_jq` block (between Vane and the final `tools` write) inserting `mcpServers["hermes"]` with `url = "https://hermes-mcp.vulcan.lan/sse"` |
| `secrets/secrets.yaml` (via `sops`, user drives) | Add `hermes-mcp/api-key` (64-hex random) and a *separate copy* under `hermes/env` (`API_SERVER_KEY=…`) so both VM and host see the same shared secret |
| `docs/ports.txt` | Reserve `8080 10.99.1.2 Hermes Agent api_server platform (HTTPS, bridge-IP only, OpenClaw via hermes-mcp)` and `9081 127.0.0.1 hermes-mcp (SSE upstream for nginx vhost hermes-mcp.vulcan.lan)` |

### Reference pattern files (READ-ONLY — do not modify but lean on them)

- `modules/services/openclaw-microvm.nix:775-803` — exact nginx vhost shape for SSE backends.
- `modules/services/openclaw-vm.nix:800-811` — `apply_mcporter_jq` helper definition.
- `modules/services/openclaw-vm.nix:835-843` — `mcpServers["drafts"]` SSE entry (template for ours).
- `modules/services/hermes-vm.nix:200-280` — existing `services.hermes-agent.settings` block (where new `gateway.platforms` entry lands).
- `modules/services/hermes-vm.nix:336-356` — existing `services.openssh` + `networking.firewall.extraInputRules` (template for the new 8080 firewall rule).
- `certs/renew-certificate.sh` — script to mint `hermes-mcp.vulcan.lan.crt` against the Vulcan CA (mirror the call site of `drafts-mcp.vulcan.lan` issuance).
- `/nix/store/r7xsk0w6k7i2mxby9zzqp2q3mf5s67ky-hermes-agent-0.13.0/lib/python3.12/site-packages/gateway/platforms/api_server.py` — authoritative spec for the Hermes endpoint (study `POST /v1/chat/completions` request/response, `X-Hermes-Session-Id`/`X-Hermes-Session-Key` semantics, and the capabilities response at line ~923 for what the API actually returns).

---

## Port Allocation (reserve before Task 1)

| Port | Bind | Owner | Purpose |
|---|---|---|---|
| 8080 | `0.0.0.0:8080` inside hermes-vm | hermes-agent's `api_server` Platform | aiohttp HTTP API; firewall scopes source to bridge IP only |
| 9081 | `127.0.0.1:9081` on host | `hermes-mcp.service` | SSE upstream for nginx vhost |

`docs/ports.txt` must record both BEFORE the first rebuild that opens them.

---

## Cross-Cutting Conventions

- **TDD:** Each Python module ships with a failing test first, minimal implementation, passing test, commit. No code lands without a test that exercises it.
- **No mocking of SQLite:** Use `aiosqlite` against a `tmp_path` fixture. Real schema, real queries, in a temp file.
- **Mocking Hermes HTTP:** Use `respx` to intercept httpx calls in `test_hermes_client.py` and `test_tools.py`. The `test_integration.py` is gated by `HERMES_MCP_INTEGRATION=1` env var and hits the real VM.
- **Commits per task:** Each task ends with a commit. Commit messages follow the existing repo convention (`feat(hermes-mcp): …`, `feat(hermes-vm): …`, `feat(openclaw): wire hermes mcp …`).
- **Don't decrypt SOPS secrets** in the plan execution. The user drives `sops` when secret edits are needed (Task 2 step 1).
- **No --no-verify / no skipping hooks.** Pre-commit hooks (`nix fmt`, etc.) must pass.

---

## Task 1: Project scaffolding & port reservation

**Files:**
- Create: `pkgs/hermes-mcp/default.nix`
- Create: `pkgs/hermes-mcp/pyproject.toml`
- Create: `pkgs/hermes-mcp/README.md`
- Create: `pkgs/hermes-mcp/src/hermes_mcp/__init__.py`
- Create: `pkgs/hermes-mcp/src/hermes_mcp/__main__.py`
- Modify: `flake.nix` (add `hermes-mcp = pkgs.callPackage ./pkgs/hermes-mcp { };` to the package set)
- Modify: `docs/ports.txt` (reserve 8080 on 10.99.1.2 and 9081 on 127.0.0.1)

**What "done" means:** `nix build .#hermes-mcp` succeeds and produces a binary at `result/bin/hermes-mcp` that prints `hermes-mcp 0.1.0` and exits 0.

- [ ] **Step 1: Reserve ports in `docs/ports.txt`**

Add two lines in numerical order:
```
8080 10.99.1.2 Hermes Agent api_server platform (HTTPS, bridge-IP only)
9081 127.0.0.1 hermes-mcp (SSE upstream for nginx vhost hermes-mcp.vulcan.lan)
```

- [ ] **Step 2: Write `pkgs/hermes-mcp/pyproject.toml`**

```toml
[project]
name = "hermes-mcp"
version = "0.1.0"
description = "MCP server bridging OpenClaw to Hermes Agent over SSE"
requires-python = ">=3.12"
dependencies = [
  "mcp>=1.2",
  "httpx>=0.27",
  "aiosqlite>=0.20",
  "pydantic>=2.6",
]

[project.optional-dependencies]
dev = [
  "pytest>=8.0",
  "pytest-asyncio>=0.23",
  "respx>=0.21",
]

[project.scripts]
hermes-mcp = "hermes_mcp.__main__:main"

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
where = ["src"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
```

- [ ] **Step 3: Write `pkgs/hermes-mcp/src/hermes_mcp/__init__.py`**

```python
"""MCP bridge from OpenClaw to Hermes Agent."""
__version__ = "0.1.0"
```

- [ ] **Step 4: Write `pkgs/hermes-mcp/src/hermes_mcp/__main__.py`**

```python
"""CLI entrypoint — `python -m hermes_mcp` or `hermes-mcp` binary."""
import sys
from hermes_mcp import __version__


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--version", "-V"):
        print(f"hermes-mcp {__version__}")
        return 0
    # Server entrypoint lands here in Task 6.
    from hermes_mcp.server import run
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 5: Write `pkgs/hermes-mcp/default.nix`**

```nix
{
  lib,
  python312,
  python312Packages,
}:
python312Packages.buildPythonApplication {
  pname = "hermes-mcp";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = with python312Packages; [
    setuptools
  ];

  dependencies = with python312Packages; [
    mcp
    httpx
    aiosqlite
    pydantic
  ];

  nativeCheckInputs = with python312Packages; [
    pytest
    pytest-asyncio
    respx
  ];

  # Hermes-side integration tests are gated by env var; safe to run unit tests in nixbuild.
  pytestFlagsArray = [ "tests/" ];

  meta = with lib; {
    description = "MCP server bridging OpenClaw to Hermes Agent";
    homepage = "https://hermes-mcp.vulcan.lan";
    license = licenses.mit;
    mainProgram = "hermes-mcp";
  };
}
```

- [ ] **Step 6: Write `pkgs/hermes-mcp/README.md`**

```markdown
# hermes-mcp

MCP server bridging OpenClaw to Hermes Agent over SSE.

See `/etc/nixos/docs/openclaw-hermes-integration.md` for operational notes
and `/etc/nixos/docs/superpowers/plans/2026-05-12-openclaw-hermes-mcp-bridge.md`
for the implementation history.
```

- [ ] **Step 7: Register the package in `flake.nix`**

Locate the `packages.${system}` (or `overlays.default`) attrset and add:
```nix
hermes-mcp = pkgs.callPackage ./pkgs/hermes-mcp { };
```

- [ ] **Step 8: Build to verify the skeleton compiles**

Run: `nix build .#hermes-mcp 2>&1 | tail -20`
Expected: build succeeds; `./result/bin/hermes-mcp --version` prints `hermes-mcp 0.1.0`.

(The `from hermes_mcp.server import run` line will fail when invoked without `--version`; that's expected — Task 6 implements `server.run()`. The build only needs to *compile* the package, not run it.)

- [ ] **Step 9: Commit**

```bash
git add pkgs/hermes-mcp/ flake.nix docs/ports.txt
git commit -m "feat(hermes-mcp): scaffold Python package + Nix derivation"
```

---

## Task 2: Enable Hermes' api_server Platform inside the VM

**Files:**
- Modify: `modules/services/hermes-vm.nix` (settings + firewall + env injection)
- User-driven: `secrets/secrets.yaml` via `sops` — add `API_SERVER_KEY=<64-hex>` to the existing `hermes/env` block

**What "done" means:** From the host, `curl -sS -X POST -H "Authorization: Bearer $KEY" http://10.99.1.2:8080/v1/chat/completions -d '{"model":"hera/omlx/Qwen3.6-27B-MLX-8bit","messages":[{"role":"user","content":"ping"}]}'` returns a 200 with a chat completion.

- [ ] **Step 1: Ask the user to generate and store the shared API key**

```
openssl rand -hex 32
```

User pastes the value into `sops /etc/nixos/secrets/secrets.yaml` under the existing `hermes:` block as a new `API_SERVER_KEY: <hex>` entry. (Reuses the same env file already mounted into the VM at `${stateDir}/env`.)

**Confirm with user before proceeding.** The user runs `sops`; the implementer subagent does NOT decrypt the file.

- [ ] **Step 2: Add `api_server` to the gateway platforms list**

In `modules/services/hermes-vm.nix` inside `services.hermes-agent.settings`, find the existing `gateway` block (currently `gateway = { enabled = true; platforms = [ "discord" ]; };`) and update to:

```nix
gateway = {
  enabled = true;
  platforms = [ "discord" "api_server" ];
};
```

- [ ] **Step 3: Add API_SERVER_* env vars next to other API_SERVER_KEY consumption**

The `API_SERVER_KEY` comes from the env file (Step 1). The remaining knobs go in
`systemd.services.hermes-agent.environment` (after the existing `PYTHONPATH` line near
`modules/services/hermes-vm.nix:263-266`):

```nix
systemd.services.hermes-agent.environment = {
  PYTHONPATH = "${hermesTimeoutShim}";
  API_SERVER_ENABLED = "true";
  API_SERVER_HOST = "0.0.0.0";  # Bind to all VM interfaces — guest fw scopes source.
  API_SERVER_PORT = "8080";
};
```

(`API_SERVER_KEY` is already imported via `environmentFiles = [ "${stateDir}/env" ]`.)

- [ ] **Step 4: Open the firewall for the new port**

Extend the existing `networking.firewall.extraInputRules` block (lines ~352-355) to add a second `accept` rule:

```nix
networking.firewall = {
  enable = true;
  extraInputRules = ''
    ip saddr ${bridgeAddr} tcp dport 22 accept comment "claude debug ssh from host bridge"
    ip saddr ${bridgeAddr} tcp dport 8080 accept comment "hermes api_server from host bridge"
  '';
};
```

- [ ] **Step 5: Rebuild and confirm the VM reboot**

Ask the user: "Rebuild and switch to deploy the API server config?"

If yes:
```bash
touch /etc/nixos/.nixos-build
sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tail -20
rm -f /etc/nixos/.nixos-build
```

- [ ] **Step 6: Wait for VM to come back, then smoke-test the endpoint**

```bash
sudo rm -f /root/.ssh/hermes-known_hosts
until sudo timeout 2 bash -c "</dev/tcp/10.99.1.2/22" 2>/dev/null; do sleep 2; done
until sudo timeout 2 bash -c "</dev/tcp/10.99.1.2/8080" 2>/dev/null; do sleep 2; done
```

Then read the key from the env file (you have read access to it as root on host) — DO NOT print it:

```bash
KEY=$(sudo grep '^API_SERVER_KEY=' /var/lib/hermes/.hermes/.env | cut -d= -f2- | tr -d '"')
[ -n "$KEY" ] && echo "key loaded"
```

Probe `/v1/capabilities` first (no body needed, lightweight):

```bash
curl -sS -m 10 -H "Authorization: Bearer $KEY" \
  http://10.99.1.2:8080/v1/capabilities | head -20
```

Expected: 200 with a JSON object containing `"object": "hermes.api_server.capabilities"` and an `endpoints` map.

Then a real chat call:
```bash
curl -sS -m 120 -X POST \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  http://10.99.1.2:8080/v1/chat/completions \
  -d '{"model":"hera/omlx/Qwen3.6-27B-MLX-8bit","messages":[{"role":"user","content":"ping"}],"max_tokens":20}'
```

Expected: 200 with an OpenAI-shaped chat completion. Note the response time is ~10-60s for MLX prefill.

- [ ] **Step 7: Commit**

```bash
git add modules/services/hermes-vm.nix
git commit -m "feat(hermes-vm): enable api_server gateway platform on port 8080"
```

---

## Task 3: Session storage layer (SQLite)

**Files:**
- Create: `pkgs/hermes-mcp/src/hermes_mcp/session_store.py`
- Create: `pkgs/hermes-mcp/tests/conftest.py`
- Create: `pkgs/hermes-mcp/tests/test_session_store.py`

**What "done" means:** All session_store unit tests pass under `pytest tests/test_session_store.py -v` inside the Nix build.

### Schema

```sql
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,                    -- uuid4() hex
    name TEXT,                              -- nullable human label
    hermes_session_id TEXT NOT NULL,        -- value sent as X-Hermes-Session-Id
    created_at REAL NOT NULL,               -- unix ts
    last_used_at REAL NOT NULL,
    message_count INTEGER NOT NULL DEFAULT 0,
    summary TEXT                            -- cached summary from summarize_session
);
CREATE INDEX IF NOT EXISTS idx_sessions_last_used ON sessions(last_used_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_name ON sessions(name) WHERE name IS NOT NULL;
```

### API

```python
@dataclass(frozen=True)
class Session:
    id: str
    name: str | None
    hermes_session_id: str
    created_at: float
    last_used_at: float
    message_count: int
    summary: str | None


class SessionStore:
    def __init__(self, db_path: Path): ...
    async def init(self) -> None: ...                          # create schema if missing
    async def create(self, name: str | None = None) -> Session: ...
    async def get(self, session_id: str) -> Session | None: ...
    async def get_by_name(self, name: str) -> Session | None: ...
    async def list(self, limit: int = 50) -> list[Session]: ...
    async def touch(self, session_id: str, *, increment_messages: bool = True) -> None: ...
    async def set_summary(self, session_id: str, summary: str) -> None: ...
    async def delete(self, session_id: str) -> bool: ...        # returns True if deleted
```

### Steps

- [ ] **Step 1: Write conftest.py**

```python
# pkgs/hermes-mcp/tests/conftest.py
import pytest
from pathlib import Path


@pytest.fixture
def tmp_db_path(tmp_path: Path) -> Path:
    return tmp_path / "sessions.db"
```

- [ ] **Step 2: Write the failing tests**

```python
# pkgs/hermes-mcp/tests/test_session_store.py
import asyncio
import time

import pytest

from hermes_mcp.session_store import Session, SessionStore


@pytest.mark.asyncio
async def test_create_assigns_uuid_and_timestamps(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    before = time.time()
    s = await store.create(name="research")
    after = time.time()

    assert len(s.id) == 32  # uuid4().hex
    assert s.name == "research"
    assert s.hermes_session_id  # non-empty
    assert before <= s.created_at <= after
    assert s.created_at == s.last_used_at
    assert s.message_count == 0
    assert s.summary is None


@pytest.mark.asyncio
async def test_get_returns_none_for_missing(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    assert await store.get("nonexistent") is None


@pytest.mark.asyncio
async def test_get_by_name(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create(name="planning")
    found = await store.get_by_name("planning")
    assert found is not None
    assert found.id == s.id


@pytest.mark.asyncio
async def test_list_returns_descending_by_last_used(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s1 = await store.create(name="first")
    await asyncio.sleep(0.01)
    s2 = await store.create(name="second")
    sessions = await store.list()
    assert [s.id for s in sessions] == [s2.id, s1.id]


@pytest.mark.asyncio
async def test_touch_updates_last_used_and_increments_count(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create()
    original_last = s.last_used_at
    original_count = s.message_count
    await asyncio.sleep(0.01)
    await store.touch(s.id, increment_messages=True)
    after = await store.get(s.id)
    assert after.last_used_at > original_last
    assert after.message_count == original_count + 1


@pytest.mark.asyncio
async def test_set_summary_persists(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create()
    await store.set_summary(s.id, "User explored MCP integration options.")
    after = await store.get(s.id)
    assert after.summary == "User explored MCP integration options."


@pytest.mark.asyncio
async def test_delete_returns_true_then_false(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    s = await store.create()
    assert await store.delete(s.id) is True
    assert await store.delete(s.id) is False
    assert await store.get(s.id) is None


@pytest.mark.asyncio
async def test_init_is_idempotent(tmp_db_path):
    store = SessionStore(tmp_db_path)
    await store.init()
    await store.init()  # must not raise
```

- [ ] **Step 3: Run the test, confirm all fail**

```bash
cd pkgs/hermes-mcp && python -m pytest tests/test_session_store.py -v 2>&1 | tail -20
```
Expected: All 7 tests fail with `ModuleNotFoundError: No module named 'hermes_mcp.session_store'`.

- [ ] **Step 4: Write the minimal implementation**

```python
# pkgs/hermes-mcp/src/hermes_mcp/session_store.py
"""SQLite-backed session metadata store.

Holds OUR side of the session bookkeeping (id, name, last-used, count,
cached summary).  The actual conversation history lives inside Hermes
itself and is keyed by `hermes_session_id`, which Hermes echoes back
through the `X-Hermes-Session-Id` response header on the first request.
"""
from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from pathlib import Path

import aiosqlite

_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    name TEXT,
    hermes_session_id TEXT NOT NULL,
    created_at REAL NOT NULL,
    last_used_at REAL NOT NULL,
    message_count INTEGER NOT NULL DEFAULT 0,
    summary TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_last_used ON sessions(last_used_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_name ON sessions(name) WHERE name IS NOT NULL;
"""


@dataclass(frozen=True)
class Session:
    id: str
    name: str | None
    hermes_session_id: str
    created_at: float
    last_used_at: float
    message_count: int
    summary: str | None


class SessionStore:
    def __init__(self, db_path: Path):
        self._db_path = db_path

    async def init(self) -> None:
        async with aiosqlite.connect(self._db_path) as db:
            await db.executescript(_SCHEMA)
            await db.commit()

    async def create(self, name: str | None = None) -> Session:
        now = time.time()
        sid = uuid.uuid4().hex
        hid = uuid.uuid4().hex  # what we'll send as X-Hermes-Session-Id
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                "INSERT INTO sessions (id, name, hermes_session_id, created_at, "
                "last_used_at, message_count, summary) VALUES (?, ?, ?, ?, ?, 0, NULL)",
                (sid, name, hid, now, now),
            )
            await db.commit()
        return Session(sid, name, hid, now, now, 0, None)

    async def get(self, session_id: str) -> Session | None:
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cur = await db.execute(
                "SELECT * FROM sessions WHERE id = ?", (session_id,)
            )
            row = await cur.fetchone()
            return _row_to_session(row) if row else None

    async def get_by_name(self, name: str) -> Session | None:
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cur = await db.execute(
                "SELECT * FROM sessions WHERE name = ? ORDER BY last_used_at DESC LIMIT 1",
                (name,),
            )
            row = await cur.fetchone()
            return _row_to_session(row) if row else None

    async def list(self, limit: int = 50) -> list[Session]:
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cur = await db.execute(
                "SELECT * FROM sessions ORDER BY last_used_at DESC LIMIT ?", (limit,)
            )
            rows = await cur.fetchall()
            return [_row_to_session(r) for r in rows]

    async def touch(self, session_id: str, *, increment_messages: bool = True) -> None:
        now = time.time()
        delta = 1 if increment_messages else 0
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                "UPDATE sessions SET last_used_at = ?, message_count = message_count + ? "
                "WHERE id = ?",
                (now, delta, session_id),
            )
            await db.commit()

    async def set_summary(self, session_id: str, summary: str) -> None:
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                "UPDATE sessions SET summary = ? WHERE id = ?", (summary, session_id)
            )
            await db.commit()

    async def delete(self, session_id: str) -> bool:
        async with aiosqlite.connect(self._db_path) as db:
            cur = await db.execute(
                "DELETE FROM sessions WHERE id = ?", (session_id,)
            )
            await db.commit()
            return cur.rowcount > 0


def _row_to_session(row: aiosqlite.Row) -> Session:
    return Session(
        id=row["id"],
        name=row["name"],
        hermes_session_id=row["hermes_session_id"],
        created_at=row["created_at"],
        last_used_at=row["last_used_at"],
        message_count=row["message_count"],
        summary=row["summary"],
    )
```

- [ ] **Step 5: Run tests, confirm all pass**

```bash
cd pkgs/hermes-mcp && python -m pytest tests/test_session_store.py -v 2>&1 | tail -25
```
Expected: 7 passed.

- [ ] **Step 6: Commit**

```bash
git add pkgs/hermes-mcp/src/hermes_mcp/session_store.py pkgs/hermes-mcp/tests/test_session_store.py pkgs/hermes-mcp/tests/conftest.py
git commit -m "feat(hermes-mcp): SQLite-backed session store with TDD coverage"
```

---

## Task 4: Hermes HTTP client

**Files:**
- Create: `pkgs/hermes-mcp/src/hermes_mcp/config.py` (small dataclass first; one test)
- Create: `pkgs/hermes-mcp/src/hermes_mcp/hermes_client.py`
- Create: `pkgs/hermes-mcp/tests/test_hermes_client.py`

**What "done" means:** `pytest tests/test_hermes_client.py -v` passes (respx-mocked).

### Config dataclass first

- [ ] **Step 1: Write `config.py` and a tiny test**

```python
# src/hermes_mcp/config.py
"""Env-driven runtime config for hermes-mcp."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    hermes_api_url: str         # e.g. http://10.99.1.2:8080
    hermes_api_key: str         # Authorization: Bearer ${this} (Hermes API_SERVER_KEY)
    model: str                  # default model to use, e.g. hera/omlx/Qwen3.6-27B-MLX-8bit
    db_path: Path
    sse_host: str               # e.g. 127.0.0.1
    sse_port: int               # e.g. 9081
    request_timeout_seconds: float = 600.0

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            hermes_api_url=_required("HERMES_API_URL").rstrip("/"),
            hermes_api_key=_required("HERMES_API_KEY"),
            model=os.environ.get("HERMES_MCP_MODEL", "hera/omlx/Qwen3.6-27B-MLX-8bit"),
            db_path=Path(os.environ.get("HERMES_MCP_DB_PATH", "/var/lib/hermes-mcp/sessions.db")),
            sse_host=os.environ.get("HERMES_MCP_HOST", "127.0.0.1"),
            sse_port=int(os.environ.get("HERMES_MCP_PORT", "9081")),
            request_timeout_seconds=float(os.environ.get("HERMES_MCP_TIMEOUT", "600")),
        )


def _required(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        raise RuntimeError(f"required env var {name} is not set")
    return v
```

(Test for config is a single `test_config_from_env_requires_url_and_key` — write that into `test_hermes_client.py` for brevity since they're tightly coupled.)

### Client API

```python
class HermesClient:
    def __init__(self, config: Config, http: httpx.AsyncClient | None = None): ...
    async def chat(self, *, hermes_session_id: str, prompt: str, model: str | None = None) -> str: ...
    async def get_capabilities(self) -> dict: ...   # GET /v1/capabilities
    async def aclose(self) -> None: ...
```

- [ ] **Step 2: Write failing tests with respx**

```python
# pkgs/hermes-mcp/tests/test_hermes_client.py
import os
from pathlib import Path

import httpx
import pytest
import respx

from hermes_mcp.config import Config
from hermes_mcp.hermes_client import HermesClient


@pytest.fixture
def cfg(tmp_path: Path) -> Config:
    return Config(
        hermes_api_url="http://hermes.test:8080",
        hermes_api_key="key-deadbeef",
        model="test-model",
        db_path=tmp_path / "s.db",
        sse_host="127.0.0.1",
        sse_port=9081,
    )


def test_config_from_env_requires_url_and_key(monkeypatch):
    monkeypatch.delenv("HERMES_API_URL", raising=False)
    monkeypatch.delenv("HERMES_API_KEY", raising=False)
    with pytest.raises(RuntimeError, match="HERMES_API_URL"):
        Config.from_env()
    monkeypatch.setenv("HERMES_API_URL", "http://x")
    with pytest.raises(RuntimeError, match="HERMES_API_KEY"):
        Config.from_env()


@pytest.mark.asyncio
@respx.mock
async def test_chat_sends_session_headers_and_returns_content(cfg):
    route = respx.post("http://hermes.test:8080/v1/chat/completions").mock(
        return_value=httpx.Response(
            200,
            json={
                "id": "cmpl-1",
                "object": "chat.completion",
                "created": 0,
                "model": "test-model",
                "choices": [
                    {"index": 0, "message": {"role": "assistant", "content": "hello back"},
                     "finish_reason": "stop"}
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3},
            },
        )
    )
    client = HermesClient(cfg)
    try:
        reply = await client.chat(hermes_session_id="hsid-1", prompt="hello")
    finally:
        await client.aclose()

    assert reply == "hello back"
    sent = route.calls.last.request
    assert sent.headers["Authorization"] == "Bearer key-deadbeef"
    assert sent.headers["X-Hermes-Session-Id"] == "hsid-1"
    assert sent.headers["X-Hermes-Session-Id"] == "hsid-1"
    body = sent.read().decode()
    assert "test-model" in body
    assert "hello" in body


@pytest.mark.asyncio
@respx.mock
async def test_chat_raises_on_non_200(cfg):
    respx.post("http://hermes.test:8080/v1/chat/completions").mock(
        return_value=httpx.Response(401, json={"error": "bad key"})
    )
    client = HermesClient(cfg)
    try:
        with pytest.raises(httpx.HTTPStatusError):
            await client.chat(hermes_session_id="hsid-1", prompt="hi")
    finally:
        await client.aclose()


@pytest.mark.asyncio
@respx.mock
async def test_get_capabilities_returns_endpoint_map(cfg):
    respx.get("http://hermes.test:8080/v1/capabilities").mock(
        return_value=httpx.Response(
            200,
            json={
                "object": "hermes.api_server.capabilities",
                "endpoints": {"chat_completions": {"method": "POST", "path": "/v1/chat/completions"}},
            },
        )
    )
    client = HermesClient(cfg)
    try:
        caps = await client.get_capabilities()
    finally:
        await client.aclose()
    assert caps["object"] == "hermes.api_server.capabilities"
```

- [ ] **Step 3: Run, confirm fail (ModuleNotFoundError)**

```bash
cd pkgs/hermes-mcp && python -m pytest tests/test_hermes_client.py -v 2>&1 | tail -10
```

- [ ] **Step 4: Write `hermes_client.py`**

```python
# src/hermes_mcp/hermes_client.py
"""Typed async client for Hermes Agent's aiohttp api_server platform."""
from __future__ import annotations

import httpx

from hermes_mcp.config import Config


class HermesClient:
    def __init__(self, config: Config, http: httpx.AsyncClient | None = None):
        self._cfg = config
        self._http = http or httpx.AsyncClient(
            base_url=config.hermes_api_url,
            timeout=httpx.Timeout(
                connect=30.0,
                read=config.request_timeout_seconds,
                write=config.request_timeout_seconds,
                pool=30.0,
            ),
            headers={"Authorization": f"Bearer {config.hermes_api_key}"},
        )

    async def chat(
        self,
        *,
        hermes_session_id: str,
        prompt: str,
        model: str | None = None,
    ) -> str:
        payload = {
            "model": model or self._cfg.model,
            "messages": [{"role": "user", "content": prompt}],
        }
        r = await self._http.post(
            "/v1/chat/completions",
            headers={"X-Hermes-Session-Id": hermes_session_id},
            json=payload,
        )
        r.raise_for_status()
        data = r.json()
        return data["choices"][0]["message"]["content"]

    async def get_capabilities(self) -> dict:
        r = await self._http.get("/v1/capabilities")
        r.raise_for_status()
        return r.json()

    async def aclose(self) -> None:
        await self._http.aclose()
```

- [ ] **Step 5: Run tests, confirm all pass**

```bash
cd pkgs/hermes-mcp && python -m pytest tests/ -v 2>&1 | tail -20
```
Expected: All session_store tests + 4 hermes_client tests pass.

- [ ] **Step 6: Commit**

```bash
git add pkgs/hermes-mcp/src/hermes_mcp/{config,hermes_client}.py pkgs/hermes-mcp/tests/test_hermes_client.py
git commit -m "feat(hermes-mcp): typed async client for Hermes api_server"
```

---

## Task 5: MCP tool implementations

**Files:**
- Create: `pkgs/hermes-mcp/src/hermes_mcp/tools.py`
- Create: `pkgs/hermes-mcp/tests/test_tools.py`

**What "done" means:** All six tools have unit-test coverage (`pytest tests/test_tools.py -v`).

### Tool contract (kept stable across server.py and tools.py)

Each tool is a free function `async def tool_<name>(store, client, **kwargs) -> dict`. They return JSON-serializable dicts; the MCP server in Task 6 turns those into `TextContent` blocks.

```python
async def tool_start_session(store, client, *, name: str | None = None) -> dict: ...
async def tool_ask_hermes(store, client, *, prompt: str, session_id: str | None = None) -> dict: ...
async def tool_continue_session(store, client, *, session_id: str, prompt: str) -> dict: ...
async def tool_list_sessions(store, client, *, limit: int = 50) -> dict: ...
async def tool_summarize_session(store, client, *, session_id: str) -> dict: ...
async def tool_delete_session(store, client, *, session_id: str) -> dict: ...
```

### Behavior

- **`start_session(name?)`** → creates a Session row, returns `{ session_id, name, hermes_session_id, created_at }`. Does NOT contact Hermes (lazy — session begins on first `chat` call).
- **`ask_hermes(prompt, session_id?)`** → if `session_id` is omitted, calls `store.create(name=None)` and uses that; calls `client.chat(...)`; `store.touch(...)`. Returns `{ session_id, reply, message_count }`.
- **`continue_session(session_id, prompt)`** → requires `session_id`. Returns 404-shaped error dict if missing. Otherwise same as ask_hermes.
- **`list_sessions(limit=50)`** → returns `{ sessions: [{id, name, hermes_session_id, created_at, last_used_at, message_count, summary}, ...] }`.
- **`summarize_session(session_id)`** → sends Hermes a meta-prompt asking it to summarize the session in 3-5 sentences, stores the result via `store.set_summary`, returns `{ session_id, summary }`.
- **`delete_session(session_id)`** → calls `store.delete`. Returns `{ deleted: bool }`. Does not currently call Hermes to clean up server-side session (Hermes prunes its own; leaving an orphan hermes_session_id is benign).

### Steps

- [ ] **Step 1: Write failing tests**

```python
# pkgs/hermes-mcp/tests/test_tools.py
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from hermes_mcp.config import Config
from hermes_mcp.hermes_client import HermesClient
from hermes_mcp.session_store import SessionStore
from hermes_mcp import tools


@pytest.fixture
def cfg(tmp_path: Path) -> Config:
    return Config(
        hermes_api_url="http://hermes.test:8080",
        hermes_api_key="k",
        model="m",
        db_path=tmp_path / "s.db",
        sse_host="127.0.0.1",
        sse_port=9081,
    )


@pytest.fixture
async def store(cfg: Config) -> SessionStore:
    s = SessionStore(cfg.db_path)
    await s.init()
    return s


@pytest.fixture
def mock_client() -> AsyncMock:
    c = AsyncMock(spec=HermesClient)
    c.chat.return_value = "mock reply"
    return c


@pytest.mark.asyncio
async def test_start_session_creates_row_without_calling_hermes(store, mock_client):
    out = await tools.tool_start_session(store, mock_client, name="planning")
    assert out["name"] == "planning"
    assert len(out["session_id"]) == 32
    assert "hermes_session_id" in out
    mock_client.chat.assert_not_awaited()


@pytest.mark.asyncio
async def test_ask_hermes_without_session_creates_one(store, mock_client):
    out = await tools.tool_ask_hermes(store, mock_client, prompt="hi there")
    assert out["reply"] == "mock reply"
    assert "session_id" in out
    assert out["message_count"] == 1
    mock_client.chat.assert_awaited_once()


@pytest.mark.asyncio
async def test_ask_hermes_with_session_reuses(store, mock_client):
    started = await tools.tool_start_session(store, mock_client, name="x")
    out = await tools.tool_ask_hermes(
        store, mock_client, prompt="hi", session_id=started["session_id"]
    )
    assert out["session_id"] == started["session_id"]
    assert out["message_count"] == 1


@pytest.mark.asyncio
async def test_continue_session_requires_existing(store, mock_client):
    out = await tools.tool_continue_session(
        store, mock_client, session_id="nonexistent", prompt="hi"
    )
    assert "error" in out
    assert "not found" in out["error"].lower()
    mock_client.chat.assert_not_awaited()


@pytest.mark.asyncio
async def test_continue_session_happy_path(store, mock_client):
    started = await tools.tool_start_session(store, mock_client, name=None)
    out = await tools.tool_continue_session(
        store, mock_client, session_id=started["session_id"], prompt="hi"
    )
    assert out["reply"] == "mock reply"


@pytest.mark.asyncio
async def test_list_sessions(store, mock_client):
    await tools.tool_start_session(store, mock_client, name="a")
    await tools.tool_start_session(store, mock_client, name="b")
    out = await tools.tool_list_sessions(store, mock_client)
    assert len(out["sessions"]) == 2


@pytest.mark.asyncio
async def test_summarize_session_uses_meta_prompt_and_stores(store, mock_client):
    mock_client.chat.return_value = "Summary: discussed plans."
    started = await tools.tool_start_session(store, mock_client, name="x")
    out = await tools.tool_summarize_session(
        store, mock_client, session_id=started["session_id"]
    )
    assert out["summary"] == "Summary: discussed plans."
    # Stored
    after = await store.get(started["session_id"])
    assert after.summary == "Summary: discussed plans."
    # Used the SAME hermes_session_id so summary has context
    sent_kwargs = mock_client.chat.await_args.kwargs
    assert sent_kwargs["hermes_session_id"] == started["hermes_session_id"]


@pytest.mark.asyncio
async def test_delete_session_returns_true_then_false(store, mock_client):
    started = await tools.tool_start_session(store, mock_client, name=None)
    out1 = await tools.tool_delete_session(store, mock_client, session_id=started["session_id"])
    assert out1["deleted"] is True
    out2 = await tools.tool_delete_session(store, mock_client, session_id=started["session_id"])
    assert out2["deleted"] is False
```

- [ ] **Step 2: Run, confirm fail (ModuleNotFoundError)**

- [ ] **Step 3: Write `tools.py`**

```python
# src/hermes_mcp/tools.py
"""MCP tool implementations.  Pure async functions — no MCP-SDK types here.

The SDK plumbing lives in server.py; keeping these functions pure makes
them testable with stdlib mocks.
"""
from __future__ import annotations

from hermes_mcp.hermes_client import HermesClient
from hermes_mcp.session_store import Session, SessionStore

_SUMMARY_PROMPT = (
    "Please summarize the conversation we've had in this session in "
    "3-5 sentences. Focus on decisions, open questions, and anything that "
    "would help someone resuming this thread later."
)


def _session_to_dict(s: Session) -> dict:
    return {
        "session_id": s.id,
        "name": s.name,
        "hermes_session_id": s.hermes_session_id,
        "created_at": s.created_at,
        "last_used_at": s.last_used_at,
        "message_count": s.message_count,
        "summary": s.summary,
    }


async def tool_start_session(
    store: SessionStore,
    client: HermesClient,  # noqa: ARG001 — kept in signature for symmetry
    *,
    name: str | None = None,
) -> dict:
    s = await store.create(name=name)
    return _session_to_dict(s)


async def tool_ask_hermes(
    store: SessionStore,
    client: HermesClient,
    *,
    prompt: str,
    session_id: str | None = None,
) -> dict:
    if session_id is None:
        s = await store.create()
    else:
        s = await store.get(session_id)
        if s is None:
            return {"error": f"session {session_id!r} not found"}
    reply = await client.chat(hermes_session_id=s.hermes_session_id, prompt=prompt)
    await store.touch(s.id, increment_messages=True)
    updated = await store.get(s.id)
    return {
        "session_id": s.id,
        "reply": reply,
        "message_count": updated.message_count,
    }


async def tool_continue_session(
    store: SessionStore,
    client: HermesClient,
    *,
    session_id: str,
    prompt: str,
) -> dict:
    s = await store.get(session_id)
    if s is None:
        return {"error": f"session {session_id!r} not found"}
    reply = await client.chat(hermes_session_id=s.hermes_session_id, prompt=prompt)
    await store.touch(s.id, increment_messages=True)
    updated = await store.get(s.id)
    return {
        "session_id": s.id,
        "reply": reply,
        "message_count": updated.message_count,
    }


async def tool_list_sessions(
    store: SessionStore,
    client: HermesClient,  # noqa: ARG001
    *,
    limit: int = 50,
) -> dict:
    sessions = await store.list(limit=limit)
    return {"sessions": [_session_to_dict(s) for s in sessions]}


async def tool_summarize_session(
    store: SessionStore,
    client: HermesClient,
    *,
    session_id: str,
) -> dict:
    s = await store.get(session_id)
    if s is None:
        return {"error": f"session {session_id!r} not found"}
    summary = await client.chat(
        hermes_session_id=s.hermes_session_id, prompt=_SUMMARY_PROMPT
    )
    await store.set_summary(s.id, summary)
    # touch but don't count summary as a user message
    await store.touch(s.id, increment_messages=False)
    return {"session_id": s.id, "summary": summary}


async def tool_delete_session(
    store: SessionStore,
    client: HermesClient,  # noqa: ARG001
    *,
    session_id: str,
) -> dict:
    deleted = await store.delete(session_id)
    return {"deleted": deleted}
```

- [ ] **Step 4: Run tests, all green**

```bash
cd pkgs/hermes-mcp && python -m pytest tests/ -v 2>&1 | tail -25
```

- [ ] **Step 5: Commit**

```bash
git add pkgs/hermes-mcp/src/hermes_mcp/tools.py pkgs/hermes-mcp/tests/test_tools.py
git commit -m "feat(hermes-mcp): six MCP tool implementations with TDD"
```

---

## Task 6: MCP SSE server entrypoint

**Files:**
- Create: `pkgs/hermes-mcp/src/hermes_mcp/server.py`
- Modify: `pkgs/hermes-mcp/tests/test_tools.py` — no change; just make sure server imports compile

**What "done" means:** `result/bin/hermes-mcp` (built by Nix in Task 1) starts the SSE server on `127.0.0.1:9081` when env vars are set, and `curl -sI http://127.0.0.1:9081/sse` returns 200 with `Content-Type: text/event-stream`.

### Steps

**NOTE on step granularity:** Step 1 below produces ~150 lines of code in one commit. If you prefer tighter granularity, split it into four substeps: (1a) write the `_TOOL_SCHEMAS` and `_TOOL_HANDLERS` module-level dicts, (1b) write `build_app(cfg)` with the Server registration and SSE transport wiring, (1c) write `run()` + uvicorn glue, (1d) add `starlette`/`uvicorn`/`anyio` to `pyproject.toml` and `default.nix`. Each substep produces a valid syntactic state (the module compiles after each); the binary doesn't start the server until 1c lands.

- [ ] **Step 1: Write `server.py`** (or split into 1a-1d per the granularity note above)

The official `mcp` Python SDK provides `mcp.server.lowlevel.Server` + `mcp.server.sse.SseServerTransport` (verified against `python3.12-mcp-1.15.0` in /nix/store). The exact import surface depends on the installed version — verify against `python -c "import mcp; print(mcp.__version__); help(mcp.server)" | head -30` BEFORE writing this in case the version pinned by the build differs.

Skeleton:
```python
# src/hermes_mcp/server.py
"""SSE MCP server exposing the six hermes-mcp tools."""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import anyio
from mcp.server.lowlevel import Server
from mcp.server.sse import SseServerTransport
from mcp.types import TextContent, Tool
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.routing import Mount, Route
import uvicorn

from hermes_mcp import tools
from hermes_mcp.config import Config
from hermes_mcp.hermes_client import HermesClient
from hermes_mcp.session_store import SessionStore

logger = logging.getLogger("hermes_mcp")

# ---- Tool schemas (JSON Schema for MCP `tools/list`) ----
_TOOL_SCHEMAS: list[Tool] = [
    Tool(
        name="ask_hermes",
        description=(
            "Send a prompt to Hermes Agent. If session_id is omitted, a "
            "fresh session is created. Returns Hermes' reply."
        ),
        inputSchema={
            "type": "object",
            "required": ["prompt"],
            "properties": {
                "prompt": {"type": "string"},
                "session_id": {"type": "string"},
            },
        },
    ),
    Tool(
        name="start_session",
        description="Create a new named (or anonymous) Hermes conversation session.",
        inputSchema={
            "type": "object",
            "properties": {"name": {"type": "string"}},
        },
    ),
    Tool(
        name="continue_session",
        description="Send a follow-up prompt within an existing session.",
        inputSchema={
            "type": "object",
            "required": ["session_id", "prompt"],
            "properties": {
                "session_id": {"type": "string"},
                "prompt": {"type": "string"},
            },
        },
    ),
    Tool(
        name="list_sessions",
        description="List Hermes sessions, most-recently-used first.",
        inputSchema={
            "type": "object",
            "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 200}},
        },
    ),
    Tool(
        name="summarize_session",
        description="Ask Hermes to summarize a session; stores the summary.",
        inputSchema={
            "type": "object",
            "required": ["session_id"],
            "properties": {"session_id": {"type": "string"}},
        },
    ),
    Tool(
        name="delete_session",
        description="Delete a Hermes session from local bookkeeping.",
        inputSchema={
            "type": "object",
            "required": ["session_id"],
            "properties": {"session_id": {"type": "string"}},
        },
    ),
]

_TOOL_HANDLERS = {
    "ask_hermes": tools.tool_ask_hermes,
    "start_session": tools.tool_start_session,
    "continue_session": tools.tool_continue_session,
    "list_sessions": tools.tool_list_sessions,
    "summarize_session": tools.tool_summarize_session,
    "delete_session": tools.tool_delete_session,
}


def build_app(cfg: Config) -> Starlette:
    server: Server = Server("hermes-mcp")
    store = SessionStore(cfg.db_path)
    client = HermesClient(cfg)

    @server.list_tools()
    async def _list() -> list[Tool]:
        return _TOOL_SCHEMAS

    @server.call_tool()
    async def _call(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        handler = _TOOL_HANDLERS.get(name)
        if handler is None:
            return [TextContent(type="text", text=json.dumps({"error": f"unknown tool {name!r}"}))]
        try:
            result = await handler(store, client, **arguments)
        except Exception as exc:
            logger.exception("tool %s failed", name)
            return [TextContent(type="text", text=json.dumps({"error": str(exc)}))]
        return [TextContent(type="text", text=json.dumps(result))]

    sse = SseServerTransport("/messages/")

    async def handle_sse(request: Request) -> None:
        async with sse.connect_sse(request.scope, request.receive, request._send) as streams:
            await server.run(streams[0], streams[1], server.create_initialization_options())

    async def startup() -> None:
        await store.init()
        logger.info("hermes-mcp ready: db=%s upstream=%s", cfg.db_path, cfg.hermes_api_url)

    async def shutdown() -> None:
        await client.aclose()

    return Starlette(
        routes=[
            Route("/sse", endpoint=handle_sse),
            Mount("/messages/", app=sse.handle_post_message),
        ],
        on_startup=[startup],
        on_shutdown=[shutdown],
    )


def run() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    cfg = Config.from_env()
    app = build_app(cfg)
    uvicorn.run(app, host=cfg.sse_host, port=cfg.sse_port, log_level="info")
    return 0
```

⚠️ **Subagent must verify the MCP SDK imports** before writing this block. If the install pulled a different layout, adjust accordingly and document the version in a comment.

- [ ] **Step 2: Update `pkgs/hermes-mcp/pyproject.toml`**

Add `starlette`, `uvicorn`, `anyio` to runtime deps. Adjust `default.nix` `dependencies` to include `starlette`, `uvicorn`, `anyio` from `python312Packages`.

- [ ] **Step 3: Rebuild `nix build .#hermes-mcp`**

Expected: builds clean. Unit tests (which don't touch server.py) still pass via the package's `pytestFlagsArray`.

- [ ] **Step 4: Smoke-start the server locally**

```bash
env \
  HERMES_API_URL=http://127.0.0.1:9999 \
  HERMES_API_KEY=fakekey \
  HERMES_MCP_DB_PATH=/tmp/test-sessions.db \
  HERMES_MCP_HOST=127.0.0.1 \
  HERMES_MCP_PORT=9081 \
  ./result/bin/hermes-mcp &
SERVER_PID=$!
sleep 2
curl -sI http://127.0.0.1:9081/sse | head -5
kill $SERVER_PID
rm -f /tmp/test-sessions.db
```

Expected: `HTTP/1.1 200 OK` and `content-type: text/event-stream`.

- [ ] **Step 5: Commit**

```bash
git add pkgs/hermes-mcp/src/hermes_mcp/server.py pkgs/hermes-mcp/pyproject.toml pkgs/hermes-mcp/default.nix
git commit -m "feat(hermes-mcp): SSE MCP server with six tool routes"
```

---

## Task 7: NixOS module — systemd, nginx vhost, cert, tmpfiles

**Files:**
- Create: `modules/services/hermes-mcp.nix`
- Modify: `hosts/vulcan/default.nix` (one import line)
- Modify: `secrets/secrets.yaml` via `sops` (user drives) — add a `hermes-mcp/env` block: `HERMES_API_KEY=<same as API_SERVER_KEY from Task 2>`. The user pastes the same hex; no decryption needed by Claude.
- Cert issuance: invoke `/etc/nixos/certs/renew-certificate.sh "hermes-mcp.vulcan.lan" -o /var/lib/nginx-certs/ -d 365 --owner nginx:nginx` (script handles SOPS internally; matches the existing pattern). Run this OUTSIDE the rebuild, BEFORE the first switch.

**What "done" means:** `systemctl status hermes-mcp.service` is `active (running)`, `curl -sI https://hermes-mcp.vulcan.lan/sse` returns 200 with `text/event-stream` (run from the host).

### Steps

- [ ] **Step 1: Ask the user to add the sops secret + mint the cert**

Two user-driven steps (Claude does NOT decrypt):
1. `sudo sops /etc/nixos/secrets/secrets.yaml` → add `hermes-mcp: { env: "HERMES_API_KEY=<same hex>" }`.
2. `sudo /etc/nixos/certs/renew-certificate.sh "hermes-mcp.vulcan.lan" -o /var/lib/nginx-certs/ -d 365 --owner nginx:nginx`.

Wait for explicit confirmation.

- [ ] **Step 2: Write `modules/services/hermes-mcp.nix`**

```nix
# Host-side MCP bridge from OpenClaw → Hermes Agent.
# Imported by hosts/vulcan/default.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  port = 9081;
in
{
  # ---- Service user (mirrors openclaw/hermes pattern) ----
  users.users.hermes-mcp = {
    isSystemUser = true;
    group = "hermes-mcp";
    home = "/var/lib/hermes-mcp";
    description = "hermes-mcp MCP bridge runtime user";
  };
  users.groups.hermes-mcp = { };

  # ---- Persistent state dir ----
  # `d` directive — preserves contents (CLAUDE.md rule).
  systemd.tmpfiles.rules = [
    "d /var/lib/hermes-mcp 0750 hermes-mcp hermes-mcp -"
  ];

  # ---- SOPS secret ----
  sops.secrets."hermes-mcp/env" = {
    mode = "0640";
    owner = "hermes-mcp";
    group = "hermes-mcp";
    restartUnits = [ "hermes-mcp.service" ];
  };

  # ---- systemd service ----
  systemd.services.hermes-mcp = {
    description = "MCP bridge from OpenClaw to Hermes Agent";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "microvm@hermes.service"
      "sops-nix.service"
    ];
    wants = [ "network-online.target" ];

    environment = {
      HERMES_API_URL = "http://10.99.1.2:8080";
      HERMES_MCP_DB_PATH = "/var/lib/hermes-mcp/sessions.db";
      HERMES_MCP_HOST = "127.0.0.1";
      HERMES_MCP_PORT = toString port;
      HERMES_MCP_MODEL = "hera/omlx/Qwen3.6-27B-MLX-8bit";
    };
    serviceConfig = {
      Type = "simple";
      User = "hermes-mcp";
      Group = "hermes-mcp";
      EnvironmentFile = config.sops.secrets."hermes-mcp/env".path;
      ExecStart = "${pkgs.hermes-mcp}/bin/hermes-mcp";
      Restart = "on-failure";
      RestartSec = "5s";
      # Hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/hermes-mcp" ];
      StateDirectory = "hermes-mcp";
      AmbientCapabilities = "";
      CapabilityBoundingSet = "";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  # ---- nginx reverse proxy with Vulcan CA cert ----
  # Mirrors modules/services/openclaw-microvm.nix:775-803 (drafts-mcp).
  services.nginx.virtualHosts."hermes-mcp.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/hermes-mcp.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/hermes-mcp.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}/";
      extraConfig = ''
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "keep-alive";
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 2h;
        proxy_connect_timeout 60s;
        proxy_send_timeout 2h;
      '';
    };
  };
}
```

- [ ] **Step 3: Wire into the host config**

In `hosts/vulcan/default.nix`, add to the `imports` list:
```nix
./modules/services/hermes-mcp.nix
```

- [ ] **Step 4: Rebuild and verify**

Ask user to authorize rebuild:
```bash
touch /etc/nixos/.nixos-build
sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tail -15
rm -f /etc/nixos/.nixos-build
```

Then:
```bash
systemctl status hermes-mcp.service --no-pager | head -10
curl -sS -I https://hermes-mcp.vulcan.lan/sse 2>&1 | head -5
```

Expected: service `active (running)`, curl returns 200 + `content-type: text/event-stream`.

- [ ] **Step 5: Commit**

```bash
git add modules/services/hermes-mcp.nix hosts/vulcan/default.nix
git commit -m "feat(hermes-mcp): NixOS module with systemd + nginx vhost"
```

---

## Task 8: Wire OpenClaw to discover the new MCP server

**Files:**
- Modify: `modules/services/openclaw-vm.nix` — add a new `apply_mcporter_jq` block

**What "done" means:** Inside the OpenClaw VM, `cat /var/lib/openclaw/.mcporter/mcporter.json | jq '.mcpServers.hermes'` shows the URL entry.

### Steps

- [ ] **Step 1: Add the jq block**

Locate the chain of `apply_mcporter_jq` calls (around `modules/services/openclaw-vm.nix:816-926`). Add a new block AFTER the `vane` block but BEFORE the final write-out:

```nix
# ---- Hermes Agent MCP bridge (added by 2026-05-12-openclaw-hermes-mcp-bridge plan) ----
# Routes OpenClaw → https://hermes-mcp.vulcan.lan/sse → host hermes-mcp service →
# http://10.99.1.2:8080 (Hermes VM api_server platform).
apply_mcporter_jq '
  .mcpServers["hermes"] = {
    "type": "sse",
    "url": "https://hermes-mcp.vulcan.lan/sse",
    "description": "Hermes Agent (NousResearch) — deep-thinker back end. Tools: ask_hermes, start_session, continue_session, list_sessions, summarize_session, delete_session."
  }
'
```

- [ ] **Step 2: Ensure `hermes-mcp.vulcan.lan` is reachable from inside the OpenClaw VM**

Confirm the host already resolves and DNATs that hostname for the OpenClaw bridge. The existing pattern from `modules/services/openclaw-vm.nix:431` proves drafts-mcp works the same way via port-443 DNAT — `hermes-mcp.vulcan.lan` should resolve via the same Technitium DNS and DNAT chain, so no additional firewall changes are needed.

Verify by sending OpenClaw VM a curl probe (via its own SSH key if available, otherwise via a one-shot diagnostic service — but typically the existing 443 DNAT for `*.vulcan.lan` covers this implicitly).

- [ ] **Step 3: Rebuild**

```bash
touch /etc/nixos/.nixos-build
sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tail -10
rm -f /etc/nixos/.nixos-build
```

- [ ] **Step 4: Verify openclaw sees the hermes MCP server**

```bash
sudo ssh -i /root/.ssh/openclaw-debug openclaw@10.99.0.2 \
  'cat /var/lib/openclaw/.mcporter/mcporter.json | jq ".mcpServers.hermes"' 2>&1
```

(Adjust SSH key path to whatever OpenClaw's debug key path is; if absent, exec via the openclaw VM's existing systemd-managed mcporter init script.)

Expected: a JSON object with `type: "sse"` and `url: "https://hermes-mcp.vulcan.lan/sse"`.

- [ ] **Step 5: Commit**

```bash
git add modules/services/openclaw-vm.nix
git commit -m "feat(openclaw): wire hermes-mcp MCP server to mcporter config"
```

---

## Task 9: End-to-end smoke test

**Files:**
- Create: `docs/openclaw-hermes-integration.md`

**What "done" means:** Running an `ask_hermes` call from OpenClaw reaches Hermes and returns a sensible reply.

### Steps

- [ ] **Step 1: From the host, hand-roll an MCP `tools/call` over the SSE endpoint**

Use the **`hermes-mcp` package's own Python env** (it has the `mcp` SDK as a runtime dep, so re-use it — avoids drift across nix-store rebuilds). Resolve the package path via `nix path-info`:

```bash
HM_PY=$(nix path-info .#hermes-mcp.dependencies.python)/bin/python3
# Fallback if the attribute path differs in your nix version:
[ -x "$HM_PY" ] || HM_PY=$(readlink -f $(which hermes-mcp) | sed 's|/bin/.*||')/lib/python*/site-packages
[ -x "$HM_PY" ] || HM_PY=$(nix shell .#hermes-mcp -c sh -c 'command -v python3')

sudo runuser -u hermes-mcp -- "$HM_PY" -c '
import asyncio, json
from mcp.client.sse import sse_client
from mcp.client.session import ClientSession

async def main():
    async with sse_client("https://hermes-mcp.vulcan.lan/sse") as (read, write):
        async with ClientSession(read, write) as s:
            await s.initialize()
            tools = await s.list_tools()
            print("TOOLS:", [t.name for t in tools.tools])
            result = await s.call_tool("ask_hermes", {"prompt":"Reply with the single word OK."})
            print("REPLY:", result.content[0].text[:200])

asyncio.run(main())
'
```

Expected: `TOOLS: ['ask_hermes', 'start_session', ...]` then a JSON blob with `reply` containing roughly `"OK"`.

If the python resolution above doesn't work cleanly, the simplest alternative is `nix shell .#hermes-mcp -c hermes-mcp-test-client …` — write a one-liner test client into `pkgs/hermes-mcp/scripts/test_client.py` and add it to the package's `scripts` table in `pyproject.toml`. The assertion is about the network path, not the toolchain delivery.

- [ ] **Step 2: From OpenClaw, ask it to use the hermes tool**

Trigger an OpenClaw conversation (via the channel the user uses for OpenClaw). Ask: *"Use the hermes MCP server's ask_hermes tool to ask Hermes what 2+2 is, then report the result."* Wait for the reply.

If the question goes through, write down the round-trip time and any errors.

- [ ] **Step 3: Write `docs/openclaw-hermes-integration.md`**

```markdown
# OpenClaw ↔ Hermes Integration Operations

## Overview

OpenClaw can call Hermes Agent as a multi-tool MCP server via
`https://hermes-mcp.vulcan.lan/sse`. The chain:

```
OpenClaw VM ─SSE→ nginx :443 ─→ hermes-mcp.service :9081 (host) ─HTTP→ Hermes VM :8080
```

## Tools exposed

| Tool | Purpose |
|---|---|
| `ask_hermes(prompt, session_id?)` | One-shot ask, auto-creates session if none |
| `start_session(name?)` | Create a named (or anonymous) session |
| `continue_session(session_id, prompt)` | Follow-up within a session |
| `list_sessions(limit=50)` | Most-recent-first index of sessions |
| `summarize_session(session_id)` | Ask Hermes to summarize; stores the summary |
| `delete_session(session_id)` | Remove local session bookkeeping |

## Operator runbook

- **Service status:** `systemctl status hermes-mcp.service`
- **Logs:** `journalctl -u hermes-mcp.service -f`
- **Session DB:** `sqlite3 /var/lib/hermes-mcp/sessions.db 'SELECT * FROM sessions ORDER BY last_used_at DESC LIMIT 20;'`
- **Rotate API key:** edit `hermes-mcp/env` (host) AND `hermes/env` (VM) in sops; restart both services.
- **Health probe:** `curl -sI https://hermes-mcp.vulcan.lan/sse` returns 200 + `text/event-stream`.

## Known limitations

- Sync responses only (no streaming through MCP).
- Hermes' server-side session bookkeeping is NOT cleaned up on `delete_session`; we delete only our local row. Hermes' own session pruner handles cleanup.
- One shared API key for all OpenClaw → Hermes traffic — no per-conversation isolation today.

## Where to make changes

- Plan: `/etc/nixos/docs/superpowers/plans/2026-05-12-openclaw-hermes-mcp-bridge.md`
- Code: `/etc/nixos/pkgs/hermes-mcp/`
- Module: `/etc/nixos/modules/services/hermes-mcp.nix`
- OpenClaw entry: `/etc/nixos/modules/services/openclaw-vm.nix` (search "mcpServers\[\"hermes\"\]")
- Hermes-VM port: `/etc/nixos/modules/services/hermes-vm.nix` (search "api_server")
```

- [ ] **Step 4: Commit + final sign-off**

```bash
git add docs/openclaw-hermes-integration.md
git commit -m "docs(hermes-mcp): operator runbook for OpenClaw↔Hermes integration"
```

Dispatch a final `superpowers:code-reviewer` agent over the whole feature branch's git diff for one round of cross-task review.

---

## Acceptance Criteria

All must be true:

1. `nix build .#hermes-mcp` succeeds.
2. All unit tests pass: `pytest pkgs/hermes-mcp/tests/ -v` shows 0 failures.
3. `systemctl is-active hermes-mcp.service` returns `active`.
4. `curl -sI https://hermes-mcp.vulcan.lan/sse` returns 200 + `text/event-stream`.
5. From OpenClaw's mcporter config: `mcpServers.hermes.url == "https://hermes-mcp.vulcan.lan/sse"`.
6. A direct MCP-client call (Task 9 Step 1) round-trips through to Hermes and returns a reply.
7. `docs/openclaw-hermes-integration.md` exists and documents the runbook.
8. No regressions in existing services: `systemctl --failed` is empty; `hermes-agent` still responds to Discord; OpenClaw still answers its own channels.

## Memory update on success

After the final commit, save/update the `project_hermes_agent.md` memory with:
- The new `hermes-mcp` service info (host service, port 9081, SQLite at `/var/lib/hermes-mcp/sessions.db`)
- The new VM port (8080) and the rationale for `gateway.platforms = [ "discord" "api_server" ]`
- That OpenClaw now sees Hermes as `mcpServers.hermes`
