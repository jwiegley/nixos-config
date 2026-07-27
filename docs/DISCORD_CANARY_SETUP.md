# Discord Round-Trip Canary — Setup Runbook (mutual cross-probing)

## What it is / why

An **active** probe that verifies Discord's inbound `MESSAGE_CREATE → agent
dispatch → reply` pipeline — the one leg no other monitor exercises. The two
agents probe **each other**, reusing their existing Discord bot tokens (no new
bot, no new secret):

- **@Claw (OpenClaw)** posts `@Hermes <nonce>` → Hermes must reply → metric
  `hermes_discord_canary_ok` (tests **Hermes**)
- **Hermes** posts `@Claw <nonce>` → OpenClaw must reply → metric
  `openclaw_discord_canary_ok` (tests **OpenClaw**)

**Accepted blind spot:** if *both* gateways die at once, neither probe reports.

**Why it's needed (2026-07-15 incident):** Hermes' Discord connection zombied
— WebSocket "connected", heartbeats ACKing, but `MESSAGE_CREATE` events stopped
reaching the agent, so it silently answered nobody for hours. Every existing
probe missed it because they bypass Discord (`e2e-chat` → api_server,
`ask_hermes` → MCP) or read log-event age (`HermesDiscordZombieSuspected`,
`OpenClawDiscordWsDown`) which a still-ACKing zombie keeps fresh. Only an
active message→reply round-trip proves the inbound path delivers.

## Known values (already wired)

- **@Claw (OpenClaw)** bot user id: `1477036366138445905`
- **Hermes** bot user id: `1503619790261194793`
- Tokens (reused, no new secret): OpenClaw → `openclaw/discord-token`;
  Hermes → `DISCORD_BOT_TOKEN` inside `hermes/env`.

## Components (built, `enable = false`)

- `scripts/discord_canary.py` — direction-agnostic probe (Discord REST v10, stdlib)
- `modules/monitoring/services/discord-canary.nix` — `services.discordCanary.probes.<name>`
- `hosts/vulcan/default.nix` — two probes (`hermes`, `openclaw`), pre-filled ids
- Alerts: `HermesDiscordCanaryDown` (self-heal-eligible) / `HermesDiscordCanaryStale`
  in `hermes.yaml`; `OpenClawDiscordCanaryDown` / `OpenClawDiscordCanaryStale`
  in `openclaw.yaml`.

## One-time setup

### 1. Pick a shared canary channel

A private channel (e.g. `#agent-canary`) where **both** @Claw and Hermes can
**View Channel + Send Messages + Read Message History** (add **Manage
Messages** for either bot if you want it to delete the other's replies too).
With Developer Mode on, right-click the channel → **Copy Channel ID**.

### 2. Allow each bot to answer the other (the real caveat)

Both gateways only respond to allow-listed senders, and many bots ignore
bot-authored messages entirely. You must:

- **Hermes must accept @Claw:** add `1477036366138445905` to
  `DISCORD_ALLOWED_USERS` (and the channel to `DISCORD_ALLOWED_CHANNELS`) in
  the `hermes/env` SOPS secret (`cd /etc/nixos && sops secrets/secrets.yaml` —
  the encrypted store lives in the separate `secrets` flake-input repo at
  `/etc/nixos/secrets/secrets.yaml`, not at the repo root).
- **OpenClaw must accept Hermes:** add `1503619790261194793` to the Discord
  `allowFrom` list in `modules/services/openclaw-config.nix` (the
  `channels.discord` block).

### 3. Verify each answers the other (do this BEFORE enabling)

Post one manual message in each direction and confirm a reply. Example
(OpenClaw→Hermes; swap token/target for the other direction):

```bash
TOK=$(sudo cat /run/secrets/openclaw/discord-token)      # post as @Claw
CH=<channel_id>; TARGET=1503619790261194793               # mention Hermes
MID=$(curl -s -X POST "https://discord.com/api/v10/channels/$CH/messages" \
  -H "Authorization: Bot $TOK" -H 'Content-Type: application/json' \
  -H 'User-Agent: DiscordBot (canary,1.0)' \
  -d "{\"content\":\"<@$TARGET> canary manual-test\"}" | jq -r .id)
sleep 30
curl -s "https://discord.com/api/v10/channels/$CH/messages?after=$MID" \
  -H "Authorization: Bot $TOK" -H 'User-Agent: DiscordBot (canary,1.0)' \
  | jq -r '.[] | "\(.author.id) \(.author.username)"'
# success = a line whose author id == $TARGET
unset TOK
```

If the target never replies: re-check its allow-list (step 2), and confirm its
adapter doesn't hard-drop bot authors. If it drops bots at the code level,
that direction can't be monitored this way without a small gateway-side change.

### 4. Enable

In `hosts/vulcan/default.nix`, set the channel id and flip `enable = true` on
whichever direction(s) verified in step 3:

```nix
services.discordCanary.probes = {
  hermes   = { enable = true; channelId = "<channel id>"; ... };  # tests Hermes
  openclaw = { enable = true; channelId = "<channel id>"; ... };  # tests OpenClaw
};
```

### 5. Build, switch, verify

```bash
cd /etc/nixos
git add scripts/discord_canary.py modules/monitoring/services/discord-canary.nix
sudo nixos-rebuild switch --flake '.#vulcan'

sudo systemctl start discord-canary-hermes.service    # run once now
sudo systemctl start discord-canary-openclaw.service
grep -h _ok /var/lib/prometheus-node-exporter-textfiles/hermes_discord_canary.prom \
            /var/lib/prometheus-node-exporter-textfiles/openclaw_discord_canary.prom
```

## Closing the self-heal loop

- **Hermes direction:** `HermesDiscordCanaryDown` carries
  `self_heal_eligible: "true"`, so a sustained failure already auto-restarts
  `microvm@hermes` via the hermes-self-heal daemon.
- **OpenClaw direction:** OpenClaw's self-heal triggers on *named* rules, not a
  label. To auto-restart on `OpenClawDiscordCanaryDown`, add that alert name to
  the openclaw-self-heal daemon's watched-rules set (`scripts/openclaw-self-heal/`).
  Until then it pages only.

Both `*CanaryDown` alerts are warmup-gated (>600s VM uptime) and the probe
retries once, so a fresh boot or a transient flap won't trigger a restart loop.

## Notes

- Each run deletes both messages (best-effort) so the channel stays clean.
- Cost: at 5-min cadence, ~288 round-trips/day/direction, each one agent turn.
- Metrics per direction: `{hermes,openclaw}_discord_canary_ok`,
  `_roundtrip_seconds`, `_post_http_code`, `_last_run_timestamp_seconds`,
  `_last_success_timestamp_seconds`.
