# OpenClaw Configuration: Nix-Generated, Atomic SOPS Secrets

> **Archival — 2026-05-14.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/services/openclaw-config.nix`).

**Status:** Design — approved 2026-05-14 via brainstorming session;
spec-review feedback (round 1) integrated 2026-05-14.

**Goal:** Move openclaw's runtime configuration from a single SOPS-encrypted
JSON blob (`secrets.yaml#openclaw/config`) to a Nix-generated structural
template + atomic per-credential SOPS secrets. Result: openclaw.json becomes
reviewable in `git`, `models.nix` becomes the source of truth for which models
openclaw exposes, and individual config tweaks (e.g. raising
`models.providers.vulcan.timeoutSeconds`) become one-line Nix edits with
`nixos-rebuild switch` — no sops decrypt round-trip.

## Problem Statement

Today, `/var/lib/openclaw/.openclaw/openclaw.json` is materialised at boot by
`openclaw-prepare-secrets.service`, which `install`s the SOPS-decrypted file
`/run/secrets/openclaw/config` into `${stateDir}/.openclaw/openclaw.json` for
virtiofs sharing into the microVM. The encrypted blob is ~13 top-level JSON
keys (gateway, meta, models, plugins, skills, tools, wizard, agents, auth,
channels, commands, messages, acp) totalling several hundred lines.

This conflates two unrelated concerns:

1. **Structural config** — gateway port, model tier choice, plugin enable
   flags, agent timeouts, model metadata, etc.  None of this is secret.
   All of it should live in `git` so changes are reviewable, models can
   be derived from the single source of truth (`/etc/nixos/models.nix`),
   and edits don't require `sops -d` round-trips.

2. **Credentials** — seven distinct API keys/tokens scattered across the
   tree (LiteLLM virtual key, Discord bot token, gateway auth token, Brave
   web-search key, Qdrant API key, GitHub PAT for `gh-issues`, plus a
   `memorySearch.remote.apiKey` that may or may not be a real key).  These
   genuinely need encryption at rest.

The current single-blob architecture means every structural tweak — adding
`timeoutSeconds: 1800` to the vulcan provider, toggling a plugin, raising an
agent budget — requires the full sops decrypt → edit → re-encrypt → rebuild
loop. It also means models in openclaw are pinned to literal LiteLLM names
duplicated from `models.nix`, so swapping models requires editing both files.

## Design Decisions Locked During Brainstorming

| Decision | Choice | Rationale |
|---|---|---|
| Nix module style | **Hybrid** — typed `mkOption`s for hot fields, free-form `extraConfig` attrset for everything else | Lets `services.openclaw.config.models.providers.vulcan.timeoutSeconds = 1800;` be a typed one-liner without forcing every openclaw.json field to be a typed option |
| SOPS granularity | **One atomic secret per credential** (6 entries, plus 1 conditional) | Independent rotation, smallest blast radius, `sops` opens to a single short string per credential |
| `models.nix` mapping | **Extend `models.nix`** with optional `contextWindow`, `maxTokens`, `api`, `reasoning`, `input` | Single source of truth; openclaw module derives `.models.providers.vulcan.models[]` mechanically |
| Tier exposure | **Only the `agent` tier** | openclaw uses one model at a time and that's always the agent tier; exposing all tiers added surface area we don't need |
| Substitution mechanism | **`jq` deep-merge** (`jq -s '.[0] * .[1]'`) | Naturally handles nested paths; template remains valid JSON on its own (nulls at secret leaves); no extra runtime dependency |
| Migration | **Side-by-side** | Add atomic secrets without touching the existing blob; cut over only after structural diff passes; delete the legacy blob in a later sops edit |
| Verification | **Structural diff dry-run** before `switch`; existing health-checks as runtime backstop | Catches schema bugs before any service restart |

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────────┐
│  /etc/nixos/models.nix                                              │
│    extended with optional fields:                                   │
│      contextWindow ? 262144                                         │
│      maxTokens     ? 81920                                          │
│      api           ? "openai-completions"                           │
│      reasoning     ? false                                          │
│      input         ? [ "text" ]                                     │
└────────────────────┬────────────────────────────────────────────────┘
                     │ imported by
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│  modules/services/openclaw-config.nix                               │
│    options:                                                         │
│      services.openclaw.config = {                                   │
│        modelTier = "agent";                                         │
│        models.providers.vulcan.timeoutSeconds = 1800;               │
│        ...typed hot fields...                                       │
│        extraConfig.wizard = { ... };  # free-form passthrough       │
│      };                                                             │
│    builds:                                                          │
│      pkgs.openclaw-config-template = pkgs.writeText                 │
│        "openclaw.json.template"                                     │
│        (builtins.toJSON (cfg.config // sentinels_at_secret_paths))  │
└────────────────────┬────────────────────────────────────────────────┘
                     │ consumed by
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│  modules/services/openclaw-microvm.nix                              │
│    systemd.services.openclaw-prepare-secrets:                       │
│      reads:  /run/secrets/openclaw/litellm-virtual-key              │
│              /run/secrets/openclaw/discord-token                    │
│              /run/secrets/openclaw/gateway-auth-token               │
│              /run/secrets/openclaw/brave-api-key                    │
│              /run/secrets/openclaw/qdrant-api-key                   │
│              /run/secrets/openclaw/gh-issues-api-key                │
│      composes overlay JSON via jq -n --rawfile                      │
│      merges:  jq -s '.[0] * .[1]' $template <(echo $overlay)        │
│      writes:  ${stateDir}/.openclaw/openclaw.json (atomic mv)       │
└─────────────────────────────────────────────────────────────────────┘
```

### SOPS layout

The single `openclaw/config` entry is replaced by atomic entries.
**Reuse existing SOPS entries where they already hold the right credential**
(established at lines 236 and the existing `qdrant/api-key` entry in
`openclaw-microvm.nix`); add new entries only for credentials not already
extracted to atomic SOPS:

| SOPS key | Status | Maps to JSON path(s) | Notes |
|---|---|---|---|
| `openclaw/litellm-virtual-key` | **NEW** | `.models.providers.vulcan.apiKey` (always) AND `.agents.defaults.memorySearch.remote.apiKey` (iff value is identical to vulcan apiKey; see Pre-Execution Check) | If memorySearch is a distinct key, this entry stays single-mapping and a second new entry is added |
| `openclaw/discord-token` | **NEW** | `.channels.discord.token` | |
| `openclaw/gateway-auth-token` | **NEW** | `.gateway.auth.token` | |
| `openclaw/perplexity-api-key` | **REUSE existing** (line 236 of openclaw-microvm.nix) | `.plugins.entries.brave.config.webSearch.apiKey` | The `brave` plugin uses a Perplexity key today; reuse the existing atomic SOPS entry rather than duplicating |
| `qdrant/api-key` | **REUSE existing** (already staged for openclaw at line ~579) | `.plugins.entries.memory-qdrant.config.qdrantApiKey` | |
| `openclaw/gh-issues-api-key` | **NEW** | `.skills.entries.gh-issues.apiKey` | |
| `openclaw/memsearch-api-key` | **CONDITIONAL NEW** | `.agents.defaults.memorySearch.remote.apiKey` | Only if Pre-Execution Check (below) reveals memorySearch is a separate key (not the LiteLLM virtual key and not the static literal `"dummy-key"`) |

**Pre-Execution Check (Phase A1, blocking):** before writing any of the new
Nix code, the implementer runs:

```bash
sudo jq -r '
  .agents.defaults.memorySearch.remote.apiKey as $m
  | .models.providers.vulcan.apiKey as $v
  | { matches_vulcan: ($m == $v),
      is_dummy: ($m == "dummy-key"),
      is_empty_or_null: (($m // "") == ""),
      first_char: ($m // "" | .[0:1]),
      last_char: ($m // "" | .[-1:]),
      length: ($m // "" | length) }
' /var/lib/openclaw/.openclaw/openclaw.json
```

This prints only structural metadata about the field (whether it matches
known values, plus opaque length/boundary characters) — never the value
itself. Based on the output:

- `matches_vulcan == true` → memorySearch reuses `openclaw/litellm-virtual-key`,
  no new SOPS entry needed
- `is_dummy == true` → memorySearch hardcoded as the literal string
  `"dummy-key"` in the Nix template, no SOPS entry needed
- Otherwise → add `openclaw/memsearch-api-key` as a separate atomic secret
  and update the substitution overlay accordingly

The legacy `openclaw/config` entry stays in `secrets.yaml` through the
migration and is removed in a later sops edit only after the new config has
been demonstrably healthy. NixOS continues to decrypt it harmlessly to
`/run/secrets/openclaw/config` during the side-by-side window; the new code
ignores it.

### Substitution

The existing `openclaw-prepare-secrets.service` already stages a host file at
`${secretsStagingDir}/openclaw-config` (= `/var/lib/microvms/openclaw/secrets/openclaw-config`),
which is virtiofs-shared into the guest VM as `/run/openclaw-secrets/openclaw-config`.
The guest's openclaw.service preStart (in `openclaw-vm.nix` around line 717)
then `cp -f`s that file to `${openclawDir}/openclaw.json` inside the VM and
post-processes it. **We keep that contract.** All we change is the body of
the host-side prepare-secrets service: instead of `cp`ing one decrypted blob,
it merges the Nix template with the atomic secrets and writes the merged file
to the same staging path the guest already trusts.

```bash
set -euo pipefail
TEMPLATE=${pkgs.openclaw-config-template}/openclaw.json.template
# Same staging path the guest already mounts as /run/openclaw-secrets/openclaw-config:
TARGET="${secretsStagingDir}/openclaw-config"
SECRETS=/run/secrets

OVERLAY=$(jq -n \
  --rawfile vk "$SECRETS/openclaw/litellm-virtual-key" \
  --rawfile dt "$SECRETS/openclaw/discord-token" \
  --rawfile gt "$SECRETS/openclaw/gateway-auth-token" \
  --rawfile pk "$SECRETS/openclaw/perplexity-api-key" \
  --rawfile qk "$SECRETS/qdrant/api-key" \
  --rawfile gh "$SECRETS/openclaw/gh-issues-api-key" \
  '{
    models: { providers: { vulcan: { apiKey: ($vk|rtrimstr("\n")) } } },
    agents: { defaults: { memorySearch: { remote: { apiKey: ($vk|rtrimstr("\n")) } } } },
    channels: { discord: { token: ($dt|rtrimstr("\n")) } },
    gateway: { auth: { token: ($gt|rtrimstr("\n")) } },
    plugins: { entries: {
      "memory-qdrant": { config: { qdrantApiKey: ($qk|rtrimstr("\n")) } },
      brave: { config: { webSearch: { apiKey: ($pk|rtrimstr("\n")) } } }
    } },
    skills: { entries: { "gh-issues": { apiKey: ($gh|rtrimstr("\n")) } } }
  }')

# Stage atomically into the existing secrets directory (already owned root,
# perms set up by the host-side service that runs before this body).
TMP=$(mktemp --tmpdir="${secretsStagingDir}" openclaw-config.XXXXXX)
trap 'rm -f "$TMP"' EXIT
jq -s '.[0] * .[1]' "$TEMPLATE" <(printf '%s' "$OVERLAY") > "$TMP"
chown ${toString openclawUid}:${toString openclawGid} "$TMP"
chmod 0400 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT
```

**Merge correctness invariant:** `jq -s '.[0] * .[1]'` deep-merges objects
but *replaces* arrays. Every secret-bearing JSON path in today's openclaw.json
(see appendix) terminates in a scalar inside an object — never inside an array
element — so the overlay shape can splice each credential into the template
without disturbing surrounding structure. If openclaw upstream ever introduces
a secret nested inside an array element, the substitution would need to be
restructured (likely with `--slurpfile` and a per-element merge), and the spec
must be revised accordingly.

Atomic write via `mktemp` + `mv` ensures the guest never sees a half-built
file when it does `cp -f /run/openclaw-secrets/openclaw-config …` at preStart.
The `rtrimstr("\n")` strips the trailing newline that sops adds to single-line
secrets. Ownership and mode match the file the existing `cp -f` produces today
(`openclaw:openclaw`, `0400`) so the guest-side semantics are preserved
byte-for-byte.

The guest-side preStart in `openclaw-vm.nix` (lines 717-764) is **not
modified** by this refactor; everything downstream of that `cp -f` continues
to work unchanged.

## Migration Plan (Side-by-Side)

Phases are tightly bounded so partial progress is always safe.

| Phase | Actor | Action | Safe to stop here? |
|---|---|---|---|
| A1 | Claude | **Pre-Execution Check** on `memorySearch.remote.apiKey` (see SOPS layout section). Output: 6 vs 7 secrets, single-source vs dummy-literal mapping. No file mutation. | ✅ Yes — read-only inspection |
| A2 | Claude | Write `openclaw-config.nix`, extend `models.nix`, update prepare-secrets script body. **Build + dry-activate (`nixos-rebuild dry-activate`).** No switch, no behaviour change. | ✅ Yes — old blob still in use |
| B | **User** | Open `sops /etc/nixos/secrets.yaml`. **Without touching `openclaw/config`**, add the new atomic entries (3 or 4 of them — `openclaw/litellm-virtual-key`, `openclaw/discord-token`, `openclaw/gateway-auth-token`, `openclaw/gh-issues-api-key`, plus conditionally `openclaw/memsearch-api-key`). Each value is copied out of the corresponding field in the existing `openclaw/config` blob. `openclaw/perplexity-api-key` and `qdrant/api-key` already exist — do not duplicate them. | ✅ Yes — new entries are unused until Phase D |
| C | Claude | Render the new template into the nix store. Run a structural diff: `diff <(jq -S 'del(.. \| .apiKey?, .token?, .password?, .secret?)' <new>) <(jq -S 'del(...)' <current>)`. Both inputs have secrets stripped before any comparison touches this terminal. Any structural mismatch is a template bug — fix it. | ✅ Yes — no service restart yet |
| D | Claude | `nixos-rebuild switch`. New `openclaw-prepare-secrets.service` body reads the atomic secrets and writes the merged openclaw.json to staging. microvm@openclaw restarts (it's already restartable; runs in a few seconds). | ✅ Yes — verify with existing health-checks |
| E | **User**, later | Once the new config has been healthy for a day, open `sops` and delete the `openclaw/config` entry. Also remove the corresponding `sops.secrets."openclaw/config"` declaration from `openclaw-microvm.nix` in the same commit. | ✅ Terminal state |

**Rollback at any phase:** revert the latest Nix commit. Phase A and C are
already revertible (no behaviour change). Phase D is revertible because the
legacy blob is still in `secrets.yaml` and the prior `openclaw-prepare-secrets`
script body would simply start using it again on rebuild.

## Verification

### Pre-switch (Phase C)

**The sanitisation filter is load-bearing.** A naive
`del(.. | .apiKey?, .token?, .password?, .secret?)` only matches keys whose
*exact* name is one of those four — it would NOT strip `qdrantApiKey`,
`webSearchApiKey`, `bearerToken`, or any future CamelCase variant. The Qdrant
key in particular is at `.plugins.entries.memory-qdrant.config.qdrantApiKey`
and would leak under the naive filter.

Use a regex-based deletion that strips any key whose name *matches* a
case-insensitive secret-bearing pattern:

```bash
SECRET_RE='([Aa]pi[Kk]ey|[Tt]oken|[Pp]assword|[Pp]assphrase|[Ss]ecret|[Ss]ecretKey|[Pp]sk|[Bb]earer)'

# Sanitise the live (currently-deployed) config. Pre-strip BEFORE any
# bytes reach stdout.
sudo jq --arg re "$SECRET_RE" -S '
  walk(
    if type == "object"
    then with_entries(select(.key | test($re) | not))
    else .
    end
  )
' /var/lib/openclaw/.openclaw/openclaw.json \
  > /tmp/openclaw-current-sanitised.json

# Sanitise the new Nix-rendered template. The template already has `null`
# at secret leaves, but apply the same filter so the comparison is on
# matched keys only — the template's `null`s and the current file's real
# values both disappear, leaving the structure-only diff.
jq --arg re "$SECRET_RE" -S '
  walk(
    if type == "object"
    then with_entries(select(.key | test($re) | not))
    else .
    end
  )
' "$(nix build --no-link --print-out-paths /etc/nixos#openclaw-config-template)/openclaw.json.template" \
  > /tmp/openclaw-new-sanitised.json

# Now safe to diff — both files have every secret-named key stripped.
diff -u /tmp/openclaw-current-sanitised.json /tmp/openclaw-new-sanitised.json

# Defensive check: assert neither sanitised file contains any of the
# secret-named keys. Exit non-zero (= halt the migration) if either does.
for f in /tmp/openclaw-current-sanitised.json /tmp/openclaw-new-sanitised.json; do
  if jq --arg re "$SECRET_RE" -e '
    [paths(scalars) | .[-1] | tostring | test($re)] | any
  ' "$f" >/dev/null; then
    echo "FATAL: $f still contains a secret-named key — sanitisation filter is incomplete" >&2
    exit 1
  fi
done

# Clean up.
shred -u /tmp/openclaw-current-sanitised.json /tmp/openclaw-new-sanitised.json
```

Any non-empty diff blocks Phase D until the template matches the current
schema. The post-sanitisation assertion catches the case where openclaw
upstream introduces a new secret-named field naming convention that the
regex doesn't cover — better to halt and update the regex than to print
a leaked credential.

### Post-switch (Phase D)

The existing monitoring stack already covers the runtime path:

- `services.openclawCanary` watches `gateway-vm.log` for plugin-load
  regressions (5-min cadence)
- `services.openclaw-mcporter-check` exercises the mcporter MCP tools
  every 5 min
- `services.hermesHealthCheck` (added in this session) runs full MCP
  round-trip every 5 min
- `services.openclawSelfHeal` triggers microvm restart on persistent
  failure

No new monitoring is required for this refactor.

## Out of Scope

- Refactoring hermes-vm or stock-trader configs along the same lines.
  (Worth doing, but separately.)
- Adding new openclaw features (additional providers, fallback chains,
  new plugins). The migration must produce an openclaw.json that is
  structurally identical to today's, modulo `null` → secret substitution.
- A nix flake check / VM test that builds and asserts the openclaw.json
  schema is complete after upstream openclaw bumps. (Worth considering as
  a follow-up; not required for this refactor.)
- Migrating openclaw to a non-SOPS secret backend (Vault, etc.).

## Security Posture

- I will not decrypt `/etc/nixos/secrets.yaml` at any point during execution.
- Every command that reads the current openclaw.json pre-strips secret-bearing
  paths through `jq del(...)` before any output reaches stdout. If a future
  openclaw release adds new secret-bearing paths, the strip filter must be
  updated correspondingly.
- The Nix template file is shipped into the nix store as-is (contains
  sentinel `null` values, no real secrets). The store is world-readable, so
  this is fine.
- All 6 (or 7) atomic SOPS entries inherit `owner = "openclaw"; mode = "0400"`
  from the existing pattern; no widening of the threat model.

## Open Questions Resolved During Brainstorming

All resolved; tracked in the "Design Decisions Locked" table above.

## Appendix: secret-bearing JSON paths in today's openclaw.json

This list is the authoritative input to the sanitisation regex and the
substitution overlay. Update both whenever a new openclaw release adds a
new secret field.

| JSON path | Field-name pattern | Source of value |
|---|---|---|
| `.models.providers.vulcan.apiKey` | `apiKey` | `openclaw/litellm-virtual-key` |
| `.agents.defaults.memorySearch.remote.apiKey` | `apiKey` | resolved by Pre-Execution Check |
| `.channels.discord.token` | `token` | `openclaw/discord-token` |
| `.gateway.auth.token` | `token` | `openclaw/gateway-auth-token` |
| `.skills.entries.gh-issues.apiKey` | `apiKey` | `openclaw/gh-issues-api-key` |
| `.plugins.entries.memory-qdrant.config.qdrantApiKey` | `qdrantApiKey` *(CamelCase!)* | `qdrant/api-key` |
| `.plugins.entries.brave.config.webSearch.apiKey` | `apiKey` | `openclaw/perplexity-api-key` |

Any future addition that doesn't match `[Aa]pi[Kk]ey|[Tt]oken|[Pp]assword|[Ss]ecret|[Pp]sk|[Bb]earer` requires updating the regex defined under Verification.

## Implementation Constraints

These are non-negotiable invariants the implementer must preserve:

1. **No secret ever appears in a Nix store path.** The new
   `openclaw-config.nix` module must not read `/run/secrets/*` at evaluation
   time (or build time). All credential substitution happens at runtime in
   the systemd unit, never in Nix. The `openclaw-config-template` derivation
   in the store is world-readable and must contain only `null` (or other
   sentinel) values at secret leaves.

2. **No secret ever lands in stdout during verification.** The sanitisation
   filter in the verification block is mandatory; the assertion that
   follows it is mandatory; the `shred -u` of the temp files is mandatory.
   No verification step may print the live openclaw.json (or any sliced
   form thereof) without first applying the regex-based key strip *and*
   asserting it's complete.

3. **No `sops -d` invocations.** This refactor is driven by the desire to
   avoid sops round-trips for structural edits; the implementation never
   itself decrypts `secrets.yaml`. All credential reads come from
   `/run/secrets/openclaw/*` and `/run/secrets/qdrant/*` files that sops-nix
   has already decrypted into a runtime tmpfs.

4. **The host-side directory ownership / mode invariants on
   `${secretsStagingDir}` are preserved.** The existing pattern (dir
   `0755 root:root`; file `0400 openclaw:openclaw`) is what the guest's
   virtiofs mount expects. The new substitution script reuses that — it
   does NOT need to `mkdir -p ${secretsStagingDir}` (an earlier step in
   the same service already does it).

5. **Phase A includes `nixos-rebuild dry-activate`**, not just `build`. The
   dry-activate step instantiates the new typed-options surface and catches
   shape errors (mistyped option, conflicting `mkMerge`, etc.) before any
   sops edit work.

## Implementation Order Note

The brainstorming session enumerated phases A through E. After the
spec-review feedback, **Phase A is split**:

- **Phase A1 (blocking):** run the Pre-Execution Check on
  `memorySearch.remote.apiKey` (see SOPS layout section). This decides
  whether the SOPS-layout has 6 or 7 entries and whether the substitution
  overlay maps `memorySearch.remote.apiKey` from the same source as the
  vulcan apiKey or from a separate `openclaw/memsearch-api-key`.

- **Phase A2:** write `openclaw-config.nix`, extend `models.nix`, update
  the prepare-secrets service body. The shape from Phase A1 informs the
  overlay JSON in this code.

