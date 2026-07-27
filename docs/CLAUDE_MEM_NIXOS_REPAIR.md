# claude-mem Repair on NixOS (2026-05-27)

> **Archival — 2026-05-27.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.

Diagnosis and repair of claude-mem's semantic-search backend on **vulcan**, plus
guidance for deciding whether the same fixes are needed on your **other machines**.

---

## TL;DR

claude-mem's background worker runs as a **systemd *user* service**. On NixOS,
systemd user services start with a stripped environment that does **not** inherit
your login shell. That broke the worker two independent ways:

| # | Missing env var | Consequence | NixOS-specific? |
|---|-----------------|-------------|-----------------|
| 1 | `PATH` | Worker can't find `uvx` (→ launches `chroma-mcp` for vector search) or the `claude` CLI (→ observation generator) | Partly — see portability |
| 2 | `LD_LIBRARY_PATH` | `chroma-mcp`'s prebuilt manylinux wheels (numpy/chromadb) can't `dlopen` `libstdc++.so.6` / `libz.so.1` | **Yes — NixOS only** |

Both are fixed with a single systemd drop-in. A **third, still-open** issue
affects the *generator* only (see §6).

The SQLite store and the `$CMEM` session-start digest never broke (they don't
shell out to `uvx`/`claude`), which is why the failure was silent: memory kept
recording, but `search` / `timeline` / `get_observations` returned HTTP 500.

---

## 1. Symptom

`search` / `timeline` / `get_observations` MCP tools failed:

```
Error calling Worker API: Worker API error (500): {"error":"Executable not found in $PATH: \"uvx\""}
Error calling Worker API: Worker API error (500): {"error":"chroma-mcp connection in backoff (10s remaining)"}
```

The worker daemon had been up ~6 days (since the 2026-05-21 reboot), stuck the
whole time.

---

## 2. Architecture (how the pieces fit)

```
Claude Code session
   └─ MCP server (node mcp-server.cjs)         ← per-session
        └─ HTTP → worker daemon on 127.0.0.1:37777
             (bun worker-service.cjs --daemon)  ← persistent, ONE per user
                ├─ SQLite: ~/.claude-mem/claude-mem.db        (prompts/sessions — always worked)
                ├─ vector search: spawns `uvx --python 3.13 chroma-mcp ... --data-dir ~/.claude-mem/chroma`
                └─ generator: spawns the `claude` CLI to summarise sessions into observations
```

The persistent worker is started by the systemd **user** unit
`~/.config/systemd/user/claude-mem-worker.service` (installed by the plugin, not
by NixOS):

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=%h/.local/bin/claude-mem-worker      # forks + detaches the bun daemon
ExecStop=... pkill -f "bun.*worker-service.cjs --daemon"
Environment=CLAUDE_MEM_PORT=37777              # <-- the ONLY env it sets
```

Note `Type=oneshot` + a forking launcher ⇒ the unit sits in `activating` forever
and `systemctl --user restart` **blocks ~90 s** on the start-job timeout even
though the daemon itself respawns in seconds. This is cosmetic; don't mistake it
for a hang.

---

## 3. Root cause

The running daemon's environment (read from `/proc/<pid>/environ`) was:

```
PATH=/run/current-system/sw/bin:/run/wrappers/bin      # bare NixOS system PATH
# LD_LIBRARY_PATH: unset
```

- `uvx`/`uv` live in `/etc/profiles/per-user/johnw/bin` (per-user Nix profile) → **not on that PATH**.
- the `claude` CLI is `/home/johnw/src/scripts/claude` → **not on that PATH**.
- Once PATH was fixed, `chroma-mcp` started but crashed instantly:

  ```
  ImportError: libstdc++.so.6: cannot open shared object file: No such file or directory
  ... (after adding gcc-lib) ...
  Original error was: libz.so.1: cannot open shared object file
  ```

  i.e. the uv-downloaded standalone CPython + manylinux wheels assume an FHS
  layout (`/usr/lib/libstdc++.so.6`) that NixOS does not provide.

**Why it started failing on 2026-05-21:** before that reboot the worker was most
likely spawned directly by Claude Code, inheriting your interactive shell PATH.
After the reboot it came up via the systemd user unit with the stripped env and
stayed broken.

---

## 4. The fix applied

### 4a. systemd drop-in (fixes PATH **and** the native-lib loading)

`~/.config/systemd/user/claude-mem-worker.service.d/override.conf`:

```ini
[Service]
Environment=PATH=/etc/profiles/per-user/johnw/bin:/run/current-system/sw/bin:/run/wrappers/bin:/home/johnw/src/scripts
Environment=LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib
```

- `LD_LIBRARY_PATH` points at **nix-ld**'s curated library set
  (`= $NIX_LD_LIBRARY_PATH`). `programs.nix-ld` is enabled system-wide on vulcan,
  and that set already contains `libstdc++` + `libz` (verified: `import chromadb`
  → OK). The `/run/current-system/...` path is stable across rebuilds.
- A drop-in (not editing the unit directly) survives plugin updates.

### 4b. settings.json (helps the generator find `claude`)

Set in `~/.claude-mem/settings.json` (was `""`):

```json
"CLAUDE_CODE_PATH": "/home/johnw/src/scripts/claude"
```

A timestamped backup `~/.claude-mem/settings.json.bak.<epoch>` was made first.
The edit was done with `jq` to a temp file in the same dir (never printing the
file, since it can hold API keys).

### 4c. reload + restart

```bash
systemctl --user daemon-reload
systemctl --user restart claude-mem-worker.service   # blocks ~90s; daemon respawns in seconds
```

---

## 5. Verification

```bash
# new daemon carries both vars:
tr '\0' '\n' < /proc/$(pgrep -f 'bun.*worker-service.cjs --daemon'|head -1)/environ \
  | grep -E '^(PATH|LD_LIBRARY_PATH)='
# → PATH=/etc/profiles/per-user/johnw/bin:...:/home/johnw/src/scripts
# → LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib

# import smoke test:
LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib \
  uv run --python 3.13 --with chromadb python -c "import chromadb; print('OK')"   # → OK
```

The `search` MCP tool now returns results. **Caveat:** the *first* call after a
restart can hit `Request timed out after 3000ms` while `chroma-mcp` cold-starts
(loads the persistent DB + embedding model); just retry — it's warm afterward.

---

## 6. Still open: the observation generator (`Preflight` JSON error)

After PATH was fixed, the generator finds `claude` but fails:

```
Generator failed {provider=claude, error=JSON Parse error: Unexpected identifier "Preflight"}
```

claude-mem runs the `claude` CLI expecting clean JSON on stdout, but the wrapper
at `/home/johnw/src/scripts/claude` (or the CLI it invokes) prints a `Preflight`
line to **stdout**, corrupting the parse. (`Preflight` is not a literal string in
the wrapper, so it comes from what the wrapper executes.)

This breaks **creation of new observations**, not search. Fix direction (not yet
applied):
- point `CLAUDE_CODE_PATH` at the real `claude` binary, bypassing the wrapper, **or**
- make the wrapper emit its preflight/diagnostic output to **stderr**, not stdout, **or**
- switch `CLAUDE_MEM_PROVIDER` to a non-CLI provider.

---

## 7. Will the other machines need this? — decision guide

Run these on each machine where you use claude-mem:

```bash
# (a) Is the worker a systemd USER service? (PATH risk applies if yes)
systemctl --user status claude-mem-worker.service 2>/dev/null | head -3

# (b) Is this NixOS? (native-lib / LD_LIBRARY_PATH fix applies only if yes)
test -e /etc/NIXOS && echo "NixOS" || echo "not NixOS"

# (c) What env does the running worker actually have? (Linux)
tr '\0' '\n' < /proc/$(pgrep -f 'bun.*worker-service.cjs --daemon'|head -1)/environ \
  | grep -E '^(PATH|LD_LIBRARY_PATH)='
#    macOS equivalent: ps -E -p <pid>  (or `launchctl print`)

# (d) Functional probe: run any claude-mem `search`; map the error:
#     "Executable not found in $PATH: uvx"      -> needs the PATH fix (§4a PATH line)
#     "MCP error -32000: Connection closed"      -> needs the LD_LIBRARY_PATH fix (NixOS, §4a)
#        (confirm via worker log: ImportError: libstdc++.so.6 ...)
#     "Request timed out after 3000ms" (1st only) -> cold start, just retry
#     'JSON Parse error: ... "Preflight"'         -> generator/wrapper issue (§6)
```

Interpretation:

| Machine type | PATH fix (§4a PATH) | LD_LIBRARY_PATH fix (§4a) | Generator/Preflight (§6) |
|---|---|---|---|
| **NixOS**, worker = systemd user service | **Yes** | **Yes** | Only if it uses the same `claude` wrapper |
| **NixOS**, worker spawned by Claude Code with full shell PATH | Maybe not (check (c)) | **Yes** (the lib problem is independent of how it's launched) | as above |
| **Ubuntu / Debian / Fedora / Arch** | Usually no (system `uvx` on PATH; check (c)) | **No** (`libstdc++`/`libz` at standard FHS paths) | as above |
| **macOS** | Usually no (Homebrew/uv on PATH) | **No** (dylibs resolve normally) | as above |

**Rule of thumb:** the `LD_LIBRARY_PATH`/nix-ld fix is needed **iff the machine is
NixOS**. The `PATH` fix is needed **iff the worker runs from a context that lacks
your per-user profile** (true for NixOS systemd user services; usually false
elsewhere — but verify with probe (c)). The generator fix is needed **iff
`CLAUDE_CODE_PATH` points at a wrapper that writes non-JSON to stdout**.

Prerequisite for the NixOS fix: `programs.nix-ld.enable = true;` with `libstdc++`
+ `zlib` in its library set. If a NixOS machine lacks nix-ld, either enable it or
set `LD_LIBRARY_PATH` to an explicit lib list, e.g.
`${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.zlib}/lib`.

---

## 8. Making it reproducible / declarative (recommended for multi-machine)

The hand-written drop-in works but lives outside your Nix config. To manage it
declaratively (and identically across machines), add a drop-in via home-manager:

```nix
# home-manager
xdg.configFile."systemd/user/claude-mem-worker.service.d/override.conf".text = ''
  [Service]
  Environment=PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/run/wrappers/bin:${config.home.homeDirectory}/src/scripts
  Environment=LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib
'';
```

(Do **not** declare `systemd.user.services.claude-mem-worker` itself — the plugin
owns that unit; only add the drop-in.) Gate the whole block on
`pkgs.stdenv.isLinux` / a NixOS check so it's a no-op on macOS.

---

## 9. Rollback

```bash
rm ~/.config/systemd/user/claude-mem-worker.service.d/override.conf
cp ~/.claude-mem/settings.json.bak.<epoch> ~/.claude-mem/settings.json   # restores CLAUDE_CODE_PATH=""
systemctl --user daemon-reload
systemctl --user restart claude-mem-worker.service
```
