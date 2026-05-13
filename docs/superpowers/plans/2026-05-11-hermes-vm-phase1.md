# Hermes Agent Phase 1 — Standalone microVM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Hermes Agent (Nous Research) on vulcan as a standalone
autonomous AI agent, isolated in a dedicated microVM with no integration to
the existing OpenClaw stack. Interaction surface for Phase 1 is the in-VM
`hermes` TUI plus a new Discord bot scoped to a dedicated channel.

**Architecture:** Mirror the proven OpenClaw microVM pattern. New microVM
`hermes-vm` sits on its own private `/30` bridge (`10.99.1.0/30`, host at
`10.99.1.1`, VM at `10.99.1.2`). Inside the VM, the official upstream
`github:NousResearch/hermes-agent` flake's `nixosModules.default` runs
Hermes as a fully declarative systemd service — `hermes setup`,
`hermes config set`, and `hermes gateway install` are all blocked at
runtime by the module's `.managed` marker. Secrets are delivered through
SOPS-nix into a single `environmentFiles` entry. Persistent state lives
at the host's `/var/lib/hermes/` directory (tmpfiles `d`, preserves
contents) and is virtio-fs shared into the VM. Outbound egress is
restricted via nftables to model API destinations + Discord + DNS.
Phase 1 deploys **a second Discord bot** scoped to a dedicated channel
disjoint from OpenClaw's — `DISCORD_ALLOWED_CHANNELS` is the gate that
keeps Hermes out of channels OpenClaw already serves. WhatsApp stays
bound to OpenClaw; Phase 2 covers any cross-bot bridge or migration.

**Tech Stack:** NixOS 25.11, microvm.nix (host module), sops-nix, Nous
Research Hermes Agent v0.x upstream flake, virtio-fs, Discord Bot API
(separate application from OpenClaw's). No new system services on the
host other than `microvm@hermes.service` and the matching
`install-microvm-hermes.service`.

---

## Why this approach

You explicitly chose (in the brainstorm preceding this plan):

1. **Dedicated microVM** for Hermes (vs. host-level or co-tenanting in the
   OpenClaw VM). Kernel isolation; same security posture you already
   trust for OpenClaw.
2. **Official upstream flake** (vs. community flake or hand-packaging).
   Tracks upstream security fixes via `nix flake update hermes-agent`.
3. **Standalone first** (vs. bridging from day one). Lets you live with
   Hermes for a while and shape the Phase 2 bridge plan based on actual
   usage patterns.
4. **Public-framework OpenClaw** — your stack is a NixOS deployment of
   the public NousResearch/openclaw framework, so future migrations and
   ClawMem federation are both options later.

The OpenClaw `/30` bridge (`10.99.0.0/30`) only fits one VM. Hermes gets
its own parallel bridge subnet so removing or relocating either VM
doesn't disrupt the other — and so the existing `openclaw-dnat` and
`openclaw-egress` nftables tables stay untouched.

## File Structure

**Modified files:**

- `/etc/nixos/flake.nix` — adds `inputs.hermes-agent` and threads it into
  the system module list.
- `/etc/nixos/hosts/vulcan/default.nix` — imports the new
  `modules/services/hermes-microvm.nix`.
- `/etc/nixos/secrets/secrets.yaml` — new top-level `hermes:` block with
  three sub-keys (bot token, allowlist, model API key). Driven by `sops`
  editor (you).
- `/etc/nixos/docs/ports.txt` — registers `22 10.99.1.2 Hermes microVM
  sshd (probe-only, Phase 2)` even though sshd isn't enabled this phase,
  to reserve the slot.

**Created files:**

- `/etc/nixos/modules/services/hermes-microvm.nix` — parent module.
  Defines the bridge, nftables egress, tmpfiles for `/var/lib/hermes`,
  microvm.nix declaration with virtio-fs shares.
- `/etc/nixos/modules/services/hermes-vm.nix` — guest config.
  Networking, Vulcan CA bundle, SOPS-nix wiring, `services.hermes-agent`
  options block.

**No changes to:**

- `openclaw-microvm.nix`, `openclaw-vm.nix`, `openclaw-nightly-report.*`,
  `openclaw-self-heal.nix`. Hermes is operationally orthogonal in Phase 1.
- `secrets.yaml` keys outside the new `hermes:` block.
- ZFS layout — `/var/lib/hermes` is a regular host directory under
  tmpfiles `d` (matching OpenClaw). If/when you want snapshotting,
  convert to a ZFS dataset later by creating one at `tank/hermes` and
  mounting it at `/var/lib/hermes` — module config doesn't change.

## Decisions locked in

- **VM IP:** `10.99.1.2` (host bridge `10.99.1.1`, subnet `10.99.1.0/30`).
- **VM hostname:** `hermes-vm`.
- **Hermes runtime UID/GID:** `932` (next free slot — `getent passwd 917..931`
  confirmed all occupied: shlink/redis-shlink/redis-openproject/openproject/
  zimit/searx/redis-searxng/open-webui). Re-verify with
  `getent passwd 932 && getent group 932` before Task 4; both should be empty.
- **State directory (host + guest):** `/var/lib/hermes`, mode `0750`,
  owner `hermes:hermes`.
- **Memory/CPU sizing:** 4 vCPU, 4 GiB RAM. Matches OpenClaw; adjust if
  Hermes proves heavier under sustained skill-loop work.
- **Discord only, second bot.** A new Discord application distinct from
  OpenClaw's. The bot is scoped via `DISCORD_ALLOWED_CHANNELS` to a
  dedicated channel (Hermes-only) so it never sees OpenClaw's channel
  traffic. `DISCORD_REQUIRE_MENTION=true` keeps it quiet unless
  explicitly @-mentioned. No WhatsApp (number-collision with OpenClaw).
- **Model provider:** OpenRouter via your existing `hera/*` route, since
  CLAUDE memory says to always use hera/* routes. You'll set
  `OPENROUTER_API_KEY` to the hera-routed key and `OPENROUTER_BASE_URL`
  to the hera proxy. Confirm during Task 3.
- **Version pin:** the first deploy uses whatever `nix flake update`
  resolves; you commit `flake.lock` so it's reproducible. Document
  the cadence (Section "Risks") rather than pinning a specific tag
  upfront — the v0.13.0 release page returned 404 during research, so
  blindly pinning is risky. Use whatever the lock resolves and treat
  upgrades as a quarterly review.
- **No sshd inside the VM in Phase 1.** Phase 2 adds it for the
  nightly-report probe. Keeps the attack surface minimal initially.
- **No DNAT** (no inbound TCP from host). Hermes only initiates outbound
  (model API, Discord gateway WebSocket, MCP servers). DNS goes via the host
  bridge (10.99.1.1) like OpenClaw's VM.

---

## Task 1: Discord bot creation (user-driven prerequisites)

**Files:** None — this task is offline preparation in the Discord
Developer Portal and your Discord server.

The `sops`-encrypted secret in Task 3 needs several values you can't
fetch programmatically: a fresh Discord bot token (distinct from
OpenClaw's), your Discord user ID for the allowlist, the dedicated
channel ID Hermes will live in, and a model API key/URL pair.

- [ ] **Step 1: Create a new Discord application**

In a browser, sign in at https://discord.com/developers/applications:
1. Click **New Application**, name it `Hermes (vulcan)` (or any name
   that distinguishes it from your OpenClaw application).
2. In the left nav, go to **Bot** → **Add Bot** (if not auto-created)
   → **Reset Token** → copy the bot token. It looks like
   `MTQ4...` (~70 chars). Treat it like a password.
3. On the same Bot page, scroll to **Privileged Gateway Intents** and
   toggle ON:
   - **Server Members Intent**
   - **Message Content Intent** (without this, Hermes receives empty
     message text and can't reason about what you said)
4. Optionally toggle OFF **Public Bot** so only you can invite this
   bot to servers.

- [ ] **Step 2: Generate the OAuth2 invite URL and invite the bot**

In the left nav: **OAuth2** → **URL Generator**.
1. **Scopes**: tick `bot` and `applications.commands`.
2. **Bot Permissions**: tick the minimal set — *View Channels*,
   *Send Messages*, *Embed Links*, *Attach Files*, *Read Message
   History*. The integer should land on `274878286912` (matches the
   upstream Hermes Discord docs recommendation).
3. Copy the generated URL at the bottom, open it in another tab, pick
   the Discord server you want Hermes in, and authorize. **Important:
   do NOT pick a server where OpenClaw is active unless you also set
   `DISCORD_ALLOWED_CHANNELS` to a Hermes-only channel in Task 3.**

- [ ] **Step 3: Create a dedicated channel for Hermes**

In that Discord server, create a new text channel — name it whatever
you like (e.g. `#hermes`). The bot needs at least *View Channel* and
*Send Messages* permission there; the role auto-created when the bot
joined should already grant this guild-wide.

If you already have other Discord bots (OpenClaw or any of its
agents), restrict that channel's access to the new bot's role only,
or restrict the OTHER bots' roles away from this channel. Phase 1
relies on channel scoping rather than role-allowlisting because
allowlists fan out into DM auth (per Hermes docs: *"a user with an
allowed role in any shared server is authorized in DMs too"*).

- [ ] **Step 4: Capture your Discord user ID and the channel ID**

In Discord (desktop or web):
1. Settings → Advanced → **Developer Mode** ON.
2. Right-click your own avatar anywhere → **Copy User ID**. You get a
   17–19 digit integer. This goes into `DISCORD_ALLOWED_USERS`.
3. Right-click the new `#hermes` channel → **Copy Channel ID**. Same
   format. This goes into `DISCORD_ALLOWED_CHANNELS` and
   `DISCORD_HOME_CHANNEL`.

If you want anyone else to talk to Hermes, repeat step 2 for each
user — `DISCORD_ALLOWED_USERS` is comma-separated.

- [ ] **Step 5: Confirm the model API plan**

Decide:
- Use the existing `hera/*` route — the `OPENROUTER_BASE_URL` and key
  Hermes will read are the same ones your other agents use. Per
  `feedback_use_hera_route.md` memory, never override to `anthropic/*`.
- Alternatively, dedicate a fresh OpenRouter key just for Hermes so its
  usage is separable in billing. Either is fine — choose now so Task 3
  captures the right value.

Capture the API key and base URL you want to commit to `sops`. **Do not
paste them anywhere yet.**

- [ ] **Step 6: Tell the controller you're ready for Task 2**

When all four values are in hand (bot token, your Discord user ID,
the Hermes-only channel ID, model API key + base URL), tell the
controller to proceed. The controller will run Task 2 next.

---

## Task 2: Add Hermes Agent flake input

**Files:**

- Modify: `/etc/nixos/flake.nix`

- [ ] **Step 1: Read the existing inputs block**

```bash
grep -n "inputs = {\|inputs\.\|llm-agents" /etc/nixos/flake.nix | head -20
```

Find the existing inputs declaration. The `llm-agents` entry around
L47 is the closest analog — Hermes follows the same shape.

- [ ] **Step 2: Add the Hermes Agent input**

Insert into the `inputs = { … };` block, alphabetized near
`hermes-agent` would fit (around the `home-manager` line). Use:

```nix
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
```

- [ ] **Step 3: Do NOT thread the input into the host module list**

Resist the temptation to add `inputs.hermes-agent.nixosModules.default`
to the host's `modules = [ ... ];` list. The Hermes module declares
`users.users.hermes` and other side-effects (via `createUser = true`
default) that would conflict with the `users.users.hermes` block in
`hermes-microvm.nix`. The guest microVM imports the Hermes module
directly via `hermes-vm.nix` — that's the only place it should be
imported. The host just exposes the flake input so the guest can
reach it via `inputs.hermes-agent`.

- [ ] **Step 4: Resolve the lock**

`nix flake lock --update-input <name>` is deprecated in Nix 2.19+; the
modern form is:

```bash
sudo nix flake update hermes-agent --flake /etc/nixos 2>&1 | tail -10
```

If the host's Nix version doesn't yet support the per-input form, fall
back to `sudo nix flake update --flake /etc/nixos` to refresh every
input (you'll want to review the full lock diff before committing).

Expected: `flake.lock` gains a `nodes.hermes-agent` entry. Inspect:

```bash
git -C /etc/nixos diff flake.lock | head -40
```

Verify the `hermes-agent` node (and any of its non-nixpkgs-following
dependencies) actually changed. If many unrelated inputs changed,
either roll back and use the per-input form, or only stage the
hermes-agent and nixpkgs-relevant hunks of the lock file.

- [ ] **Step 5: Smoke-test the flake evaluates**

```bash
nix flake check /etc/nixos --no-build 2>&1 | tail -20
```

If the flake has eval errors, fix them now rather than at rebuild time
when you've already touched secrets. Expected: no errors, possibly
warnings.

- [ ] **Step 6: Commit**

```bash
git -C /etc/nixos add flake.nix flake.lock
git -C /etc/nixos commit -m "$(cat <<'EOF'
feat(flake): add Hermes Agent input (NousResearch/hermes-agent)

Wires the upstream NixOS module into the vulcan system module list
so a follow-up commit can enable services.hermes-agent.* inside a
dedicated microVM. No services are activated by this commit on its
own — just makes the options visible.

flake.lock pins the input as resolved by nix flake update; review
the lock diff for surprises before rebuild. Upgrade cadence: run
nix flake update hermes-agent quarterly or when upstream announces
a security fix that affects gateway code paths.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: SOPS secrets block (user drives the editor)

**Files:**

- Modify: `/etc/nixos/secrets/secrets.yaml` (gitignored on this host;
  no commit needed)

- [ ] **Step 1: Open the secrets file in `sops`**

```bash
sops /etc/nixos/secrets/secrets.yaml
```

- [ ] **Step 2: Add the hermes block**

The existing `openclaw:` block sits around L113 with sub-keys (`config`,
`gcp-oauth-keys`, `home-assistant-token`, `probe-ssh-private-key`, etc.).
Add a new top-level block, alphabetically positioned near the other
agents (after `hermes-mcp-tokens` if present, otherwise next to
`openclaw:`). Indent with 4 spaces under the parent key. The body should
be a single multiline string (Hermes consumes it as an `environmentFile`,
so it must be `KEY=value` lines):

```yaml
hermes:
    env: |
        # OpenRouter via hera/* route (see feedback_use_hera_route.md)
        OPENROUTER_API_KEY=sk-or-v1-...your-key-here...
        OPENROUTER_BASE_URL=https://hera.vulcan.lan/v1
        # Discord — second bot, distinct from OpenClaw's. Scope to a
        # dedicated channel so it never sees OpenClaw's traffic.
        DISCORD_BOT_TOKEN=MTQ4...your-discord-bot-token...
        DISCORD_ALLOWED_USERS=YOUR_DISCORD_USER_ID
        DISCORD_ALLOWED_CHANNELS=YOUR_HERMES_CHANNEL_ID
        DISCORD_HOME_CHANNEL=YOUR_HERMES_CHANNEL_ID
        # Defense-in-depth: only respond when explicitly @-mentioned
        # (Hermes won't react to bare-text in the channel). Combined
        # with DISCORD_ALLOWED_CHANNELS scoping, this prevents
        # accidental cross-talk with any other bot in the same guild.
        DISCORD_REQUIRE_MENTION=true
        # Block @everyone / role pings in Hermes's own output:
        DISCORD_ALLOW_MENTION_EVERYONE=false
        DISCORD_ALLOW_MENTION_ROLES=false
        # Optional but recommended hardening:
        HERMES_LOG_LEVEL=INFO
        HERMES_REDACTION=enabled
```

Replace the placeholders with the real values from Task 1. Save and
exit `sops`.

- [ ] **Step 3: Verify the encrypted form landed correctly**

```bash
grep -n "^hermes:\|env: ENC" /etc/nixos/secrets/secrets.yaml | head -3
```

Expected: a `hermes:` line followed by `env: ENC[AES256_GCM,…`. The
presence of `ENC[` is the proof of encryption. **DO NOT** `sops -d`
to verify the cleartext content — forbidden by CLAUDE.md.

- [ ] **Step 4: Tell the controller you're done**

The controller will continue with Task 4 once you confirm the
`hermes.env` sub-key is encrypted in place.

---

## Task 4: Create the host-side parent module (`hermes-microvm.nix`)

**Files:**

- Create: `/etc/nixos/modules/services/hermes-microvm.nix`

This module defines, on the host:

- The 10.99.1.0/30 bridge (parallel to the existing 10.99.0.0/30 OpenClaw
  bridge).
- The `hermes` system user and group (UID/GID 932).
- tmpfiles entry for `/var/lib/hermes` (mode 0750, owner hermes:hermes).
- nftables tables for **egress only** (DNS to bridge gateway, model API
  destinations, Discord gateway). No DNAT — no inbound TCP from host.
- The `microvm.vms.hermes` declaration: 4 vCPU / 4 GiB RAM, virtio-fs
  shares for the read-only Nix store and read-write `/var/lib/hermes`.
- Imports `./hermes-vm.nix` (the guest config from Task 5).

- [ ] **Step 1: Read the OpenClaw analog to crib structure**

```bash
sed -n '1,140p' /etc/nixos/modules/services/openclaw-microvm.nix
```

Pay attention to the `let` block defining `bridgeAddr`, `stateDir`,
`vmHostname`, `openclawUid`, `dnatPortList` — your module needs analogs.

- [ ] **Step 2: Write the new module**

Create `/etc/nixos/modules/services/hermes-microvm.nix` with this
content (verify the exact bridgeName/dnatPorts shape against the
OpenClaw file when copying — minor field names may have evolved):

```nix
# Host-side parent module for the Hermes Agent microVM.
# Imported by /etc/nixos/hosts/vulcan/default.nix.
#
# Sibling to modules/services/openclaw-microvm.nix; intentionally on
# its own private /30 bridge so neither VM's networking can affect the
# other. No DNAT/inbound in Phase 1 — Hermes is outbound-only.
{
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  bridgeName = "hermes-br0";
  tapName = "vm-hermes";
  bridgeAddr = "10.99.1.1";
  bridgeCidr = "${bridgeAddr}/30";
  vmAddr = "10.99.1.2";

  # External NIC used for VM NAT. Matches openclaw-microvm.nix:25 — the
  # host's physical interface on this Asahi/aarch64 box. Update both
  # files together if it ever changes.
  externalInterface = "end0";

  vmHostname = "hermes-vm";
  hermesUid = 932;
  hermesGid = 932;
  stateDir = "/var/lib/hermes";
in
{
  # NOTE: `inputs.microvm.nixosModules.host` is already imported globally
  # by flake.nix (system modules list). Do NOT re-import here — it
  # creates noise and drifts from the OpenClaw analog. We do still use
  # `inputs` in the let-block (microvm.vms.hermes.specialArgs below).

  # ---- Host user/group ----
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
    description = "Hermes Agent runtime user";
  };
  users.groups.hermes.gid = hermesGid;

  # ---- Host-side persistent state ----
  # `d` directive — preserves contents across rebuilds (CLAUDE.md rule).
  # `C+` directive stages the Vulcan root CA into the state share for the
  # guest's `security.pki.certificateFiles` to pick up (copy-once, never
  # overwrites; rerun a `nixos-rebuild` after rotating the cert).
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 hermes hermes -"
    "C+ ${stateDir}/vulcan-root-ca.crt 0644 hermes hermes - /etc/nixos/certs/vulcan-root-ca.crt"
  ];

  # ---- NetworkManager coexistence ----
  # NetworkManager runs on this host; tell it to ignore the bridge and
  # TAP interface so systemd-networkd can manage them. (Same pattern as
  # openclaw-microvm.nix:327.)
  networking.networkmanager.unmanaged = [
    "interface-name:${bridgeName}"
    "interface-name:${tapName}"
  ];

  # ---- systemd-networkd: bridge + TAP ----
  # Bridge comes up before the VM (ConfigureWithoutCarrier); TAP joins
  # the bridge when microvm.nix creates it.
  systemd.network.enable = true;
  # mkDefault: openclaw-microvm.nix sets the same flag. With both
  # modules loaded, mkDefault keeps the merge clean if either side
  # ever wants to override.
  systemd.network.wait-online.anyInterface = lib.mkDefault true;
  systemd.network.netdevs."50-${bridgeName}".netdevConfig = {
    Kind = "bridge";
    Name = bridgeName;
  };
  systemd.network.networks."50-${bridgeName}" = {
    matchConfig.Name = bridgeName;
    addresses = [ { Address = bridgeCidr; } ];
    networkConfig.ConfigureWithoutCarrier = true;
  };
  systemd.network.networks."51-${tapName}" = {
    matchConfig.Name = tapName;
    networkConfig.Bridge = bridgeName;
  };

  # ---- NAT: VM internet access ----
  networking.nat = {
    enable = true;
    internalInterfaces = [ bridgeName ];
    externalInterface = externalInterface;
  };

  # ---- Egress isolation (iptables-nft, matching OpenClaw) ----
  # OpenClaw's firewall uses iptables-extraCommands. Mirror that so the
  # host has one consistent backend (don't introduce nftables.tables
  # alongside iptables — they fight). Same FORWARD-chain drops as
  # openclaw for RFC-1918, plus an egress log for audit.
  networking.firewall.extraCommands = ''
    # ── Hermes network isolation ──
    iptables -N hermes-isolate 2>/dev/null || iptables -F hermes-isolate

    # DNS to bridge gateway (Technitium binds to 0.0.0.0:53)
    iptables -A hermes-isolate -d ${bridgeAddr} -p tcp --dport 53 -j RETURN
    iptables -A hermes-isolate -d ${bridgeAddr} -p udp --dport 53 -j RETURN

    # Drop everything else originating from the VM toward host services
    iptables -A hermes-isolate -j DROP
    iptables -I nixos-fw 3 -i ${bridgeName} -j hermes-isolate

    # FORWARD chain: block private-network-bound traffic (NAT/routing path).
    iptables -A FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP

    # Egress logging — log new outbound connections from the bridge
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress: " --log-level info

    # Belt-and-suspenders IPv6: the guest has v6 disabled and the
    # bridge is v4-only, but if anything ever flips v6 forwarding on
    # this host (or adds a v6 addr to the bridge), the v4 rules above
    # silently fail to filter it. Drop any v6 forward off the bridge.
    ip6tables -A FORWARD -i ${bridgeName} -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -i ${bridgeName} -j hermes-isolate 2>/dev/null || true
    iptables -F hermes-isolate 2>/dev/null || true
    iptables -X hermes-isolate 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress: " --log-level info 2>/dev/null || true
    ip6tables -D FORWARD -i ${bridgeName} -j DROP 2>/dev/null || true
  '';

  # ---- Nix store / virtiofs interaction ----
  # The guest mounts /nix/store via virtiofs (ro-store share in
  # hermes-vm.nix). Auto-optimise on the host can produce stale file
  # handles inside the guest — disable. Matches openclaw-microvm.nix:623.
  nix.optimise.automatic = false;

  # ---- SOPS secret staged for the VM's environmentFile ----
  # sops-nix decrypts on the host (where the age key lives) and writes
  # the cleartext to `path`. Because that path is inside the state share
  # virtio-fs'd into the VM, Hermes inside the VM reads it transparently
  # as /var/lib/hermes/env. Mode 0640 + owner hermes lets the in-VM
  # hermes user read it; the file never crosses to non-hermes processes.
  sops.secrets."hermes/env" = {
    mode = "0640";
    owner = "hermes";
    group = "hermes";
    path = "${stateDir}/env";
    # Re-rendering the env file alone isn't enough — the in-VM hermes
    # process loads env once at start. Restart the microVM unit when
    # the secret changes. Matches openclaw's pattern.
    restartUnits = [ "microvm@hermes.service" ];
  };

  # ---- microvm.nix declaration ----
  microvm.vms.hermes = {
    autostart = true;
    config = {
      imports = [ ./hermes-vm.nix ];
      _module.args = {
        inherit
          bridgeAddr
          vmHostname
          hermesUid
          hermesGid
          stateDir
          ;
      };
    };
    # microvm.nix runner config
    specialArgs = { inherit inputs system; };
  };

  # The microVM runtime itself
  # Both the per-VM `autostart = true` (above) and this target list
  # are required by microvm.nix — the former installs the systemd unit
  # link, the latter drives microvms.target boot ordering. Don't
  # consolidate.
  microvm = {
    autostart = [ "hermes" ];
  };
}
```

- [ ] **Step 3: Sanity-check the file parses**

```bash
nix-instantiate --parse /etc/nixos/modules/services/hermes-microvm.nix > /dev/null && echo PARSE OK
```

If it doesn't parse, fix syntax. Do not proceed.

- [ ] **Step 4: Commit (do NOT rebuild yet — Task 5 must land first)**

```bash
git -C /etc/nixos add modules/services/hermes-microvm.nix
git -C /etc/nixos commit -m "$(cat <<'EOF'
feat(hermes): add host-side parent module for the Hermes Agent microVM

Defines the 10.99.1.0/30 bridge, the hermes system user/group (UID/GID
932), tmpfiles entries for /var/lib/hermes (state share) and the
Vulcan root CA staged at /var/lib/hermes/vulcan-root-ca.crt, nftables
egress filtering, the sops.secrets."hermes/env" declaration (which
decrypts the secrets.yaml hermes/env key into the state share so the
guest's environmentFile picks it up via virtio-fs), and the
microvm.vms.hermes declaration that imports the guest config from
hermes-vm.nix (added in the next commit).

No host DNAT and no inbound TCP rules — Phase 1 keeps the VM purely
outbound (model APIs, Discord gateway WebSocket, DNS via the bridge gateway).
Egress is allowed broadly except to RFC-1918 destinations to limit
lateral movement if the guest is compromised.

Not wired into the host yet; that lands when hermes-vm.nix is added
and hosts/vulcan/default.nix imports the parent module.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Create the guest config (`hermes-vm.nix`)

**Files:**

- Create: `/etc/nixos/modules/services/hermes-vm.nix`

This module configures everything inside the guest:

- Hostname, basic NixOS state, IPv4 networking via the parent's bridge.
- Mounts of the host's `/var/lib/hermes` and the Vulcan CA bundle.
- The `services.hermes-agent.*` block from the upstream module.
- SOPS-nix loading of the hermes env file from `/var/lib/hermes`.

Note: the SOPS file actually decrypts on the HOST (where the age key
lives) and is delivered into the VM via a separate virtio-fs share.
Hermes inside the VM just reads it as a file. The OpenClaw VM uses the
same pattern — your existing `virtiofs-secrets.sock` in OpenClaw is the
analog. For Phase 1, simpler approach: stage the decrypted env file at
`/var/lib/hermes/env` from a host-side oneshot before the microvm
starts.

- [ ] **Step 1: Write the guest config**

Create `/etc/nixos/modules/services/hermes-vm.nix`:

```nix
# Guest config for the Hermes Agent microVM.
# Imported by modules/services/hermes-microvm.nix via microvm.vms.hermes.config.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  bridgeAddr,
  vmHostname,
  hermesUid,
  hermesGid,
  stateDir,
  tapName,
  ...
}:
let
  vmAddr = "10.99.1.2";
in
{
  imports = [
    inputs.hermes-agent.nixosModules.default
  ];

  # ---- Basic guest config ----
  system.stateVersion = "25.11";
  networking.hostName = vmHostname;
  networking.useNetworkd = true;
  networking.enableIPv6 = false;
  boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
  boot.kernel.sysctl."net.ipv6.conf.default.disable_ipv6" = 1;

  # ---- Guest networking ----
  microvm.interfaces = [
    {
      type = "tap";
      id = tapName; # threaded from hermes-microvm.nix via _module.args
      mac = "02:00:00:0c:1a:02";
    }
  ];
  systemd.network.networks."10-eth" = {
    matchConfig.Name = "eth*";
    address = [ "${vmAddr}/30" ];
    routes = [ { Gateway = bridgeAddr; } ];
  };
  networking.nameservers = [ bridgeAddr ];

  # ---- Virtio-fs shares ----
  # ro-store: Nix store from host (read-only) — standard microvm.nix idiom.
  # state:    /var/lib/hermes from host (read-write).
  # ro-store mountPoint is the host-store stage; microvm.nix's mounts.nix
  # bind-mounts /nix/.ro-store onto /nix/store at boot when
  # writableStoreOverlay is unset (which it intentionally is for Hermes —
  # uv2nix gives us a sealed venv at build time, no runtime store writes).
  microvm.shares = [
    {
      tag = "ro-store";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      proto = "virtiofs";
    }
    {
      tag = "state";
      source = stateDir;
      mountPoint = stateDir;
      proto = "virtiofs";
    }
  ];

  # ---- Vulcan CA bundle (HTTPS to internal services) ----
  # The host's CA cert is staged via tmpfiles into the state share, then
  # systemd reads it from the standard location. Same pattern as the
  # OpenClaw VM.
  security.pki.certificateFiles = [
    "${stateDir}/vulcan-root-ca.crt"
  ];

  # ---- Hermes Agent service ----
  services.hermes-agent = {
    enable = true;
    user = "hermes";
    group = "hermes";
    createUser = true;
    stateDir = stateDir;
    addToSystemPackages = false; # Known bug #6044 with HERMES_HOME export.
    container.enable = false;     # The microVM IS the sandbox.

    environmentFiles = [ "${stateDir}/env" ];

    settings = {
      # Declarative agent config. The upstream module deep-merges this
      # into ~/.hermes/config.yaml; the `.managed` marker blocks
      # `hermes config set` so this file is the only source of truth.
      logging.level = "INFO";
      gateway = {
        enabled = true;
        platforms = [ "discord" ];
      };
      discord = {
        # Token, allowlists, channel scoping come from env vars
        # (DISCORD_BOT_TOKEN, DISCORD_ALLOWED_USERS,
        # DISCORD_ALLOWED_CHANNELS, DISCORD_HOME_CHANNEL,
        # DISCORD_REQUIRE_MENTION). YAML keys below are the knobs that
        # DO NOT have env-var equivalents. If an env var IS set, it
        # overrides the YAML value at runtime — so DISCORD_REQUIRE_MENTION
        # in /var/lib/hermes/env wins over `require_mention` here.
        require_mention = true;
        auto_thread = true;
        reactions = true;
        allow_mentions = {
          everyone = false;
          roles = false;
          users = true;
          replied_user = true;
        };
      };
      # Model routing — Hermes consumes OPENROUTER_API_KEY and
      # OPENROUTER_BASE_URL from the env file. The model name MUST match
      # the `agent` slot in /etc/nixos/models.nix so Hermes shares the
      # same routing/fallback story OpenClaw uses for its long-running
      # tool-using sessions. Update both files together when changing.
      model = {
        provider = "openrouter";
        name = "hera/omlx/Qwen3.6-27B-MLX-8bit";
      };
      # memory/skills directories: omit — the upstream module's tmpfiles
      # creates ${stateDir}/.hermes/memories and .hermes/plugins on
      # activation (see nixosModules.nix:712-713). Hermes's defaults
      # already point there. Overriding without a matching tmpfiles
      # entry would force Hermes to mkdir at runtime, which may not have
      # the right group-write bits.
    };
  };

  # User+group inside the guest — must match the host UID so the
  # virtio-fs share permissions line up.
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
    createHome = true; # defensive — state share is also tmpfiles'd on host
  };
  users.groups.hermes.gid = hermesGid;
}
```

- [ ] **Step 2: Sanity-check the guest module parses**

```bash
nix-instantiate --parse /etc/nixos/modules/services/hermes-vm.nix > /dev/null && echo PARSE OK
```

- [ ] **Step 3: Confirm the CA-cert staging is already in place**

The Task 4 module already includes the `C+` tmpfiles rule that copies
`/etc/nixos/certs/vulcan-root-ca.crt` into the state share at
`${stateDir}/vulcan-root-ca.crt`. No additional host-side change is
needed here — the guest's `security.pki.certificateFiles` (in Step 2
above) reads from that staged path.

Verify the source cert exists before rebuild:

```bash
ls -la /etc/nixos/certs/vulcan-root-ca.crt
```

Expected: regular file, non-zero size, readable. If the filename is
different on your host, update both the `C+` source path in
`hermes-microvm.nix` AND the destination path in `hermes-vm.nix`
`security.pki.certificateFiles` to match.

- [ ] **Step 4: Commit**

```bash
git -C /etc/nixos add modules/services/hermes-vm.nix
git -C /etc/nixos commit -m "$(cat <<'EOF'
feat(hermes): add Hermes Agent guest microVM config

Adds the in-VM NixOS configuration that runs Hermes Agent via the
upstream nixosModules.default. Networking is the 10.99.1.0/30 bridge
defined in the parent module, with DNS proxied through the host
bridge (10.99.1.1). The state share at /var/lib/hermes is mounted
read-write so Hermes can write skills, memories, and session data
across reboots.

The agent is configured fully declaratively via services.hermes-agent
options — Discord is the only enabled gateway platform, scoped to a
single dedicated channel via DISCORD_ALLOWED_CHANNELS (set in the
sops env file) so this bot never sees OpenClaw's channel traffic.
require_mention defaults to true so Hermes is quiet unless explicitly
@-mentioned. The model route reads OPENROUTER_API_KEY and
OPENROUTER_BASE_URL from the sops-staged env file.
addToSystemPackages stays off (upstream issue #6044) and container
mode is off (the microVM IS the sandbox).

Vulcan root CA is staged into the state share via tmpfiles so the
guest can validate HTTPS to internal services without bundling the
cert in the Nix store.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire the new module into the vulcan host

**Files:**

- Modify: `/etc/nixos/hosts/vulcan/default.nix`

- [ ] **Step 1: Add the import**

Find the existing `imports = [ … ];` block (starts L9). The OpenClaw
import is at L135. Add immediately after it, keeping alphabetical/grouped
ordering:

```nix
    ../../modules/services/hermes-microvm.nix
```

- [ ] **Step 2: Confirm eval**

```bash
nix flake check /etc/nixos --no-build 2>&1 | tail -10
```

If there are eval errors (e.g. duplicate `users.users.hermes`, missing
input, syntax mistakes), fix them now. The most likely class of error:
the upstream Hermes flake's NixOS module also creates a `hermes` user,
conflicting with the one we declared in `hermes-microvm.nix`. Resolution:
set `services.hermes-agent.createUser = false` and rely on the parent
module's user declaration. (Or vice versa — drop the parent module's
users.users.hermes and let `createUser = true` handle it. Pick one
based on what the upstream module actually expects; the module docs
list `createUser` defaulting to `true`.)

- [ ] **Step 3: Commit (do NOT rebuild yet)**

```bash
git -C /etc/nixos add hosts/vulcan/default.nix
git -C /etc/nixos commit -m "$(cat <<'EOF'
feat(vulcan): import hermes-microvm module

Wires the Hermes Agent microVM (added in two earlier commits) into the
vulcan host configuration. Next nixos-rebuild switch will materialize
the microvm@hermes.service unit and start it on first boot.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update ports registry

**Files:**

- Modify: `/etc/nixos/docs/ports.txt`

- [ ] **Step 1: Reserve the Phase 2 sshd slot**

Even though Phase 1 doesn't enable sshd inside the VM, register the
slot now so a future port allocation doesn't collide:

In the SSH section (the existing block with `22 0.0.0.0 :: SSH` and
`22 10.99.0.2 OpenClaw microVM sshd …`), append:

```
22 10.99.1.2 Hermes microVM sshd (Phase 2; not enabled in Phase 1)
```

- [ ] **Step 2: Commit**

```bash
git -C /etc/nixos add docs/ports.txt
git -C /etc/nixos commit -m "$(cat <<'EOF'
docs(ports): reserve Hermes microVM sshd slot for Phase 2

The Hermes microVM doesn't enable in-VM sshd in Phase 1 — Phase 2
will add it for the nightly-report SSH probe pattern. Register the
slot in ports.txt now so future allocations don't pick 10.99.1.2:22
unknowingly.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Build, switch, verify

- [ ] **Step 1: Build first, no switch**

```bash
touch /etc/nixos/.nixos-build
sudo nixos-rebuild build --flake '/etc/nixos#vulcan' 2>&1 | tail -30
rm -f /etc/nixos/.nixos-build
```

Expected: build succeeds. Look for `microvm-hermes-vm-microvm-run.drv`
and `nixos-system-hermes-vm-25.11pre-git.drv` in the output — those
are evidence the guest config evaluated. Failure modes to watch for:
- "duplicate users.users.hermes" → resolve per Task 6 Step 2.
- "the option `services.hermes-agent.<x>` does not exist" → upstream
  module's option surface has changed; consult
  `hermes-agent.nousresearch.com/docs/getting-started/nix-setup` for
  the current shape.
- "infinite recursion" → likely a `let` binding in the parent module
  references something it shouldn't.

- [ ] **Step 2: Switch**

```bash
touch /etc/nixos/.nixos-build
sudo nixos-rebuild switch --flake '/etc/nixos#vulcan' 2>&1 | tail -15
rm -f /etc/nixos/.nixos-build
```

Watch for:
- `adding secret: hermes/env` — confirms SOPS deployed the env file.
- `the following new units were started: microvm@hermes.service, install-microvm-hermes.service`
- No `failed` markers.

- [ ] **Step 3: Verify the microVM is up**

```bash
sudo systemctl status microvm@hermes.service --no-pager | head -15
```

Expected: `Active: active (running)`. Memory usage 1.5–2 GiB shortly
after boot is normal.

- [ ] **Step 4: Verify the secret reached the VM**

The decrypted env file lives at `/var/lib/hermes/env` on the host AND
inside the VM (same path, via virtio-fs). Check the host side without
reading content (CLAUDE.md rule: never display secret contents):

```bash
sudo stat /var/lib/hermes/env
```

Expected: `Access: (0640/-rw-r-----) Uid: ( 932/  hermes) Gid: ( 932/  hermes)`.

- [ ] **Step 5: Verify the hermes-agent service is active inside the VM**

```bash
sudo machinectl shell hermes-vm /bin/systemctl status hermes-agent.service 2>&1 | head -15
```

If `machinectl` doesn't support this microVM (microvm.nix doesn't
always plumb a machinectl-compatible socket), look at the host-visible
journal instead:

```bash
sudo journalctl _COMM=hermes-agent --since "5 minutes ago" --no-pager | tail -20
```

Expected: log lines about gateway startup, Discord gateway
connection, model route initialization.

- [ ] **Step 6: Verify the Discord bot answers**

In Discord, go to the `#hermes` channel you created in Task 1. Send
`@Hermes (vulcan) hello` (mention the bot — `require_mention=true`
means it ignores un-mentioned messages). Expected: a reply within
~10 seconds. If nothing comes back:
- Check the journal for `discord` / `gateway` errors.
- Verify `DISCORD_ALLOWED_USERS` matches your actual Discord user ID.
- Verify `DISCORD_ALLOWED_CHANNELS` contains the channel you're in.
- Verify the bot token in `sops` is correct and that **Message Content
  Intent** is enabled in the Developer Portal (without it Hermes
  receives empty message text — the most common silent failure).
- Verify the bot actually joined the server (visible in the member
  list); if not, re-run the OAuth2 invite URL from Task 1.

- [ ] **Step 7: Verify the CLI works from inside the VM**

Try the interactive TUI (note: this requires a TTY, which the systemd
unit doesn't have — use a separate exec):

```bash
sudo machinectl shell hermes-vm /bin/su - hermes -c hermes
```

Expected: the Hermes Agent terminal UI launches. Press Ctrl-D or
`/exit` to quit. If `machinectl shell` isn't available, use the
microvm.nix console socket — see `microvm-openclaw.sock` for the
OpenClaw analog at the same level under `/var/lib/microvms/openclaw/`.

- [ ] **Step 8: Final commit if any polish needed**

```bash
git -C /etc/nixos status
# If clean, skip. If any in-flight changes from troubleshooting,
# commit them with a descriptive message.
```

- [ ] **Step 9: Save project memory**

Save `project_hermes_agent.md` capturing:
- Where the agent lives (microVM `hermes-vm` at 10.99.1.2)
- How secrets flow (sops → /var/lib/hermes/env → environmentFile)
- Which channels are enabled (Discord only, scoped to one channel via
  `DISCORD_ALLOWED_CHANNELS`, distinct from OpenClaw's bot/channels)
- The upgrade cadence (`nix flake update hermes-agent` quarterly)
- Phase 2 follow-ups (sshd for nightly probe, OpenClaw bridge)

---

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Upstream module's options diverge from research notes; build fails. | Plan calls out a specific failure mode in Task 8 Step 1. If options drift, consult upstream docs and edit `hermes-vm.nix` Step 2's `settings` block. The eight-task scaffolding still applies. |
| `createUser = true` collision with parent module's `users.users.hermes`. | Task 6 Step 2 explicitly addresses this with two valid fixes. |
| Hermes burns budget unexpectedly (autonomous skill loop calling models). | The OPENROUTER key can be capped per-month at OpenRouter. Set a hard cap before Task 8 Step 6. |
| Bot responds to wrong Discord user or wrong channel. | Three layers: `DISCORD_ALLOWED_USERS` (user-ID allowlist; deny-by-default if unset), `DISCORD_ALLOWED_CHANNELS` (channel-ID allowlist; scopes the bot to a single channel disjoint from OpenClaw's), `DISCORD_REQUIRE_MENTION=true` (ignores un-mentioned messages even in allowed channels). Validate by messaging from a different account in a different channel and confirming both are rejected. |
| Cross-bot collision with OpenClaw in the same Discord server. | Phase 1 explicitly avoids overlap by scoping Hermes to its own channel ID. Verify in Task 8 Step 6 that OpenClaw's bot does NOT respond in the Hermes channel and vice versa. |
| Egress rules too permissive — leakage to other internal services. | Phase 1 deliberately allows broad egress to RFC-1918 *gateway* (10.99.1.1 only) and external. Observe `nft -s list chain inet hermes-egress forward` counters for a week, then tighten in Phase 2 against the actual destinations Hermes uses. |
| Skills written to `/var/lib/hermes/skills` are runtime-modifiable code; a prompt-injection could write a malicious skill. | The microVM is the isolation boundary. Skills run only inside the VM, can't reach host or OpenClaw. ZFS snapshot pre-deployment optional for rollback. |
| Upstream releases ship without a stable tag tested for the NixOS module shape. | Use `nix flake update hermes-agent` only in dev, test the build, then commit `flake.lock`. Don't auto-update. |
| The microvm.nix `microvm.shares` source `/var/lib/hermes` doesn't exist at first boot. | Task 4's `tmpfiles d` directive ensures the directory is created before the unit starts; the microvm install service also waits for `systemd-tmpfiles-setup.service`. Verify ordering with `systemctl list-dependencies microvm@hermes.service`. |
| Vulcan CA cert not picked up; HTTPS to internal services fails. | `security.pki.certificateFiles` inside the guest reads the cert at activation. Verify with `curl -v https://hera.vulcan.lan/v1` from inside the VM after Task 8 Step 2. |

## Out of scope (Phase 2 and beyond)

- **OpenClaw → Hermes bridge** (MCP or HTTP). Belongs in a separate plan
  once Phase 1 has settled. The key open question: does Hermes actually
  expose an MCP server endpoint, or only consume MCP servers? Research
  showed conflicting evidence. Phase 2 starts by verifying that
  empirically, then choosing between MCP-bridge and OpenAI-HTTP-bridge.
- **`hermes claw migrate`** — one-way data migration from OpenClaw.
  Worth considering only if you decide to retire OpenClaw entirely.
- **sshd inside the VM** for the nightly-report `HOST_BLIND_SERVERS`
  probe extension. Easy to add (mirrors the OpenClaw work from
  `2026-05-11-openclaw-vm-ssh-probe.md`); deferred to keep Phase 1
  small.
- **ClawMem shared memory layer.** Federated SQLite vault between
  OpenClaw and Hermes. Useful only after both agents are running.
- **WhatsApp on Hermes.** Would need a fresh phone number distinct
  from OpenClaw's WhatsApp number (Hermes's Baileys bridge can't share
  a session). Not blocked by anything technical — just out of Phase 1
  scope. (Discord is now IN scope as the Phase 1 channel.)
- **Additional Discord channels for Hermes.** Phase 1 scopes Hermes
  to a single channel via `DISCORD_ALLOWED_CHANNELS`. Widening to
  more channels is a one-line config change after you've lived with
  the bot for a bit.
- **Tightened egress allowlist** against the specific model/Discord
  destinations Hermes hits. Phase 2 reviews `nft` counters and locks
  down accordingly.

## References

- [Hermes Agent — Nix & NixOS setup](https://hermes-agent.nousresearch.com/docs/getting-started/nix-setup)
- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- [Community Nix flake — 0xrsydn/nix-hermes-agent](https://github.com/0xrsydn/nix-hermes-agent)
  (consulted as a backup reference; not used as primary input)
- Existing analog in this repo: `/etc/nixos/modules/services/openclaw-microvm.nix`
  and `/etc/nixos/modules/services/openclaw-vm.nix`
- CLAUDE memory: `feedback_use_hera_route.md` — always use hera/* model
  routes, never anthropic/* as a workaround
