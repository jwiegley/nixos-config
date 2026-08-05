# CLAUDE.md

Guidance for Claude Code when working with this NixOS repository.

## ⚠️ CRITICAL SAFETY RULES ⚠️

### 🛑 PRIMARY LENS — APPLY THIS BEFORE EVERY OPERATION

**Security is the FIRST filter on every action. Not a backstop. Not a final check. The FIRST filter.**

You have a recurring failure mode: tunnel-visioning on a diagnostic or implementation
task and treating the rules below as a passive constraint. That has produced multiple
violations (2025-10-27 OAuth tokens, 2026-04-29 WiFi PSK, 2026-05-12 SOPS partial output,
2026-05-13 settings.json plaintext keys, 2026-05-18 db_url grep leak, 2026-05-18
SOPS phone+pairing code via journalctl). It must stop.

**The rule applies to BOTH INPUTS AND OUTPUTS.** Past violations clustered around
output-emitting tools (`journalctl`, `curl`, `psql`, `jq` on a config file, even
`Read` of an innocuous-looking settings file that turned out to hold plaintext API
keys), not just direct `cat`-of-secret. Any data path that *might* surface
credentials, tokens, PII, or PSKs into this conversation triggers the check —
regardless of whether the *source path* looks sensitive.

**Mandatory pre-flight check — run BEFORE any tool call whose stdout/stderr will
appear in this conversation AND whose source data might carry secrets:**

Triggering tools include but are not limited to: `cat`, `head`, `tail`, `Read`,
`less`, `more`, `awk`, `sed -n`, redirected `grep`, `journalctl`, `systemctl status`
on units that load credentials, `curl`/`wget` against config endpoints, `psql -c`
against tables that may hold tokens, `jq` against settings files, `ssh <host> '<cmd>'`
when the remote command emits secrets, `nmcli connection show <wifi-name>` without
field-targeting, the Read tool against anything under `~/.claude/`, `~/.config/`, or
`/var/lib/<service>/`.

1. **PATH CHECK** — Is the path on the FORBIDDEN-BY-DEFAULT list below, or in any
   directory adjacent to one (network, auth, secrets, credential storage)?
   - If yes: STOP. Use metadata-only commands (`ls -la`, `stat`, `wc -l`, `file`) or
     service-aware tools (`nmcli` field selectors, `systemctl status`, `journalctl`,
     `resolvectl`) instead.
   - If unsure: STOP and ask the user. Asking is cheap. A leaked secret is not.

2. **PURPOSE CHECK** — Will this command's output appear in the conversation?
   - If yes AND the file may contain credentials, tokens, keys, SSIDs, IPs, or PII:
     STOP. Use a field-targeted extractor (e.g. `nmcli -f connection.id,connection.type,connection.autoconnect`)
     or pipe through redaction. Never `cat` "to see what's in there."

3. **BATCH CHECK** — When dispatching parallel reads, apply checks 1–2 to EACH path
   independently. Do NOT extrapolate from one safe read to others ("the wired profile
   was just routing config, so the wifi profile is too" — wrong, and the exact path
   that produced the 2026-04-29 violation).

4. **GREP HIT CHECK** — If a `grep` shows that a file or module deals with credentials,
   secrets, or auth (e.g. matches `credential`, `secret`, `token`, `psk`, `password`,
   `api_key`, `oauth`), every nearby file is suspect until proven otherwise.

5. **OUTPUT CHECK** — Before pasting any block of tool output into the conversation,
   ask: could this output contain a credential the user moved into SOPS, a token a
   service loaded via `LoadCredential`, an API key in `env`, a PSK, an OAuth refresh
   token, a phone number / SSID treated as PII, or a database connection string with
   a password? If the answer is "possibly yes":
   - DO NOT paste the raw block. Paraphrase ("the service is running, paired=true, N
     vCards indexed") or quote a *specific, manually-verified-safe* line.
   - When a particular line must be shown, redact secrets inline in the *same
     command* that produces it — never as a follow-up step. E.g.
     `journalctl ... | sed -E 's/(code for )\+[0-9]+(: )\S+/\1[REDACTED]\2[REDACTED]/'`,
     or `jq 'del(.env)' < settings.json`.
   - "I just want to confirm the value flowed through" is the failure mode that
     produced the 2026-05-18 SOPS phone+pairing leak. Verifying SOPS plumbing by
     pasting the journal IS the leak.

**Mechanical backstop (active since 2026-05-18):** A PreToolUse hook wraps every
`Bash` tool call with a pipe through `~/.claude/scripts/claude-output-redactor.py`,
scrubbing common credential patterns (E.164 phone numbers, API key prefixes
`sk-ant-*`/`sk-proj-*`/`gh*_*`/`AIza*`/`pplx-*`/etc., Bearer tokens, postgres/mysql
URLs with passwords, htpasswd lines, PEM private-key bodies, and generic
`password=`/`token=`/`secret=` assignments). The hook is a **safety net, not a
license to ignore the rule above.** It won't catch every shape, it doesn't apply
to `Read`/`Grep`/`Glob` output, and a single new credential format slips through.
Treat the redaction as defense in depth — apply the OUTPUT CHECK first; the hook
is only there to soften the consequence when the check fails.

**FORBIDDEN-BY-DEFAULT paths — no `cat`/`Read`/content display without explicit
user approval, even with `sudo`:**

- `/etc/NetworkManager/system-connections/*` — WiFi PSKs, VPN credentials, EAP keys
- `/run/secrets/*` — SOPS-decrypted secrets at runtime
- `/var/lib/hass/.storage/*` — OAuth tokens, refresh tokens, integration secrets
- `*.age`, `*.key`, `*.pem`, `*.crt` private halves, `*credentials*`, `*.env`
  when under `/etc`, `/var`, `/run`, or `/home/*/.config`
- Any output of `sops -d` — that command itself is forbidden
- `/var/lib/<service>/` files named `passwd`, `password`, `secret`, `token`, `key`,
  `*.sqlite` for auth-bearing services
- Home Assistant, Postfix, Dovecot, Samba, Step-CA, PostgreSQL data directories
  beyond metadata

**Adjacent / context-sensitive paths — apply Purpose Check rigorously:**

- `/etc/nixos/secrets/secrets.yaml` — encrypted form is OK to view; never decrypt
- `nmcli connection show <name>` — fine for metadata; avoid full output for WiFi
- `~/.claude/settings.json`, any tool's `settings.json`/`config.json` — may hold
  plaintext API keys in MCP `env` blocks or similar; if you must inspect, use
  `jq 'del(.. | .env? // empty)'` or field-target a known-safe key

**Outputs that frequently surface secrets despite an innocuous source path:**

- `journalctl -u <unit>` for any service that takes `LoadCredential`, prints a
  pairing/registration code, or logs unredacted request bodies (whatsapp-bridge,
  hass, postfix, dovecot, stock-trader, rspamd, anything that calls a third-party
  API). Paste only summary lines you've eyeballed; never dump the whole tail.
- `curl http://<svc>/api/config` or any settings-dump endpoint — pipe through
  `jq 'del(.apiKey, .token, .password)'` (or the project-specific shape) before
  display.
- `psql -c "SELECT * FROM <auth-table>"` — column-filter to non-secret fields, or
  use `\d` for schema only.
- `Read` of `~/.claude/settings.json`, `*.env`, `*.credentials`, OAuth client JSON
  — opt for field-targeted jq instead.
- `ssh <host> '<cmd>'` where the remote command would normally print secrets — the
  ssh stdout becomes your conversation just like a local command would.

**If you violate these rules: STOP ALL WORK immediately. Apologize. Save a feedback
memory describing the specific failure mode. Wait for explicit user acknowledgment
before resuming. Do NOT "continue carefully" — STOP.**

---

### SYSTEM OPERATIONS

**NEVER reboot the machine:**
- Only the user will manually reboot the system
- Do not suggest, recommend, or attempt system reboots
- If a change requires a reboot, inform the user and let them decide when to reboot

### DATA LOSS PREVENTION

**NEVER use systemd tmpfiles.rules for persistent data directories:**

- **`d` directive** = Creates directory if it doesn't exist, **PRESERVES contents**
- **`D` directive** = Creates OR **EMPTIES directory** when `systemd-tmpfiles --remove` runs (on every boot/rebuild)
- **`e` directive** = Adjusts permissions only, never creates or deletes

**CRITICAL: The D directive is for temporary directories like /tmp, NOT for data storage!**

**For persistent data directories, use ZFS datasets or regular directories WITHOUT tmpfiles.rules.**

**Before modifying tmpfiles.rules:**
1. STOP and verify: Is this data meant to persist or be temporary?
2. For persistent data: Use ZFS datasets, NOT tmpfiles.rules
3. For temporary data: Use `D` directive with age parameters
4. Wait for explicit user approval

**Past incidents:**
- **2025-11-04**: Changed `/var/mail/johnw` from `d` to `D`, causing mail deletion
- **2025-11-09**: Used `D` directive for container data directories, lost database twice due to emptying on rebuild

### SECURITY - NO SECRETS IN OUTPUT

**This section is enforced by the PRIMARY LENS pre-flight check above.** Do not skip
that check on the assumption that this list is exhaustive — it isn't. The PRIMARY
LENS is the authoritative gate; this list is a non-exhaustive reminder.

**NEVER reveal or display:**
- Passwords, API keys, tokens, OAuth credentials
- WiFi SSIDs/passwords, EAP credentials, VPN PSKs
- Network topology, internal IP addresses, port mappings beyond what `docs/ports.txt` documents
- Contents of any file under `/etc/NetworkManager/system-connections/` (WiFi/VPN profiles)
- Contents from `/run/secrets/` or decrypted SOPS files
- Home Assistant `.storage/*` files (contain OAuth tokens)
- Certificate private keys or full PEM bundles containing them

**FORBIDDEN commands (no exceptions, even with `sudo`):**
- `sops -d` (decrypts secrets)
- Any command reading `/run/secrets/*`
- `cat`, `head`, `tail`, `less`, `Read`, `awk`, `sed -n`, redirected `grep` against
  files under `/etc/NetworkManager/system-connections/`
- Reading `/var/lib/hass/.storage/*` files
- Commands showing `access_token`, `refresh_token`, `api_key`, `psk=`, `password=` fields

**For NetworkManager profile inspection, use field-targeted nmcli only:**
- ✅ `nmcli -f connection.id,connection.type,connection.autoconnect,connection.autoconnect-priority connection show <name>`
- ✅ `nmcli -f general.state,general.connection device show <iface>`
- ❌ `cat /etc/NetworkManager/system-connections/*.nmconnection`
- ❌ `nmcli connection show <name>` (without `-f`) on WiFi/VPN profiles

### SECURITY - FILE PERMISSIONS

**NEVER make sensitive files world-readable or group-readable without explicit justification:**

- **Password files, private keys, tokens** = MUST be `600` (owner read/write only) or `400` (owner read-only)
- **NEVER use `644` (world-readable) or `664` (group-readable) for sensitive files**
- **NEVER use `777`, `666`, or any permission that allows write access to group/others**

**Proper permission patterns:**
- Secrets for root-only services: `600 root:root`
- Secrets for specific service user: `600 service-user:service-user` or `640 root:service-group`
- If a service can't read a secret file, the solution is NOT to open permissions - instead:
  1. Check what user/group the service runs as
  2. Change file ownership to match (`chown user:group`)
  3. Use minimal permissions (`600` or `640` if group access needed)
  4. Consider using systemd `LoadCredential=` for better isolation

**Past violations:**
- **2025-11-14**: Attempted to fix PostgreSQL password read by changing from `600` to `644` (world-readable)

**SAFE operations:**
- `sops /etc/nixos/secrets/secrets.yaml` (interactive editor)
- `ls -la /run/secrets/` (metadata only)
- Checking logs with `journalctl`
- Using `systemctl status` commands

**Past violation (2025-10-27):** Displayed OAuth tokens from Home Assistant storage. Should have used journalctl logs instead.

**If you violate these rules: STOP ALL WORK. Apologize and wait for user acknowledgment.**

---

## System Overview

**Host:** vulcan - aarch64 Linux on Apple hardware (Asahi Linux)
**Key Services:** PostgreSQL, Step-CA, Dovecot, Samba, Home Assistant, Prometheus/Grafana, Nginx
**Storage:** ZFS on /tank
**State Version:** 25.11 (DO NOT change)

## SOPS Secrets Management

Secrets are encrypted in `/etc/nixos/secrets/secrets.yaml` using age encryption.
That file lives in a SEPARATE git repo at `/etc/nixos/secrets/`, consumed as the
non-flake flake input `secrets` (declared in `flake.nix`; `sops.defaultSopsFile`
is set from it in `modules/core/system.nix`). The main repo's `.gitignore` excludes `/secrets`,
so it is tracked by its own repo, not by `/etc/nixos`'s.
Private age keys must NEVER be committed. This host's age identities are derived
from `/etc/ssh/ssh_host_ed25519_key` plus `/var/lib/sops-nix/key.txt` — there are
no `.age` key files in the repo tree.

```bash
# Edit secrets
sops /etc/nixos/secrets/secrets.yaml

# Apply changes (see System Management -- always go through this script)
/etc/nixos/build

# Secrets deploy to
/run/secrets/
```

**Adding secrets:**
1. Edit with `sops /etc/nixos/secrets/secrets.yaml`
2. Declare in NixOS module with owner/permissions
3. Access via systemd `LoadCredential` or direct path
4. Rebuild to deploy

## Quick Command Reference

### System Management

**Always build and switch through `/etc/nixos/build`. Do not call `nixos-rebuild` directly.**

```bash
/etc/nixos/build                 # acquire the lock, nixos-rebuild switch, release the lock
/etc/nixos/build build           # build only
/etc/nixos/build test            # activate without creating a generation
/etc/nixos/build switch --show-trace   # extra args pass through to nixos-rebuild
/etc/nixos/build -- <command>    # run any command while holding the build lock
nix flake update                 # Update inputs
nix fmt                          # Format Nix files
```

The script owns the whole `/etc/nixos/.nixos-build` protocol so it cannot be forgotten:
it acquires the lock atomically (`O_EXCL`, no test-then-create race), releases it on
**every** exit path including SIGINT/SIGTERM/SIGHUP and a crashed build, and logs every
event — acquire attempt, waiting, forcible seizure, acquisition, build start/finish/result,
full build output, lock release — to `/var/log/build.log` (mode 0600, size-rotated).

Waiting behaviour: a held lock is waited on for up to 4 hours (`--wait-seconds`), then
**forcibly seized**. A lock the script itself wrote records the holder's PID, so if that
process is provably dead the lock is seized immediately rather than after the full wait
(`--no-stale-seize` disables this). A hand-`touch`ed lock carries no PID and is therefore
never judged stale — it waits out the full timeout, because being wrong here means killing
someone's real build.

This replaced the manual convention after a lock left behind by a finished session blocked
another for 85 minutes. The lock path and its "file exists == locked" meaning are unchanged,
so a session still doing it by hand interoperates in both directions.

### Service Status
```bash
sudo systemctl status <service>
sudo journalctl -u <service> -f
sudo systemctl restart <service>
```

### Certificate Authority
```bash
# ALWAYS use the secure script (handles SOPS internally):
sudo /etc/nixos/certs/renew-certificate.sh "domain.lan" \
  -o "/output/dir" -d 365 --owner "user:group"

# Common locations:
# Nginx: /var/lib/nginx-certs/ (nginx:nginx)
# PostgreSQL: /var/lib/postgresql/certs/ (postgres:postgres)
# Dovecot: /var/lib/dovecot-certs/ (root:root)
```

### Database Backups
Daily automated backups at 2 AM to `/tank/Backups/PostgreSQL/`
```bash
sudo systemctl status postgresql-backup.timer
sudo systemctl start postgresql-backup.service  # Manual backup
```

### Port Management

**Port Registry: `/etc/nixos/docs/ports.txt`**

The system maintains a comprehensive port registry to prevent conflicts and track port assignments.

```bash
# View all ports in use
cat /etc/nixos/docs/ports.txt

# Find an available port in a range
grep -E "^90[0-9]{2}" /etc/nixos/docs/ports.txt  # Check 9000-9099 range
```

**CRITICAL: When adding a new service that uses a port:**

1. **Check `/etc/nixos/docs/ports.txt` FIRST** to find an available port
2. Assign the port to your service in the NixOS configuration
3. **IMMEDIATELY update `/etc/nixos/docs/ports.txt`** with the new port assignment
4. Include the interface binding (0.0.0.0, 127.0.0.1, ::, *, etc.)
5. Add a descriptive service name

**Format for ports.txt entries:**
```
PORT INTERFACE... [SERVICE/DESCRIPTION]

Examples:
9999 127.0.0.1 MyService exporter
8888 0.0.0.0 :: MyApp web interface
3000 * MyService (all interfaces)
```

**Verifying port availability:**
```bash
# Check if port is already assigned in config
grep "^PORT_NUMBER " /etc/nixos/docs/ports.txt

# Check if port is actually in use (run as root)
sudo ss -tunlp | grep :PORT_NUMBER
```

**Common port ranges:**
- 80, 443: HTTP/HTTPS (nginx proxies)
- 9000-9999: Prometheus exporters and monitoring
- 5000-5999: Application services
- 3000-3999: Web applications
- 127.0.0.1 ports: Services proxied by nginx (not directly exposed)

### Common Services

**Home Assistant**
- URL: https://hass.vulcan.lan
- Config: `/var/lib/hass/`
- Integrations: See `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md`

**Monitoring**
- Grafana: https://grafana.vulcan.lan
- Prometheus: https://prometheus.vulcan.lan
- Nagios: https://nagios.vulcan.lan

**Email**
```bash
doveadm index -u <user> '*'        # Index for search
doveadm fts optimize -u <user>     # Optimize FTS
```

**File Sharing (Samba)**
- Connect: `smb://vulcan.lan/<share>`
- Shares defined in `/etc/nixos/modules/services/samba.nix`

**ZFS**
```bash
dh              # Custom dataset helper
zfs list        # Standard listing
zpool status    # Pool health
```

## Module Organization

There is NO `configuration.nix` and NO root-level `secrets.yaml`. The only `.nix`
files at the repo root are `flake.nix` and `models.nix`; the host configuration is
`hosts/vulcan/default.nix`.

```
/etc/nixos/
├── flake.nix                # Main flake configuration (entry point)
├── models.nix               # Shared LLM model registry (llm.reasoning.name, ...)
├── hosts/vulcan/
│   ├── default.nix          # THE host configuration (the big `imports` list; stateVersion here)
│   └── hardware-configuration.nix
├── modules/                 # 204 .nix across 11 category dirs
│   ├── services/            # Service configurations (80 .nix)
│   ├── monitoring/          # Prometheus, Grafana, alerts/, exporters
│   ├── containers/          # Container / quadlet definitions
│   ├── core/                # base, networking, system, programs, wifi, ...
│   ├── users/               # Users + home-manager/ modules
│   └── ...                  # storage, security, packages, lib, maintenance,
│                            #   hardware
├── overlays/                # Package overlays
├── pkgs/                    # Locally packaged software
├── certs/                   # Certificate scripts (renew-certificate.sh)
├── scripts/                 # Exporters, self-heal actions, validation harnesses
├── docs/                    # Additional documentation
├── secrets/                 # SOPS store — SEPARATE git repo, flake input `secrets`
│   └── secrets.yaml         #   (gitignored by this repo)
└── nagios/                  # SEPARATE git repo, flake input `nagios`
    └── hosts.nix            #   Private network topology (gitignored by this repo)
```

## Troubleshooting

**Build issues:**
```bash
nix flake check
sudo nixos-rebuild build --flake '.#vulcan' --show-trace
```

**Secret issues:**
```bash
ls -la /run/secrets/         # Check deployment
stat /run/secrets/<name>     # Check permissions
```

**Service issues:**
```bash
systemctl --failed           # List failed services
journalctl -u <service> -f  # View logs
```

## Important Files

- `/etc/nixos/nagios/hosts.nix` - Private network topology (separate git repo, flake
  input `nagios`; imported at `modules/services/nagios.nix` as `nagios.outPath + "/hosts.nix"`)
- `/etc/nixos/secrets/secrets.yaml` - SOPS-encrypted secrets (separate git repo,
  flake input `secrets`; excluded from this repo by `.gitignore`)
- `/etc/nixos/hosts/vulcan/default.nix` - The host configuration (there is no `configuration.nix`)
- `/etc/nixos/docs/ports.txt` - Port registry (MUST update when adding services)
- `/etc/nixos/docs/` - Detailed service documentation
- `/tank/Backups/` - Backup storage location
- `/run/secrets/` - Runtime secret deployment

