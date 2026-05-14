# OpenClaw Nix Config Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single SOPS-encrypted `openclaw/config` blob with a Nix-generated openclaw.json template + atomic per-credential SOPS secrets, so structural edits (like `timeoutSeconds: 1800`) become one-line Nix changes that don't require `sops -d` round-trips.

**Architecture:** Two-stage render. (1) `modules/services/openclaw-config.nix` mirrors today's openclaw.json shape as a free-form NixOS option `services.openclaw.config`, derives the model entry from `/etc/nixos/models.nix`, and emits a `pkgs.openclaw-config-template` derivation containing valid JSON with `null` at every secret leaf. (2) `openclaw-prepare-secrets.service` (existing unit, replaced body) reads the template + 4 new + 2 reused atomic SOPS secrets, deep-merges them via `jq -s '.[0] * .[1]'`, and atomically writes the result to the existing virtiofs-shared staging path `${secretsStagingDir}/openclaw-config`. The guest-side preStart in `openclaw-vm.nix` is **not modified**.

**Tech Stack:** Nix (NixOS modules, `builtins.toJSON`, `pkgs.writeText`), `jq` (template authoring + runtime overlay merge), `sops-nix` (per-secret encryption), `bash` (substitution script body).

**Spec:** [`/etc/nixos/docs/superpowers/specs/2026-05-14-openclaw-nix-config-design.md`](../specs/2026-05-14-openclaw-nix-config-design.md)

**Security invariants (carry across every task):**
- Never decrypt `/etc/nixos/secrets/secrets.yaml` directly. Use `/run/secrets/openclaw/*` paths instead.
- Every command that reads `/var/lib/openclaw/.openclaw/openclaw.json` pre-strips secret-named keys with the regex-based `jq walk` filter before any byte reaches stdout.
- The Nix template in the store never contains real credentials — only `null` sentinels.
- Phase B (atomic sops edits) and Phase E (later legacy removal) are user-driven; the executor stops at the Phase B handoff and waits.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `/etc/nixos/models.nix` | **modify** | Add optional `contextWindow`, `maxTokens`, `api`, `reasoning`, `input` to LLM tiers |
| `/etc/nixos/modules/services/openclaw-config.nix` | **create** | Expose `services.openclaw.config` (free-form attrset, default = current structure with `null` at secret leaves) + emit `pkgs.openclaw-config-template` derivation |
| `/etc/nixos/modules/services/openclaw-microvm.nix` | **modify** | Replace the `openclaw-config` `cp -f` block in `openclaw-prepare-secrets.service` with the jq deep-merge from the spec |
| `/etc/nixos/hosts/vulcan/default.nix` | **modify** | Import the new `openclaw-config.nix` module |
| `/etc/nixos/docs/superpowers/plans/2026-05-14-openclaw-nix-config.md` | (this file) | Plan checklist |
| `/etc/nixos/secrets/secrets.yaml` | **user-driven** | Add 4 new atomic SOPS entries (Phase B) — DO NOT modify; instructions only |
| `/etc/nixos/modules/services/openclaw-vm.nix` | **UNCHANGED** | Guest-side preStart at lines 717-764 stays exactly as it is |

---

## Task 1: Phase A1 — Pre-Execution Check on `memorySearch.remote.apiKey`

**Why:** The spec leaves one open structural question — whether `.agents.defaults.memorySearch.remote.apiKey` is the same value as the LiteLLM virtual key, a literal `"dummy-key"`, or a third distinct credential. This drives whether we need 4 new SOPS secrets or 5, and how the substitution overlay maps the memorySearch slot. Answer must come from a metadata-only inspection that never prints the value.

**Files:** none (read-only)

- [ ] **Step 1: Run the metadata-only inspection**

Run:
```bash
sudo jq -r '
  .agents.defaults.memorySearch.remote.apiKey as $m
  | .models.providers.vulcan.apiKey as $v
  | {
      matches_vulcan: ($m == $v),
      is_dummy: ($m == "dummy-key"),
      is_empty_or_null: (($m // "") == ""),
      length: ($m // "" | length)
    }
' /var/lib/openclaw/.openclaw/openclaw.json
```

Expected output: JSON with four booleans and an integer length. **No credential bytes printed.**

- [ ] **Step 2: Record the disposition in this plan**

Append a line to this plan immediately below this step (using `Edit`):
```
**Phase A1 outcome:** matches_vulcan=<bool>, is_dummy=<bool>, mapping_decision=<reuse-vulcan|dummy-literal|new-secret>
```

Then update each subsequent task that references the memorySearch slot to use the chosen mapping:
- If `matches_vulcan == true` → overlay maps `agents.defaults.memorySearch.remote.apiKey` from `--rawfile vk` (same as vulcan); SOPS layout has 4 new entries.
- If `is_dummy == true` → template hardcodes `"dummy-key"` literal at that path; SOPS layout has 4 new entries.
- Otherwise → add `openclaw/memsearch-api-key` to SOPS layout (5 new entries); overlay maps from `--rawfile mk "$SECRETS/openclaw/memsearch-api-key"`.

- [ ] **Step 3: Commit**

```bash
git add /etc/nixos/docs/superpowers/plans/2026-05-14-openclaw-nix-config.md
git commit -m "docs(plan): record Phase A1 disposition for memorySearch.remote.apiKey"
```

---

## Task 2: Snapshot the current structural JSON for use as Nix-module default

**Why:** The new `openclaw-config.nix` module's `services.openclaw.config` default needs to mirror today's full openclaw.json shape. We capture a sanitized snapshot now and use it as the source for the Nix attrset in Task 4.

**Files:** none touched yet; output stored in `/tmp` and `shred`ed after Task 4.

- [ ] **Step 1: Define the sanitization helpers (one-time shell setup)**

```bash
export SECRET_RE='([Aa]pi[Kk]ey|[Tt]oken|[Pp]assword|[Pp]assphrase|[Ss]ecret|[Ss]ecretKey|[Pp]sk|[Bb]earer)'
strip_secrets() {
  jq --arg re "$SECRET_RE" '
    walk(
      if type == "object"
      then with_entries(
        if .key | test($re)
        then .value = null
        else .
        end
      )
      else .
      end
    )
  ' "$1"
}
assert_no_secret_leaf() {
  jq --arg re "$SECRET_RE" -e '
    [paths(scalars) as $p
      | select(($p[-1] | tostring | test($re)) and (getpath($p) != null))]
    | length == 0
  ' "$1" >/dev/null || {
    echo "FATAL: $1 still contains a non-null secret-named leaf" >&2
    return 1
  }
  return 0
}
```

Note: We **set secret values to `null`** rather than deleting the keys, so the structural shape (key names, types of non-secret siblings) is preserved exactly. The assertion only fails if a secret-named leaf has a non-null value.

- [ ] **Step 2: Capture the sanitized snapshot**

`strip_secrets` is a bash function in this shell, so it can't be invoked through `sudo` directly — instead, inline the jq under sudo with the same canonical `$SECRET_RE`:

```bash
sudo jq --arg re "$SECRET_RE" '
  walk(
    if type == "object"
    then with_entries(if .key | test($re) then .value = null else . end)
    else .
    end
  )
' /var/lib/openclaw/.openclaw/openclaw.json > /tmp/openclaw-structural.json
chmod 0600 /tmp/openclaw-structural.json
```

- [ ] **Step 3: Run the post-strip assertion**

```bash
assert_no_secret_leaf /tmp/openclaw-structural.json
echo "Assertion exit code: $?"
```

Expected: prints `Assertion exit code: 0`. If non-zero, halt: extend `SECRET_RE` to cover the new field-name pattern and re-run from Step 1.

- [ ] **Step 4: Sanity-check structure is well-formed JSON of the expected shape**

```bash
jq -e '
  has("gateway") and has("models") and has("agents")
  and has("plugins") and has("skills") and has("channels")
' /tmp/openclaw-structural.json
```

Expected: prints `true` and exit code 0.

- [ ] **Step 5: No commit yet — this is just a temp file for Task 4**

The file lives in `/tmp/openclaw-structural.json` until Task 4 transcribes it into Nix syntax. We `shred -u` it at the end of Task 4.

---

## Task 3: Extend `models.nix` with the optional fields openclaw consumes

**Files:**
- Modify: `/etc/nixos/models.nix`

**Why:** `openclaw.json` describes each model with 8 fields (`id`, `name`, `api`, `reasoning`, `input`, `cost`, `contextWindow`, `maxTokens`); `models.nix` today provides only `name` and the retry params. We add the missing fields as optional with sensible defaults, on the `agent` tier (the only tier we materialize into openclaw, per the spec).

- [ ] **Step 1: Read the current `models.nix`**

```bash
cat /etc/nixos/models.nix
```

- [ ] **Step 2: Add the new optional fields to the `agent` tier**

Edit `/etc/nixos/models.nix` so the `llm.agent` block becomes:

```nix
agent = {
  name = "hera/omlx/Qwen3.6-27B-MLX-8bit";
  maxSeconds = 3600;
  initialDelay = 5;
  maxDelay = 60;

  # ── Optional metadata consumed by openclaw-config.nix ────────────
  # The openclaw `.models.providers.vulcan.models[]` entry needs more
  # detail than the bare `name`. Defaults below match today's runtime
  # config; override per-tier if a future model has different limits.
  api = "openai-completions";
  reasoning = false;
  input = [ "text" ];
  cost = {
    input = 0;
    output = 0;
  };
  contextWindow = 262144;
  maxTokens = 81920;
};
```

The fields are additive and backward-compatible — other services that import `models.nix` continue to read `name`/`maxSeconds`/`initialDelay`/`maxDelay` unchanged.

- [ ] **Step 3: Verify nix evaluates the new schema**

```bash
nix eval --raw --impure --expr 'let m = import /etc/nixos/models.nix; in
  "agent=${m.llm.agent.name} ctx=${toString m.llm.agent.contextWindow} maxTok=${toString m.llm.agent.maxTokens}"'
```

Expected: `agent=hera/omlx/Qwen3.6-27B-MLX-8bit ctx=262144 maxTok=81920`

- [ ] **Step 4: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/models.nix'
```

- [ ] **Step 5: Commit**

```bash
git add /etc/nixos/models.nix
git commit -m "feat(models): extend llm.agent with optional openclaw metadata fields

Adds contextWindow, maxTokens, api, reasoning, input, cost to the agent
tier. Defaults match the current openclaw.json runtime values. Other
services importing models.nix ignore the new fields."
```

---

## Task 4: Create `modules/services/openclaw-config.nix`

**Files:**
- Create: `/etc/nixos/modules/services/openclaw-config.nix`

**Why:** This is the central module: it owns `services.openclaw.config` (free-form Nix attrset mirroring today's openclaw.json), derives the model entry from `models.nix`, and emits the `openclaw.json.template` derivation that the runtime substitution will deep-merge with atomic secrets.

- [ ] **Step 1: Convert the structural snapshot to a Nix attrset (draft)**

Translate `/tmp/openclaw-structural.json` into Nix attrset syntax, with these substitutions:
- `null` values at secret leaves stay as `null` in Nix.
- The `models.providers.vulcan.models` array is replaced by a derived expression that pulls from `models.nix.llm.agent`.

Use this as your worksheet:

```bash
# Quick conversion helper (json → indented nix-like preview, NOT final syntax)
jq 'walk(
  if type == "string" and . == ""
  then null
  else .
  end
)' /tmp/openclaw-structural.json
```

Then by hand, transcribe to Nix. Heuristics:
- JSON object `{"a": 1}` → Nix attrset `{ a = 1; }`
- JSON array `[1, 2]` → Nix list `[ 1 2 ]`
- JSON string keys with hyphens (`"gh-issues"`) → quoted Nix keys (`"gh-issues" = ...;`)
- JSON `null` → Nix `null`
- JSON `true`/`false` → Nix `true`/`false`

- [ ] **Step 2: Write the module skeleton**

Create `/etc/nixos/modules/services/openclaw-config.nix`:

```nix
# Nix-generated openclaw configuration template.
#
# This module owns the structural shape of /var/lib/openclaw/.openclaw/openclaw.json
# as a free-form NixOS option. Secret leaves are set to `null` here; the
# openclaw-prepare-secrets systemd service deep-merges atomic SOPS secrets
# into the rendered template at runtime via `jq -s '.[0] * .[1]'`.
#
# See spec: docs/superpowers/specs/2026-05-14-openclaw-nix-config-design.md
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.openclaw;
  models = import ../../models.nix;
  agentTier = models.llm.agent;

  # The single openclaw model entry derived from models.nix.llm.agent.
  # The guest-side preStart in openclaw-vm.nix overwrites .id and .name
  # with `agentModel` (also from models.nix) so the two stay in lockstep
  # even if Nix evaluation order ever splits them.
  derivedModel = {
    id = agentTier.name;
    name = agentTier.name;
    api = agentTier.api or "openai-completions";
    reasoning = agentTier.reasoning or false;
    input = agentTier.input or [ "text" ];
    cost = agentTier.cost or {
      input = 0;
      output = 0;
    };
    contextWindow = agentTier.contextWindow or 262144;
    maxTokens = agentTier.maxTokens or 81920;
  };

  # ─── Default structure (mirrors today's openclaw.json) ───────────
  # TRANSCRIBED from /tmp/openclaw-structural.json. Secret leaves are
  # null sentinels — the prepare-secrets jq merge fills them at runtime.
  defaultConfig = {
    # … TRANSCRIBE the entire structural snapshot here, with:
    #   - models.providers.vulcan.apiKey      = null;
    #   - models.providers.vulcan.models      = [ derivedModel ];
    #   - agents.defaults.memorySearch.remote.apiKey = null;
    #   - channels.discord.token              = null;
    #   - gateway.auth.token                  = null;
    #   - plugins.entries."memory-qdrant".config.qdrantApiKey = null;
    #   - plugins.entries.brave.config.webSearch.apiKey = null;
    #   - skills.entries."gh-issues".apiKey  = null;
    # Everything else verbatim from the snapshot.
  };

  # Final rendered config = defaultConfig overlaid with user overrides.
  # `lib.recursiveUpdate` does deep merge so user overrides splice into
  # nested paths cleanly.
  renderedConfig = lib.recursiveUpdate defaultConfig cfg.config;

  # Template derivation — valid JSON, world-readable, no real secrets.
  templateDrv = pkgs.writeText "openclaw.json.template" (builtins.toJSON renderedConfig);

in
{
  options.services.openclaw = {
    config = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Override-set for the openclaw.json structural template. Any nested
        attribute set here is deep-merged onto the module's built-in
        `defaultConfig` (which mirrors today's openclaw.json shape).

        Common edits:
          services.openclaw.config.models.providers.vulcan.timeoutSeconds = 1800;
          services.openclaw.config.plugins.entries.whatsapp.enabled = false;
          services.openclaw.config.gateway.controlUi.allowedOrigins = [ ... ];

        Secret leaves (apiKey/token/...) MUST stay null — the
        openclaw-prepare-secrets service substitutes atomic SOPS secrets
        at runtime.
      '';
      example = lib.literalExpression ''
        {
          models.providers.vulcan.timeoutSeconds = 1800;
          plugins.entries.whatsapp.enabled = false;
        }
      '';
    };
  };

  config = {
    # Expose the rendered template via the system's pkgs set so the
    # prepare-secrets service can reference it through `pkgs.openclaw-config-template`.
    nixpkgs.overlays = [
      (final: prev: {
        openclaw-config-template = templateDrv;
      })
    ];
  };
}
```

- [ ] **Step 3: Transcribe `/tmp/openclaw-structural.json` into the `defaultConfig` body**

Open the file in an editor; fill the `defaultConfig = { ... }` block by hand, key-by-key. Replace every secret-named leaf with `null` (per the appendix in the spec; specifically the 7 paths listed). Replace `.models.providers.vulcan.models` with `[ derivedModel ]`.

This is the bulk of the work — expect ~80-120 lines of Nix attrset.

- [ ] **Step 4: Verify Nix evaluation succeeds**

```bash
nix-instantiate --parse /etc/nixos/modules/services/openclaw-config.nix > /dev/null
echo "parse exit: $?"
```

Expected: prints `parse exit: 0` (file parses as valid Nix).

- [ ] **Step 5: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/modules/services/openclaw-config.nix'
```

- [ ] **Step 6: Shred the temp snapshot**

The snapshot has served its purpose — the structural shape now lives in `openclaw-config.nix`. Shred to remove any latent traces.

```bash
shred -u /tmp/openclaw-structural.json
```

- [ ] **Step 7: Commit (module skeleton only; not yet wired in)**

```bash
git add /etc/nixos/modules/services/openclaw-config.nix
git commit -m "feat(openclaw): add Nix-generated openclaw.json template module

Defines services.openclaw.config as a free-form attrset whose default
mirrors today's openclaw.json shape, with null sentinels at every
secret-named leaf (apiKey, token, qdrantApiKey). The .models.providers.
vulcan.models[0] entry derives from models.nix.llm.agent so changing
the agent model auto-updates openclaw.

Renders to pkgs.openclaw-config-template via an overlay; consumed by
openclaw-prepare-secrets.service (separate commit). No behaviour
change yet — module isn't imported."
```

---

## Task 5: Replace the `openclaw-config` cp block in `openclaw-prepare-secrets.service`

**Files:**
- Modify: `/etc/nixos/modules/services/openclaw-microvm.nix` (lines ~512-515 in current tree)

**Why:** This is where the new template + atomic secrets get composed into the file the guest already trusts. Every other cp block in the script stays untouched.

- [ ] **Step 1: Identify the exact lines to replace**

```bash
grep -nB 1 -A 4 '"openclaw/config"' /etc/nixos/modules/services/openclaw-microvm.nix
```

Expected: shows the block:
```
      # Copy the SOPS-decrypted openclaw config
      cp -f "${config.sops.secrets."openclaw/config".path}" "${secretsStagingDir}/openclaw-config"
      chown ${toString openclawUid}:${toString openclawGid} "${secretsStagingDir}/openclaw-config"
      chmod 0400 "${secretsStagingDir}/openclaw-config"
```

- [ ] **Step 2: Replace with the jq-merge body**

Edit `openclaw-microvm.nix` to replace **only the four cp/chown/chmod lines** identified in Step 1 (the lines starting with `# Copy the SOPS-decrypted openclaw config` down through the `chmod 0400 "${secretsStagingDir}/openclaw-config"`). **Preserve the preceding `mkdir -p "${secretsStagingDir}"` and `chmod 0755 "${secretsStagingDir}"` lines** (the two lines at the top of the script body) — the merge needs the staging dir to exist before the `mktemp --tmpdir` call.

The merge runs **as root** (the existing `systemd.services.openclaw-prepare-secrets` has no `User=` directive). That's intentional and required: it allows `--rawfile` to read `qdrant/api-key` (which is owned `root:prometheus` mode `0440`, not `openclaw:openclaw`). The final `chown ... openclaw:openclaw` + `chmod 0400` on the temp file restores the host→guest ownership contract before `mv` to the staging path. If a future reviewer tightens this service with `User=openclaw`, the qdrant read will silently break — keep this comment in the unit body.

(Apply the Phase A1 disposition: if Phase A1 chose `matches_vulcan`, the overlay line for `memorySearch.remote.apiKey` reuses `$vk`; if `is_dummy`, the line maps to the literal `"dummy-key"`; if `new-secret`, add `--rawfile mk` and adjust.)

```nix
      # ── Merge the Nix-generated structural template with atomic SOPS
      # ── secrets to produce ${secretsStagingDir}/openclaw-config.
      # The guest-side preStart in openclaw-vm.nix (lines 717-764) reads
      # the result via virtiofs and does its own jq post-processing.
      OVERLAY=$(${pkgs.jq}/bin/jq -n \
        --rawfile vk "${config.sops.secrets."openclaw/litellm-virtual-key".path}" \
        --rawfile dt "${config.sops.secrets."openclaw/discord-token".path}" \
        --rawfile gt "${config.sops.secrets."openclaw/gateway-auth-token".path}" \
        --rawfile pk "${config.sops.secrets."openclaw/perplexity-api-key".path}" \
        --rawfile qk "${config.sops.secrets."qdrant/api-key".path}" \
        --rawfile gh "${config.sops.secrets."openclaw/gh-issues-api-key".path}" \
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
      TMP=$(${pkgs.coreutils}/bin/mktemp --tmpdir="${secretsStagingDir}" openclaw-config.XXXXXX)
      trap 'rm -f "$TMP"' EXIT
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' \
        "${pkgs.openclaw-config-template}" \
        <(printf '%s' "$OVERLAY") \
        > "$TMP"
      chown ${toString openclawUid}:${toString openclawGid} "$TMP"
      chmod 0400 "$TMP"
      mv "$TMP" "${secretsStagingDir}/openclaw-config"
      trap - EXIT
```

Note: `pkgs.openclaw-config-template` is a file derivation (not a directory). `writeText` produces a single file in the store at that path.

- [ ] **Step 3: Declare the new atomic SOPS secrets in the same module**

Find the existing `sops.secrets."openclaw/config"` block (near line 206) — leave it intact for the side-by-side migration. Immediately after the existing block of openclaw secrets (after `sops.secrets."openclaw/org-db-password"`), add:

```nix
    sops.secrets."openclaw/litellm-virtual-key" = {
      owner = "openclaw";
      group = "openclaw";
      mode = "0400";
      restartUnits = [
        "openclaw-prepare-secrets.service"
        "microvm@openclaw.service"
      ];
    };
    sops.secrets."openclaw/discord-token" = {
      owner = "openclaw";
      group = "openclaw";
      mode = "0400";
      restartUnits = [
        "openclaw-prepare-secrets.service"
        "microvm@openclaw.service"
      ];
    };
    sops.secrets."openclaw/gateway-auth-token" = {
      owner = "openclaw";
      group = "openclaw";
      mode = "0400";
      restartUnits = [
        "openclaw-prepare-secrets.service"
        "microvm@openclaw.service"
      ];
    };
    sops.secrets."openclaw/gh-issues-api-key" = {
      owner = "openclaw";
      group = "openclaw";
      mode = "0400";
      restartUnits = [
        "openclaw-prepare-secrets.service"
        "microvm@openclaw.service"
      ];
    };
```

If Phase A1 chose `new-secret` for memorySearch, also add `sops.secrets."openclaw/memsearch-api-key"` with the same shape.

`openclaw/perplexity-api-key` and `qdrant/api-key` are already declared elsewhere in this file — do NOT add them again.

- [ ] **Step 4: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/modules/services/openclaw-microvm.nix'
```

- [ ] **Step 5: Commit**

```bash
git add /etc/nixos/modules/services/openclaw-microvm.nix
git commit -m "$(cat <<'EOF'
feat(openclaw): merge Nix template with atomic SOPS secrets in prepare-secrets

Replaces the single-blob cp of openclaw/config with a jq deep-merge of
the openclaw-config-template derivation (from openclaw-config.nix) and
6 atomic SOPS secrets: 4 new (litellm-virtual-key, discord-token,
gateway-auth-token, gh-issues-api-key) plus 2 reused (perplexity-api-key,
qdrant/api-key). The legacy openclaw/config secret declaration stays
in place for the side-by-side migration window.

The merge writes to the same ${secretsStagingDir}/openclaw-config
path the guest already mounts via virtiofs and post-processes in its
own preStart — the host→guest contract is preserved byte-for-byte
(ownership openclaw:openclaw, mode 0400).
EOF
)"
```

---

### Task 6: Wire `openclaw-config.nix` into `hosts/vulcan/default.nix`

**Files:**
- Modify: `/etc/nixos/hosts/vulcan/default.nix` (imports block, near line 137 — alongside the existing `../../modules/services/openclaw-microvm.nix`)

- [ ] **Step 1: Add the import line**

Open `/etc/nixos/hosts/vulcan/default.nix` and locate the existing line `../../modules/services/openclaw-microvm.nix`. Insert a new import line directly above it:

```nix
    ../../modules/services/openclaw-config.nix
    ../../modules/services/openclaw-microvm.nix
```

The order matters only for human readability — Nix evaluates imports as an unordered set. Putting `openclaw-config.nix` above `openclaw-microvm.nix` groups them visually and makes the dependency direction (microvm depends on config's `pkgs.openclaw-config-template` overlay) obvious to a reader.

- [ ] **Step 2: Format**

```bash
nix-shell -p nixfmt-rfc-style --run 'nixfmt /etc/nixos/hosts/vulcan/default.nix'
```

- [ ] **Step 3: Evaluate the flake (no build, no switch) to catch syntax/eval errors fast**

```bash
nix flake check --no-build /etc/nixos 2>&1 | tail -40
```

Expected: no errors. If `pkgs.openclaw-config-template` is undefined, the overlay in `openclaw-config.nix` is wired incorrectly — revisit Task 4 Step 2 before continuing.

- [ ] **Step 4: Commit**

```bash
git add /etc/nixos/hosts/vulcan/default.nix
git commit -m "$(cat <<'EOF'
chore(vulcan): import openclaw-config module

Wires the new openclaw-config.nix into vulcan's import list so the
pkgs.openclaw-config-template overlay and services.openclaw.config
option become live. No build yet — Task 7 does the dry build with
structural verification.
EOF
)"
```

---

### Task 7: Phase C — build host, dry-render template, structural diff vs current `openclaw.json`

**Goal:** Prove the Nix-rendered structural template has the same shape (key set + array lengths) as the currently-running config, *without* decrypting any secret. This is the gate before Phase B.

**Files:**
- No code changes; this task only runs commands.

- [ ] **Step 1: Take the host build lock**

```bash
touch /etc/nixos/.nixos-build
trap 'rm -f /etc/nixos/.nixos-build' EXIT
```

(If the file already exists, wait up to 10 min per the project convention; do not blow it away.)

- [ ] **Step 2: Build the host (no switch)**

```bash
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' 2>&1 | tail -40
```

Expected: build succeeds. The `./result` symlink in /etc/nixos points at the new system closure. **Do not switch yet.**

- [ ] **Step 3: Extract the template store path from the built system closure**

The Nix overlay puts `openclaw-config-template` into the host's `pkgs` set, but `nixosConfigurations.<host>.pkgs.<attr>` is not always reachable via the flake CLI (depends on flake version + `_module.args.pkgs` exposure). The reliable approach: the prepare-secrets unit body contains `${pkgs.openclaw-config-template}`, which the system-closure renderer materializes into a `/nix/store/...` path inside the rendered unit file under `./result/etc/systemd/system/openclaw-prepare-secrets.service`. Grep that path out:

```bash
TPL=$(grep -oE '/nix/store/[a-z0-9]+-openclaw-config-template' \
        /etc/nixos/result/etc/systemd/system/openclaw-prepare-secrets.service \
      | head -1)
echo "Template path: $TPL"
test -f "$TPL" && echo "OK: template is a regular file"
```

Expected: `$TPL` is `/nix/store/<hash>-openclaw-config-template` and the file exists. This file is world-readable and contains *no secrets* (placeholders only, e.g. structural keys plus the literal token `@VAULT@` or empty strings where secrets will be merged — depending on which placeholder convention Task 4 finalized).

If `grep` returns empty, the unit body in Step 2's build doesn't reference `pkgs.openclaw-config-template` — Task 5 Step 2 was not applied. Fix and re-build before continuing.

If the template contains anything secret-looking, **STOP**. Task 4 produced the wrong derivation; fix before proceeding.

- [ ] **Step 4: Confirm template has no secret-shaped leaves**

Use the same `assert_no_secret_leaf` helper from Task 2 Step 1 (re-export `SECRET_RE` if you've started a new shell):

```bash
export SECRET_RE='([Aa]pi[Kk]ey|[Tt]oken|[Pp]assword|[Pp]assphrase|[Ss]ecret|[Ss]ecretKey|[Pp]sk|[Bb]earer)'
assert_no_secret_leaf() {
  jq --arg re "$SECRET_RE" -e '
    [paths(scalars) as $p
      | select(($p[-1] | tostring | test($re)) and (getpath($p) != null))]
    | length == 0
  ' "$1" >/dev/null || { echo "FATAL: $1 still contains a non-null secret-named leaf" >&2; return 1; }
}
assert_no_secret_leaf "$TPL" && echo "OK: template has no non-null secret-named leaves"
```

If this assertion fails, **STOP** and review Task 4 — the template must contain *only* `null` placeholders for every secret leaf, never a real credential.

- [ ] **Step 5: Snapshot the live openclaw.json key set (sanitized)**

The guest VM holds the live config at `/var/lib/openclaw/.openclaw/openclaw.json` (mode 0400 openclaw:openclaw). Probe it from the host via SSH using the openclaw probe key, applying the spec's canonical `SECRET_RE` *before* anything leaves the SSH pipe. We `--arg re` the regex through the ssh invocation so there's exactly one canonical regex on the host side:

```bash
LIVE_KEYS=$(mktemp)
ssh -i /root/.ssh/openclaw-probe -o StrictHostKeyChecking=no openclaw@10.99.0.2 \
  "jq --arg re '$SECRET_RE' '
    def strip_secrets:
      walk(if type == \"object\" then
        with_entries(select(
          (.key | type == \"string\") and
          (.key | test(\$re) | not)
        ))
      else . end);
    strip_secrets | [paths | join(\".\")] | sort | .[]
  ' /var/lib/openclaw/.openclaw/openclaw.json" > "$LIVE_KEYS"

wc -l "$LIVE_KEYS"
```

Expected: a couple hundred dotted paths, e.g. `models.providers.vulcan.models.0.name`, `gateway.host`, etc. Each path is structural, never a credential.

- [ ] **Step 6: Snapshot the template key set (same sanitization)**

```bash
TPL_KEYS=$(mktemp)
jq --arg re "$SECRET_RE" '
  def strip_secrets:
    walk(if type == "object" then
      with_entries(select(
        (.key | type == "string") and
        (.key | test($re) | not)
      ))
    else . end);
  strip_secrets | [paths | join(".")] | sort | .[]
' "$TPL" > "$TPL_KEYS"

wc -l "$TPL_KEYS"
```

- [ ] **Step 7: Diff the key sets**

```bash
diff -u "$LIVE_KEYS" "$TPL_KEYS"
```

**Expected:** empty diff (exit 0). 

If there are missing paths in the template (lines starting with `-`), the Nix `defaultConfig` is missing fields the current openclaw.json relies on. Add them to `openclaw-config.nix` and re-run from Step 2.

If there are *extra* paths in the template (lines starting with `+`), the Nix model adds structure the live config doesn't have. That's allowed but should be intentional — check each addition is a known new field, not a typo.

Array-length differences manifest as path-suffix differences (e.g. live has `.models.providers.vulcan.models.0..2`, template has `.0..1`). The spec's jq deep-merge replaces arrays wholesale, so the template's array length wins at merge time — that's intentional, but verify it matches what `models.nix` was intended to produce.

- [ ] **Step 8: Compare a few non-secret leaf values for sanity**

Don't dump full values; instead check a handful of structural fields that should never differ:

```bash
ssh -i /root/.ssh/openclaw-probe -o StrictHostKeyChecking=no openclaw@10.99.0.2 \
  'jq -r ".gateway.host, .gateway.port, .models.providers.vulcan.url" /var/lib/openclaw/.openclaw/openclaw.json'

jq -r '.gateway.host, .gateway.port, .models.providers.vulcan.url' "$TPL"
```

Both invocations should print the same three lines. If they diverge, `openclaw-config.nix`'s `defaultConfig` has a typo or a wrong default.

- [ ] **Step 9: Clean up the lock and temp files**

```bash
rm -f /etc/nixos/.nixos-build
rm -f "$LIVE_KEYS" "$TPL_KEYS"
trap - EXIT
```

- [ ] **Step 10: Record Phase C result in the plan checkbox below**

After this task passes, mark the Phase C row in the migration-plan table at the top of the spec as ✅ done. (The actual checkbox is in the plan, not a code change — just a TodoWrite update from the controller.)

**No commit:** Phase C produces no repo changes; it only validates the work from Tasks 1-6.

---

### Task 8: Phase B handoff — STOP, hand the new SOPS secrets to the user

**This is the autonomous-execution stop point.** The next task is run by the user, not me. After verification I print exact instructions and wait.

**Files:**
- User-modified: `/etc/nixos/secrets/secrets.yaml` (encrypted; I never decrypt, never display).

- [ ] **Step 1: Print the exact secret paths the user must add**

In the chat (not in a file), tell the user:

> Phase C structural validation passed. To proceed to Phase D (rebuild + switch), please open the encrypted secrets file with:
>
> ```bash
> sops /etc/nixos/secrets/secrets.yaml
> ```
>
> and add **four new keys** under the existing `openclaw:` subtree:
>
> 1. `litellm-virtual-key` — paste the value currently inside `openclaw/config` under the JSON path `.models.providers.vulcan.apiKey`. You can copy it from the same sops session before adding the new key, without ever displaying it in the terminal.
> 2. `discord-token` — paste the value at `.channels.discord.token`.
> 3. `gateway-auth-token` — paste the value at `.gateway.auth.token`.
> 4. `gh-issues-api-key` — paste the value at `.skills.entries.gh-issues.apiKey`.
>
> Existing keys to **reuse, not duplicate**:
> - `openclaw/perplexity-api-key` (already present; mapped to `.plugins.entries.brave.config.webSearch.apiKey`)
> - `qdrant/api-key` (already present; mapped to `.plugins.entries.memory-qdrant.config.qdrantApiKey`)
>
> Conditional fifth key (only if Phase A1 produced the `new-secret` result):
> - `openclaw/memsearch-api-key` — paste the value at `.agents.defaults.memorySearch.remote.apiKey`.
>
> Save and exit sops. Tell me "secrets added" when done.

- [ ] **Step 2: Wait for the user's confirmation**

Do not proceed until the user signals completion in chat. Do not poll the file. Do not decrypt to verify.

- [ ] **Step 3: After user confirms, verify ENC[ markers without decryption**

These four credentials are all expected to be **single-line strings** (a virtual key, a Discord bot token, an HMAC-style auth token, and a GitHub PAT). For single-line tokens, the `ENC[` marker appears on the same line as the YAML key. If sops ever rewrites a value as a block scalar (`|` or `>` indicator), this grep would return 0 even though the encryption succeeded — so we also gate the success message on a follow-up check that the key appears at all.

```bash
for k in litellm-virtual-key discord-token gateway-auth-token gh-issues-api-key; do
  enc=$(grep -c "^[[:space:]]*${k}:[[:space:]]*ENC\[" /etc/nixos/secrets/secrets.yaml)
  any=$(grep -c "^[[:space:]]*${k}:" /etc/nixos/secrets/secrets.yaml)
  if [ "$enc" -eq 1 ]; then
    echo "OK: openclaw/${k} present and encrypted"
  elif [ "$any" -ge 1 ] && [ "$enc" -eq 0 ]; then
    echo "FATAL: openclaw/${k} present but NOT encrypted — STOP and re-edit via sops" >&2
    exit 1
  else
    echo "FATAL: openclaw/${k} missing from secrets.yaml — STOP and tell the user" >&2
    exit 1
  fi
done
```

Expected: four `OK: openclaw/<key> present and encrypted` lines. Any other output halts execution.

- [ ] **Step 4: Commit the updated secrets.yaml**

```bash
git add /etc/nixos/secrets/secrets.yaml
git commit -m "$(cat <<'EOF'
chore(secrets): add atomic openclaw secrets

Adds four new SOPS keys (litellm-virtual-key, discord-token,
gateway-auth-token, gh-issues-api-key) carved out of the legacy
openclaw/config blob. The legacy blob remains in place for the
side-by-side migration window — Phase E (future session) will
remove it after the new path bakes.
EOF
)"
```

**No code changes in this task** — only a secrets.yaml commit.

---

### Task 9: Phase D — `nixos-rebuild switch` after user-driven Phase B

**Pre-condition:** Task 8 complete; user has added the four new SOPS keys and `git status` shows secrets.yaml committed.

**Files:**
- No code changes in this task — only rebuild + verification commands.

- [ ] **Step 1: Take the build lock**

```bash
touch /etc/nixos/.nixos-build
trap 'rm -f /etc/nixos/.nixos-build' EXIT
```

- [ ] **Step 2: Switch**

```bash
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -60
```

Expected: switch completes with no failed units. If `openclaw-prepare-secrets.service` fails, see Step 4's troubleshooting.

- [ ] **Step 3: Verify the new SOPS secrets are deployed (metadata only)**

```bash
ls -la /run/secrets/openclaw/litellm-virtual-key
ls -la /run/secrets/openclaw/discord-token
ls -la /run/secrets/openclaw/gateway-auth-token
ls -la /run/secrets/openclaw/gh-issues-api-key
```

Each must show ownership `openclaw:openclaw` and mode `0400`. **Do not `cat` these files.**

- [ ] **Step 4: Verify `openclaw-prepare-secrets.service` succeeded**

```bash
systemctl status openclaw-prepare-secrets.service --no-pager | head -20
journalctl -u openclaw-prepare-secrets.service -n 30 --no-pager
```

Expected: green `active (exited)` with `Process: ... status=0/SUCCESS`. The journal should show the `jq -s '.[0] * .[1]'` invocation completing without error.

If it failed:
- Check `/var/lib/microvms/openclaw/secrets/` for a leftover `openclaw-config.XXXXXX` tempfile (the trap should have cleaned it; if present, something interrupted mid-merge).
- Check the journal for jq error messages (likely a malformed overlay rawfile path or a typo'd sops key).
- Fix and re-run: `sudo systemctl restart openclaw-prepare-secrets.service`.

- [ ] **Step 5: Verify the merged config landed on the staging path (size only)**

```bash
ls -la /var/lib/microvms/openclaw/secrets/openclaw-config
stat -c '%s %U:%G %a' /var/lib/microvms/openclaw/secrets/openclaw-config
```

Expected: ownership `openclaw:openclaw`, mode `0400`, size in the 4–16 KB range (matches the live config order of magnitude). **Do not `cat` this file.**

- [ ] **Step 6: Verify the openclaw microVM came up clean**

```bash
systemctl status microvm@openclaw.service --no-pager | head -15
```

Expected: `active (running)`.

- [ ] **Step 7: SSH into the guest and confirm post-processed openclaw.json**

```bash
ssh -i /root/.ssh/openclaw-probe -o StrictHostKeyChecking=no openclaw@10.99.0.2 \
  'stat -c "%s %U:%G %a" /var/lib/openclaw/.openclaw/openclaw.json'
```

Expected: size > 4 KB, owner `openclaw:openclaw`, mode `0400`.

- [ ] **Step 8: Release the lock**

```bash
rm -f /etc/nixos/.nixos-build
trap - EXIT
```

**No commit:** this task changes runtime state only.

---

### Task 10: Phase D verification — health checks + functional smoke test

**Pre-condition:** Task 9 complete; microVM is up.

**Files:**
- No code changes; verification commands only.

- [ ] **Step 1: Wait one health-check tick (≤5 min) and read the canary metric**

```bash
# OnCalendar for openclaw-canary.timer is *:0/5, so within 5 min there's a fresh metric.
sleep 60
cat /var/lib/prometheus-node-exporter-textfiles/openclaw_canary.prom 2>/dev/null \
  | grep -E '^openclaw_canary_(ok|last_success_timestamp_seconds)'
```

Expected: `openclaw_canary_ok 1` and a `last_success_timestamp_seconds` within the last 5 min.

- [ ] **Step 2: Read the mcporter check metric**

```bash
cat /var/lib/prometheus-node-exporter-textfiles/openclaw_mcporter.prom 2>/dev/null \
  | grep -E '^openclaw_mcporter_(ok|servers_up|servers_total)'
```

Expected: `openclaw_mcporter_ok 1`. `servers_up` should equal `servers_total`. If `servers_up < servers_total`, one of the MCP servers is misconfigured — likely a stale env (LiteLLM key, Qdrant key, GitHub PAT). Check `journalctl -u openclaw-canary.service -n 50 --no-pager` for which server failed.

- [ ] **Step 3: Run a small Claw round-trip from the host**

```bash
ssh -i /root/.ssh/openclaw-probe -o StrictHostKeyChecking=no openclaw@10.99.0.2 \
  'curl -fsS --max-time 30 -H "Authorization: Bearer $(jq -r .gateway.auth.token /var/lib/openclaw/.openclaw/openclaw.json)" \
    http://127.0.0.1:9080/v1/health' 2>&1 | head -10
```

Expected: HTTP 200 with a healthy JSON body. The `jq` extraction happens *inside* the guest VM and the token never crosses the SSH pipe — only the response body does, which is non-secret.

If you see a 401, the new `gateway-auth-token` doesn't match what Claw was rebuilt with; check that Task 8 Step 1 instructions had the user copy from the same source.

- [ ] **Step 4: Confirm Hermes bridge is reachable from the guest**

```bash
ssh -i /root/.ssh/openclaw-probe -o StrictHostKeyChecking=no openclaw@10.99.0.2 \
  'curl -fsS --max-time 10 http://127.0.0.1:9081/sse -o /dev/null -w "%{http_code}\n"'
```

Expected: `200` (SSE endpoints respond 200 with `text/event-stream`). The two-stage DNAT chain (Task 5 of the earlier hermes-mcp plan) routes 9081 through the bridge gateway to the host.

- [ ] **Step 5: Inspect self-heal logs for false alarms**

```bash
journalctl -u openclaw-self-heal.service -n 20 --no-pager
journalctl -u hermes-self-heal.service -n 20 --no-pager
```

Expected: no recent restart actions. If either watchdog has fired, it sees a metric flag — go back to Step 1 or 2.

**No commit:** verification only.

---

### Task 11: Post-deploy bookkeeping — memory + closing notes

**Files:**
- Update: `/home/johnw/.claude/projects/-etc-nixos/memory/project_openclaw_migration.md` (existing)
- Update: `/home/johnw/.claude/projects/-etc-nixos/memory/MEMORY.md` if a new memory file is added

- [ ] **Step 1: Append a refactor-completion note to the existing migration memory**

Open `/home/johnw/.claude/projects/-etc-nixos/memory/project_openclaw_migration.md` and add a dated section:

```markdown
## 2026-05-14 — config refactor complete

The single SOPS-encrypted openclaw/config blob has been replaced by a
Nix-generated structural template (`pkgs.openclaw-config-template`,
defined in `modules/services/openclaw-config.nix`) merged with 4 new
atomic SOPS secrets at host build time. Structural keys (gateway,
models, plugins, etc.) are now reviewable in git via `openclaw-config.nix`
and tunable with one-line Nix edits + `nixos-rebuild switch`. Models
flow from `models.nix` through a `derivedModel` adapter into the
`.models.providers.vulcan.models[]` array.

Legacy `openclaw/config` SOPS key remains in place for one bake period —
Phase E (a future session) removes it.

Reference paths:
- Module: /etc/nixos/modules/services/openclaw-config.nix
- Adapter: /etc/nixos/models.nix (new optional fields: contextWindow, maxTokens, api, reasoning, input)
- Merge site: /etc/nixos/modules/services/openclaw-microvm.nix (openclaw-prepare-secrets.service)
- Spec: /etc/nixos/docs/superpowers/specs/2026-05-14-openclaw-nix-config-design.md
- Plan: /etc/nixos/docs/superpowers/plans/2026-05-14-openclaw-nix-config.md
```

- [ ] **Step 2: Final repo commit (optional)**

If any small polish was made during verification (e.g. a typo in a comment, a missed `nixfmt`), commit it as a single follow-up:

```bash
git status
# review any remaining changes
git add <files>
git commit -m "$(cat <<'EOF'
chore(openclaw-config): post-deploy polish

Minor follow-ups after Phase D verification: <list>.
EOF
)"
```

If `git status` is clean, skip this step.

- [ ] **Step 3: Mark the plan complete**

In TodoWrite, mark all task rows complete. Announce to the user:

> Phase D complete. The openclaw config refactor is live. The legacy openclaw/config SOPS key is still in secrets.yaml as a fallback — Phase E (its removal) is intentionally deferred to a future session so we get a multi-day bake period.

---

## What this plan covers

| Phase | Owner | Description | Task(s) |
|-------|-------|-------------|---------|
| A1    | me    | Pre-execution metadata check on `memorySearch.remote.apiKey` | 1 |
| A2    | me    | Snapshot structural JSON, build adapter + module, wire merge | 2–6 |
| C     | me    | Build host, dry-render template, structural diff vs current | 7 |
| B     | user  | sops edit to add 4 new atomic secrets | 8 |
| D     | me    | `nixos-rebuild switch` + runtime verification | 9–10 |
| —     | me    | Bookkeeping (memory + closing notes) | 11 |

## What this plan explicitly defers

- **Phase E** — removal of the legacy `openclaw/config` SOPS key from `secrets.yaml`. Deferred to allow a multi-day bake period during which the legacy blob still exists as a manual rollback target.
- **Refactoring hermes-vm or stock-trader configs** in the same Nix-template style. Out of scope; would be a follow-up plan.
- **A nixos VM-test that asserts openclaw.json schema completeness**. Useful regression guard but adds a build-time dep on a quemu-aarch64 boot; tracked as a future test infra task.
- **New openclaw features** (additional providers, model fallback chains). Out of scope.

## Rollback plan (if Phase D fails)

If `openclaw-prepare-secrets.service` fails to merge or microvm@openclaw fails to start after Task 9:

1. `sudo nixos-rebuild switch --rollback` — flip back to the previous generation, which still uses `openclaw/config` directly.
2. The legacy SOPS key is intact (we did not remove it in Phase B), so the previous generation will boot openclaw with the old config path unchanged.
3. Save the failed-generation journal (`journalctl --boot=-1 -u openclaw-prepare-secrets.service > /tmp/openclaw-prepare-secrets-failure.log`) for diagnosis.
4. Repair the module (likely a jq filter typo or an unexpected key name in the live JSON the template doesn't model), re-run from Task 7 Step 2.

## Execution mode

Per the calling session's grant: I (Claude) execute Tasks 1–7 autonomously using subagent-driven development, then **STOP at Task 8 Step 1** and surface the secret-addition instructions to the user. After the user confirms Task 8 Step 2 is done, I proceed with Tasks 8 Step 3 onward through Task 11.

I never decrypt secrets.yaml. I never `cat` `openclaw.json` or `openclaw-config`. Every command that walks JSON pre-strips secret-named keys through the regex-based jq filter from the spec, with the post-strip assertion enforced before display.