# Discord Round-Trip Canary — Setup Runbook (mutual cross-probing)

> **REMOVED — do not follow this runbook.** The mutual cross-agent canary was
> deleted with OpenClaw on 2026-07-31 (it probed two agents against each other, so
> it could not outlive one of them), and the remaining synthetic Hermes probes —
> the `ask_hermes` round-trip and the e2e chat probe — were removed on 2026-08-05
> because every probe landed in the operator's real Discord/Conduit message
> history. Nothing described below exists any more.
>
> What replaced it: passive liveness only. `hermes-health-check` probes the
> api_server and the MCP SSE endpoint and reads the Discord heartbeat-ACK stamp;
> `hermes-fallback-counter` catches per-conversation failures from real traffic
> within a minute. Kept as design history for anyone considering synthetic
> agent probing again — note the tradeoff that decided it.

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

## Bot-to-bot: config-only, and the gates are NOT where you would guess

An earlier version of this section claimed "both agents ignore bot-authored messages" and
"there is no config knob for this in either agent — no `allowBots`-style option exists in
openclaw's config schema or Hermes' env", and recommended retiring the canary. **All three
claims were wrong.** Both knobs exist, both work, and no code change is needed. That section
is preserved only as a warning about how it was reached: it generalised from probe runs that
were each invalidated by their own conditions (VM warmup, a 90 s timeout against 85–88 s
replies, and a probe that scored the *sibling probe's own post* as a reply).

### @Claw (openclaw) — TWO gates, in this order

`channels.discord.allowBots = "mentions"` is necessary and **not sufficient**. The gate that
actually drops a bot is the guild member allowlist, and it runs **first**:

| order | site (openclaw 2026.7.1) | condition |
|---|---|---|
| 1 | `message-handler.preflight.ts:563` | `isGuildMessage && hasAccessRestrictions && !memberAllowed` |
| 2 | `message-handler.preflight.ts:695` | bot author, `allowBots = "mentions"`, and no mention/reply |

`hasAccessRestrictions` comes from `allow-list.ts:238-240`:
`channelUsers = channelConfig?.users ?? guildInfo?.users`, then non-empty ⇒ restricted. So a
**non-empty `guilds.<id>.users` list restricts every sender in that guild, humans and bots
alike**, and any id missing from it is dropped 132 lines before `allowBots` is consulted.
The sender must therefore appear in `guilds.<id>.users`. `channels.discord.allowFrom` is a
**different** list — it feeds `resolveDiscordTextCommandAccess` and the DM path only, and
does not open gate 1.

Two traps:

- A per-channel `channels.<id>` entry **shadows** the guild entry via the `??` above, so
  adding one silently narrows the guild grant. Keep `channels = { }`.
- Because `requireMention = false`, mention resolution is dead code for human senders. A
  broken mention path is therefore **invisible in operator testing** and visible only for
  bots, which must clear gate 2.

### Hermes (discord.py) — one gate, and it is ordered correctly

`DISCORD_ALLOW_BOTS` in the SOPS `hermes/env` secret: `none` (default) / `mentions` / `all`.
Deployed at `plugins/platforms/discord/adapter.py:784-792`, and it runs **before** the human
`DISCORD_ALLOWED_USERS` allowlist deliberately (upstream #4466), so a bot admitted by
`DISCORD_ALLOW_BOTS` is not then rejected for being absent from the user allowlist. `mentions`
requires `self._client.user in message.mentions` — Discord's server-parsed mentions array.

**The value ships via the `secrets` flake input.** Editing `secrets.yaml` is not enough: the
input must be re-locked (`nix flake update secrets`) and `flake.lock` **committed**, or a
later checkout silently reverts the setting. The 2026-07-30 bump was `secrets` rev 158 → 160,
and Hermes began processing canary posts 15 minutes after it was activated.

### Hermes replies in a THREAD, not the channel

Hermes runs `auto_thread = true` (`modules/services/hermes-vm.nix`), so it answers by opening
a thread on the incoming message. A thread started from a message carries the **same
snowflake as that message**, and thread messages do **not** appear in the parent channel's
message list. A probe that only reads `/channels/<channel>/messages` is therefore structurally
blind to every Hermes reply.

This is not hypothetical: across nine consecutive runs (2026-07-30 22:55 → 2026-07-31 00:46
PDT) the probe reported `no reply within timeout` while Hermes answered **all nine
correctly** — `gateway.run` logged `inbound`, the agent logged `finish_reason=stop
response_len=18` (exactly `len("CANARY OK ") + 8` hex nonce chars), and
`gateway.platforms.base` logged `Sending response (18 chars)` to a snowflake that was not the
channel id. Zero send failures. The probe now polls both the channel and
`/channels/<posted_message_id>/messages`, and deletes the reply from whichever it was found
in.

Diagnostic value of the distinction: `admission` failures leave **no** `gateway.run: inbound`
line, whereas a **delivery/visibility** failure has the full inbound → response → Sending
response chain. Check `/var/lib/hermes/.hermes/logs/agent.log` before touching any allowlist.

### Reading a canary result honestly

- **Ignore any result within ~20 minutes of a VM restart.** In the one proven-good window,
  runs starting +3.5 min and +18.6 min post-boot both failed; the first success was ~36 min
  post-boot.
- **Only `reply+nonce` and `reply+reference` mean anything.** Before the probe was hardened
  it accepted any recent message from the target, so the two probes scored each other's posts
  and one run deleted a genuine @Claw reply to the operator. Any green before 2026-07-30
  21:39 PDT is an artifact.
- A bare `no reply within timeout` does not distinguish "dropped at gate 1", "dropped at
  gate 2", and "replied without echoing" — set `logging.file` and read the
  `[discord-preflight] drop: …` line instead of guessing.

## ⚠️ Read this before diagnosing a red canary

**`post_http=200` + `no reply within timeout` does NOT mean the target rejected the
sender.** It means the post succeeded and no reply arrived *inside `timeoutSeconds`*.
These targets are LLM agents: measured reply latencies are 3.5s, 6.8s, 7.4s, 30.2s,
85.3s, 87.8s. Against the module's original 90s default, healthy slow replies scored
as a dead round-trip, and reading that as "the allowlist is wrong" produced a
confidently wrong diagnosis on 2026-07-30. `timeoutSeconds` is now 180 on both probes.

Rule out, in this order, before touching any allowlist:
1. **A still-warming VM** — compare the run's timestamp against
   `microvm@<agent>.service`'s `ActiveEnterTimestamp`, and against
   `openclaw_gateway_ready_timestamp_seconds` (which must POSTDATE the restart; a
   `probe_success` of 1 seconds after a restart is usually a stale scrape).
2. **A timeout that is simply too short** — see the latency spread above.
3. **A dead timer** — `systemctl list-timers 'discord-canary*'` with an EMPTY
   next-elapse. That is how the hermes direction was silently dead for a day.

**The agents answer only about half their mentions.** That is why the alerts key on
the *age of last success* and on a *success rate*, not on consecutive failures — see
`*DiscordCanaryDown` / `*DiscordCanaryDegraded`.

## ⚠️ What happens if you enable before step 3 (2026-07-30 incident)

Both directions were enabled on 2026-07-30 **without** completing step 2, so
neither bot could answer the other and both canaries reported `ok=0` from their
very first run. That produced a self-inflicted outage loop:

`OpenClawDiscordCanaryDown` fired → the self-heal daemon had no explicit action
mapped for it and fell back to its `restart_microvm` default → the restart
re-stamped `openclaw_microvm_active_enter_timestamp_seconds`, which the alert's
own `> 600` warmup gate reads → the alert **resolved** → 25 minutes later
(600 s warmup + `for: 15m`) it fired and restarted the VM again. One
critical-then-resolved email pair every ~26 minutes, and the first restart killed
a VM that had been healthy for 62 hours.

Three changes were made. Read the last paragraph for what they do and do **not**
guarantee — an earlier version of this section claimed the loop "cannot recur",
which was wrong.

1. **No canary-down auto-restart.** `OpenClawDiscordCanaryDown` is deliberately
   absent from `openclaw-self-heal`'s `ACTION_MAP`, and must stay absent. This is
   the change that actually breaks the loop.
2. **No default remediation.** The daemon no longer defaults *unmapped* alerts to
   `restart_microvm` (hermes never did). Unmapped alerts are ignored and counted
   in `openclaw_self_heal_unknown_alerts_total`.
3. **Proven-green gate + setup-fault alert.** `*DiscordCanaryDown` also requires
   `last_success_timestamp_seconds > 0`, and `*DiscordCanaryNeverSucceeded` fires
   after 2 h so a never-green canary is reported rather than silently inert.

**What the gate does not do.** `last_success > 0` is satisfied *permanently* once
a canary goes green even once. It stops an unproven probe being mistaken for a
regression; it does **not** bound the restart loop. If this alert were ever mapped
to a restart again, a genuine post-green failure would loop exactly as before:
restart → warmup gate re-stamped → resolve → re-fire 25 min later with a new
`startsAt` → new incident at attempt 1 → restart. Per-incident escalation never
accumulates, and the circuit breaker (3 actions/hour) paces it without ending it.
Any future attempt to automate this needs a bound that survives its own
remediation re-stamping the gate metric.

Enabling early is now *safe* (it can neither page nor remediate), but step 3 is
still the right order: until it passes, the canary is monitoring nothing.

## Known values (already wired)

- **@Claw (OpenClaw)** bot user id: `1477036366138445905`
- **Hermes** bot user id: `1503619790261194793`
- Tokens (reused, no new secret): OpenClaw → `openclaw/discord-token`;
  Hermes → `DISCORD_BOT_TOKEN` inside `hermes/env`.

## Components (both directions `enable = true` since 2026-07-30)

- `scripts/discord_canary.py` — direction-agnostic probe (Discord REST v10, stdlib)
- `modules/monitoring/services/discord-canary.nix` — `services.discordCanary.probes.<name>`.
  Timers use `OnActiveSec`, not `OnBootSec`: a timer first created by a
  `nixos-rebuild switch` on a long-uptime host would otherwise have its only
  anchor in the past and never fire, which is exactly what left
  `discord-canary-hermes.timer` dead from birth (`SubState=elapsed`, empty
  NextElapse — indistinguishable from healthy in `systemctl status`).
- `hosts/vulcan/default.nix` — two probes (`hermes`, `openclaw`), pre-filled ids
- Alerts, per direction: `…DiscordCanaryDown` (critical, gated on
  `last_success > 0`, self-heal-eligible), `…DiscordCanaryNeverSucceeded`
  (warning, setup fault, deliberately **not** self-heal-routed),
  `…DiscordCanaryStale` (warning), `…DiscordCanaryNotCleaningUp` (warning).

## One-time setup

### 1. Pick a shared canary channel

A private channel (e.g. `#agent-canary`) where **both** @Claw and Hermes can
**View Channel + Send Messages + Read Message History** (add **Manage
Messages** for either bot if you want it to delete the other's replies too).
With Developer Mode on, right-click the channel → **Copy Channel ID**.

### 2. Allow each bot to answer the other (the real caveat)

Both gateways only respond to allow-listed senders, and many bots ignore
bot-authored messages entirely. What 2026-07-30 established, per direction:

- **Hermes accepting @Claw: NOTHING TO DO.** It already answers @Claw — verified
  ok=1 / rt=6.773s. Do **not** edit `DISCORD_ALLOWED_USERS` in the `hermes/env`
  SOPS secret on the strength of a red canary; an earlier version of this runbook
  prescribed that, and it would have been a pointless secrets edit. This direction
  was red because its *timer* never fired.
- **OpenClaw accepting Hermes: `allowFrom` is enough.** Add
  `1503619790261194793` to `channels.discord.allowFrom` in
  `modules/services/openclaw-config.nix`, then restart `microvm@openclaw` (config is
  injected at preStart). The canary went green on that alone. Hermes is *also*
  scoped under `guilds.<id>.channels."<#interconnect>"` with
  `requireMention = true`; that block is accepted by openclaw (drift shows it is not
  stripped) but is **not** load-bearing and its semantic effect is untested — do not
  cite it as proof that per-channel scoping works. Do **not** add Hermes to the
  guild-wide `guilds.<id>.users`: that list pairs with `requireMention = false`, so
  @Claw would answer every Hermes message anywhere in the guild, and since Hermes
  answers @Claw they could ping-pong without bound.

### 3. Verify each answers the other (do this BEFORE enabling)

Post one manual message in each direction and confirm a reply. Example
(OpenClaw→Hermes; swap token/target for the other direction):

Do NOT substitute `sudo cat` on the token path to inspect it — see the
FORBIDDEN-BY-DEFAULT list in `CLAUDE.md`. Reading it into a variable that is never
echoed (and `unset` at the end) is the only form used here.

```bash
TOK=$(sudo cat /run/secrets/openclaw/discord-token)      # post as @Claw; never echo $TOK
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
