# Task: Add Sherlock Database Tool to OpenClaw on Vulcan

## Context

I want to give my OpenClaw AI gateway the ability to query my `org` PostgreSQL database using the Sherlock tool. Sherlock is a read-only database query CLI that translates natural language into SQL. It's already working on my macOS machines (hera, clio) via `overlays/30-sherlock-db.nix` in my nix-config repo.

The implementation has several challenges that you'll need to solve together. Read this entire prompt before starting.

## Current Architecture

### OpenClaw on Vulcan

OpenClaw runs inside a **microVM** (not directly on the host). The relevant files:

- **`/etc/nixos/modules/services/openclaw-microvm.nix`** — Host-side config: defines the microVM, networking, secrets staging, nginx proxy. This is the file that defines `dnatPorts`, the bridge network, and virtiofs mounts.
- **`/etc/nixos/modules/services/openclaw-vm.nix`** — Guest-side NixOS config: what runs inside the VM.
- **`/etc/nixos/overlays/default.nix`** — Vulcan's overlay file, selectively imports from nix-config.
- **`/etc/nixos/modules/services/databases.nix`** — PostgreSQL configuration with pg_hba.conf rules.

The microVM architecture:
- Guest VM is on bridge network `10.99.0.2/30`, host bridge at `10.99.0.1/30`
- Guest accesses host loopback services via two-stage DNAT (guest rewrites 127.0.0.1:PORT to 10.99.0.1:PORT, host PREROUTING rewrites that to 127.0.0.1:PORT)
- The `dnatPorts` list in `openclaw-microvm.nix` controls which host ports are reachable from the VM
- **Port 5432 (PostgreSQL) is NOT currently in `dnatPorts`** — this must be added
- State directory `/var/lib/openclaw` is shared via virtiofs
- Secrets are staged to `/var/lib/microvms/openclaw/secrets/` on host, mounted at `/run/openclaw-secrets/` in the guest

OpenClaw has these tool capabilities:
- `tools.exec.security = "full"` and `tools.exec.ask = "off"` — can execute shell commands freely
- MCP servers configured via mcporter at `/var/lib/openclaw/.openclaw/.mcporter/mcporter.json`
- Plugins system for memory, messaging, etc.
- ACP backend connects to Claude Code

### Sherlock Tool

Sherlock (https://github.com/michaelbromley/sherlock) is a TypeScript CLI tool compiled with Bun. Key facts:

- **Build system**: `bun build ./src/query-db.ts --compile --target=bun-linux-arm64` (this target exists in Bun but the project doesn't build it in CI)
- **Pre-built binaries**: Only `darwin-arm64` and `linux-x64` are released. **There is no `aarch64-linux` binary.** Vulcan is `aarch64-linux`.
- **Dependencies**: `commander`, `@clack/prompts`, `@napi-rs/keyring` (native keyring), `mssql`
- **Config**: `~/.config/sherlock/config.json` with connection definitions
- **Credential storage**: Uses `@napi-rs/keyring` on macOS (Keychain). On headless Linux in a VM, there is no system secret service, so credentials must be stored differently (plain text in config or environment variable).

### The `org` Database

PostgreSQL on vulcan (port 5432) has an `org` database containing Org-mode data:
- 14 tables: `files`, `entries`, `entry_tags`, `entry_stamps`, `entry_log_entries`, `entry_properties`, `entry_links`, `entry_embeddings`, `entry_body_blocks`, `entry_categories`, `entry_relationships`, `entry_body_blocks`, `log_entry_body_blocks`, `schema_version`
- ~72K entries, ~384K body blocks, ~378K properties, ~281K embeddings
- Timestamps use Modified Julian Day integers (today 2026-04-10 = MJD 61140). Convert with: `DATE '1858-11-17' + day`
- The `entries` table has a `tsv` column (tsvector) for full-text search
- The `entry_embeddings` table has a `embedding` column (pgvector) for semantic search

PostgreSQL auth rules (from `databases.nix`):
- Localhost (127.0.0.1): `scram-sha-256` (password required)
- 192.168.0.0/16: `hostssl` with `scram-sha-256` (SSL + password required)
- **The 10.99.0.0/30 bridge network has NO auth rule** — connections would be rejected

### What's Already on Hera (nix-config)

The existing overlay at `nix-config/overlays/30-sherlock-db.nix`:
- Downloads pre-built binaries for `aarch64-darwin` and `x86_64-linux`
- Embeds a `SKILL.md` into the derivation (Claude Code skill definition)
- The SKILL.md includes an SSL+Keychain workaround section for when `-c` fails
- Installed into user profile as `sherlock` and skill at `~/.claude/skills/sherlock/`

## What Needs to Be Done

### 1. Build Sherlock for aarch64-linux

Since no pre-built binary exists, you need to build from source. Two approaches:

**Option A (preferred): Bun cross-compile in a Nix derivation**
- Clone the sherlock repo
- Use `bun build ./src/query-db.ts --compile --target=bun-linux-arm64` to produce a native binary
- The `@napi-rs/keyring` native dependency may need special handling (it provides macOS Keychain, Windows Credential Vault, and Linux Secret Service bindings). Since we won't use keyring in the VM, it might need to be stubbed or the build may need `--external @napi-rs/keyring`.

**Option B: Run directly with Bun**
- Package Bun for the VM and run `bun run /path/to/query-db.ts` as a script
- Simpler but adds Bun as a runtime dependency

Whichever approach you choose, add the aarch64-linux target to the overlay. You can either:
- Modify `nix-config/overlays/30-sherlock-db.nix` to add an `aarch64-linux` source (if building from source in the overlay)
- Or create a new overlay on vulcan at `/etc/nixos/overlays/` and import the sherlock package from there

### 2. Network: Add PostgreSQL Access from the MicroVM

In `/etc/nixos/modules/services/openclaw-microvm.nix`:
- Add `5432` to the `dnatPorts` list

In `/etc/nixos/modules/services/databases.nix`, add a pg_hba.conf rule for the bridge network:
```
# OpenClaw microVM bridge network
host    org       openclaw   10.99.0.0/30    scram-sha-256
```
Or, if you want broader access:
```
host    all       all        10.99.0.0/30    scram-sha-256
```

Note: After DNAT, PostgreSQL may see the source as 10.99.0.2 (VM) or 127.0.0.1 (post-DNAT). Test both to determine which pg_hba.conf rule matches. The localhost scram-sha-256 rule already exists and may suffice if DNAT fully rewrites the source.

### 3. Credentials: PostgreSQL Password for OpenClaw

Create a dedicated PostgreSQL user for OpenClaw (or reuse an existing one):
- Add a SOPS secret for the database password: `sops /etc/nixos/secrets.yaml` → add `openclaw/org-db-password`
- Stage it in `openclaw-prepare-secrets` service to `/var/lib/microvms/openclaw/secrets/org-db-password`
- The sherlock config inside the VM should reference this password file

**Important: No SSL workaround needed.** On hera/clio (macOS), the sherlock SKILL.md includes a workaround for SSL connections using `security find-generic-password` to pull passwords from macOS Keychain and construct a `-u` URL with `?sslmode=require`. None of that applies here:
- The VM connects to PostgreSQL via localhost DNAT, which uses plain `scram-sha-256` (no SSL)
- There is no macOS Keychain in the Linux VM
- Sherlock's `-c org` named connection will work directly with a password in the config file
- The SKILL.md for this deployment should NOT include the SSL/Keychain workaround section

For the sherlock config (`/var/lib/openclaw/.openclaw/.config/sherlock/config.json`):
```json
{
  "version": "2.0",
  "connections": {
    "org": {
      "type": "postgres",
      "host": "127.0.0.1",
      "port": 5432,
      "database": "org",
      "username": "openclaw",
      "password": "<read from staged secret>"
    }
  }
}
```

Since the VM connects via localhost DNAT (not over the network), SSL is not required — the 127.0.0.1 pg_hba.conf rule uses plain `scram-sha-256`.

### 4. OpenClaw Integration

The simplest approach: add sherlock to the VM's PATH and let OpenClaw's exec tool run it. In the guest VM config (`openclaw-vm.nix`), add the sherlock package to the OpenClaw service's `path`.

Then add instructions to OpenClaw's system prompt or agent config so it knows how to use sherlock. OpenClaw's agent config is in `/var/lib/openclaw/.openclaw/openclaw.json` under `agents.defaults`. You could:

- Add a `systemPrompt` field with sherlock usage instructions
- Or configure sherlock as an MCP server in mcporter (if sherlock supports MCP — it currently doesn't, so the CLI approach is simpler)

The key instructions the agent needs:
1. Use `sherlock -c org query "SQL..." -f markdown` for queries
2. The `org` database contains Org-mode data
3. Timestamps are MJD integers — convert with `DATE '1858-11-17' + day`
4. Use `sherlock -c org introspect` to learn the schema
5. Always use LIMIT to avoid large result sets

### 5. Ensure the `org` Database and User Exist

The `org` database is already created by the org-jw system. Verify:
- The database `org` exists in PostgreSQL
- Create a PostgreSQL role for openclaw: `CREATE ROLE openclaw WITH LOGIN PASSWORD '...';`
- Grant read access: `GRANT CONNECT ON DATABASE org TO openclaw; GRANT USAGE ON SCHEMA public TO openclaw; GRANT SELECT ON ALL TABLES IN SCHEMA public TO openclaw; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO openclaw;`
- This can be done via the `mkPostgresUserSetup` helper already used in `databases.nix`

## Security Considerations

- The openclaw user should have **read-only** access to the `org` database (SELECT only)
- Sherlock enforces read-only at the application level (only allows SELECT/SHOW/DESCRIBE/EXPLAIN/WITH)
- The database password should come from SOPS secrets, never hardcoded in Nix
- The VM's filesystem isolation ensures sherlock can only access the OpenClaw state directory

## Testing Plan

1. Build the system: `sudo nixos-rebuild build --flake '.#vulcan'`
2. Switch: `sudo nixos-rebuild switch --flake '.#vulcan'`
3. Verify PostgreSQL connectivity from the VM:
   ```bash
   sudo microvm -c openclaw
   # Inside VM:
   sherlock -c org tables
   ```
4. Test a query:
   ```bash
   sherlock -c org query "SELECT count(*) FROM entries" -f markdown
   ```
5. Test via OpenClaw: send a message asking "How many TODO items do I have?" and verify it uses sherlock to query the database.

## Files to Modify

| File | Change |
|------|--------|
| `/etc/nixos/overlays/default.nix` | Import sherlock package (from nix-config or new local overlay) |
| `/etc/nixos/modules/services/openclaw-microvm.nix` | Add 5432 to `dnatPorts` |
| `/etc/nixos/modules/services/openclaw-vm.nix` | Add sherlock to service PATH, set up config |
| `/etc/nixos/modules/services/databases.nix` | Add pg_hba.conf rule for bridge network; add openclaw user/grants |
| `/etc/nixos/secrets.yaml` | Add `openclaw/org-db-password` secret |

Optionally:
| `/etc/nixos/overlays/sherlock.nix` | New overlay if building sherlock from source locally |
| `nix-config/overlays/30-sherlock-db.nix` | Add `aarch64-linux` build target (if building from source in shared overlay) |
