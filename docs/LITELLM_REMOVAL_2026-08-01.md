# LiteLLM removal and LLM gateway migration — 2026-08-01

Final status record. LiteLLM was removed from vulcan and replaced by an nginx
reverse proxy on the same port. This documents what changed, what was verified,
what was deliberately given up, and what remains outstanding.

**Outcome: complete and verified.** Generation 2357, commits `b67dd1501` and
`ab687529f`, both pushed to `origin/main`.

---

## What replaced LiteLLM

`127.0.0.1:4000` is now an nginx reverse proxy to `https://hera.lan:8443/v1`
(llama-swap / MLX), declared in `modules/services/hera-llm-proxy.nix`.

The port and the OpenAI wire shape are unchanged, so **no consumer needed
rewiring** — including the Hermes microVM, whose `hermes-br0` DNAT already
rewrites to `127.0.0.1:4000`.

Design points:

- TLS to hera verified against the Vulcan CA (`proxy_ssl_verify on`, SNI set).
- The upstream `Authorization` header is injected host-side from SOPS via
  `sops.templates`, so the key never enters the world-readable Nix store and
  never reaches the Hermes guest.
- `proxy_buffering off` for SSE token streaming.
- `proxy_read_timeout 3600s` to match `models.nix` `maxSeconds` — a cold 27B
  load was measured at 50–95s.

Verified live against the backend: `/v1/models`, `/v1/chat/completions`,
`/v1/embeddings` (`bge-m3-mlx-fp16`, 1024-dim), `/v1/audio/transcriptions`,
and `/v1/messages` — llama-swap speaks the Anthropic shape natively, which is
why the `litellm-anthropic-fixup` shim was **not** carried forward.

---

## Deliberate capability changes

These are consequences of removing a routing proxy, not oversights.

| Capability | Status |
|---|---|
| Chat completions | preserved (`Qwen3.6-27B-oQ4e-mtp`) |
| Embeddings | preserved (`bge-m3-mlx-fp16`, 1024-dim) |
| Transcription | preserved (`cohere-transcribe-03-2026-mlx-fp16`) |
| Anthropic `/v1/messages` | preserved — native on llama-swap |
| Model **aliasing** | **gone** |
| Hosted providers | **gone** |
| Rerank | **gone** (no rerank model upstream) |

**Model aliasing.** The gateway does not rewrite request bodies, so callers must
use real upstream ids. `models.nix` now carries `Qwen3.6-27B-oQ4e-mtp` and
`bge-m3-mlx-fp16` instead of the old `hera/omlx/...` and `hera/bge-m3` aliases.
Five Python defaults that hardcoded the alias and bypassed the registry were
updated too.

**stock-trader.** `ANTHROPIC_BASE_URL` pointed at the deleted `:4001` shim and
`ANTHROPIC_MODEL` was `hera/claude-opus-4-7`, a hosted model that existed only
through LiteLLM's provider catalog. The Anthropic-shaped path still works but is
now served by the **local** model. Switching it back to `api.anthropic.com` turns
this service from local-only into metered external egress — an operator
decision, documented inline.

**rspamd.** The `harmony_filter` guardrail that stripped `<|channel|>` analysis
markers was a LiteLLM plugin and died with the proxy. JSON parsing there now
rests entirely on `enable_thinking = false`. Documented inline as the first thing
to check if spam classification starts failing — Postfix blocks on that milter.

---

## Two nginx defects found the hard way

Both took down more than the new vhost.

**1. A sops-rendered file that nginx `include`s must be owned by `nginx`.**
This host runs nginx as `User=nginx`, and the config test in `ExecStartPre` reads
every `include` as that user. A `0400 root`-owned template made `nginx -t` fail
with `EACCES`, which failed the unit and took **every vhost** down for ~44
seconds, then crash-looped into the systemd start limit. Fix: `owner = "nginx"`.

**2. `recommendedProxySettings` is appended *after* `extraConfig`.**
It contains `proxy_set_header Host $host;`, which silently overrode the upstream
Host — hera received `Host: 127.0.0.1:4000`, matched no `server_name`, and
returned 400 for every request. The 400 says `Server: nginx` and looks local;
the discriminator is the version banner (vulcan runs 1.28.3, hera 1.30.4). Fix:
`recommendedProxySettings = false` and set headers explicitly.

Both are recorded in the agent memory file
`project_nginx_sops_include_and_proxy_headers`.

---

## Alerting fix: HostUnreachable was double-alerting 42 targets

`HostUnreachable` selected `job=~"blackbox_.*"`, which matched every HTTP vhost
probe. So 42 targets emitted **paired** `WebServiceDown` + `HostUnreachable`
criticals for one condition, the latter claiming a *host* was unreachable when
only an HTTP endpoint on it was — the same defect the rule's own comment already
documented for the hera probes, at 42x the scale.

Observed live: a single nginx restart during this migration produced exactly that
pair for `https://rspamd.vulcan.lan`, which is what prompted the operator's
"rspamd web access is unavailable" report. rspamd itself was never broken.

Narrowed to exclude `blackbox_http.*`. No coverage lost — `WebServiceDown`
selects the same jobs at the same severity (`critical`) with a **shorter** dwell
(`1m` vs `2m`), so it fires sooner on the identical condition. `blackbox_https_public`
retains its dedicated owner, `PublicEdgeDown`. Verified against live data before
building.

---

## SOPS: configuration made independent of stale litellm names

`secrets.yaml` was **never opened, edited, decrypted, or re-encrypted.**

Six modules referenced a `litellm*` SOPS entry. In **five** the value was already
**inert** — the gateway overwrites the client's `Authorization` header, so those
consumers only ever needed a non-empty string. All five now use a literal
sentinel and depend on no SOPS entry:

| Module | Old pointer |
|---|---|
| `rspamd.nix` | `litellm-vulcan-lan` |
| `vane.nix` | `litellm-vulcan-lan` |
| `hermes-self-heal.nix` | `litellm-vulcan-lan` |
| `openclaw-self-heal.nix` | `litellm-vulcan-lan` |
| `openclaw-microvm.nix` | `openclaw/litellm-virtual-key` |

Two subtleties handled: rspamd's `enabled = true;` lived *inside* the removed
secret-existence gate, so a missing secret used to silently disable the GPT
module — the write is now unconditional. And vane's key is hashed into its
provider identity, so the sentinel is covered by the existing re-hash logic;
a migration step also drops the legacy provider rather than leaving a duplicate.

### The one remaining reference

`modules/services/hera-llm-proxy.nix` still points at `litellm/omlx-api-key`.
This is the gateway's **real** upstream bearer token, and the backend validates
it **by value** (a bogus token returns 401, verified). It cannot become a
sentinel, and `secrets.yaml` holds no other entry with that value. The nix
attribute name is already neutral (`hera-llm-api-key`), so the rename is a
one-line change once a new entry exists. Procedure documented inline at that
declaration.

---

## The alexey / home-manager blocker (resolved by nix-review)

Activation of generation 2357 exited **4** and left `home-manager-johnw`
crash-looping. Cause: an `aiManagedPreflight` check from the `nix-config-ai`
input — updated by three upstream fleet commits rebased in during this work,
**not** by the LiteLLM changes — refused to clobber four pre-existing paths:

```
.claude/commands/alexey.md
.claude/skills/alexey-review
.config/opencode/commands/alexey.md
.config/opencode/skills/alexey-review
```

Evidence of origin: first blocking message at 08:44:55, exactly when gen 2357
activated, with zero occurrences before; `aiManagedPreflight` appears nowhere in
this repo's history.

Resolved by moving the four artifacts aside to
`~/.local/share/hm-preflight-blockers/2026-08-01/` (8 files preserved, including
the `alexey-review` skill trees and their `references/`), then restarting the
unit. All four paths are now Nix-managed store symlinks that resolve cleanly.

**Correction on record:** the initial analysis reported "no Nix source found
under the HM generation" for those paths and framed removal as lossy. That was
wrong — the search inspected the generation derivation directly, but
home-manager stages content in a separate `home-files` store path it references.
Replacements existed; moving the originals aside was correct and safe.

### Lagging alerts, watched to zero

The fix left two warnings that were artifacts of the loop, not new faults:

- `SystemdJournalHighErrorRate` — 49 of the errors were literally
  "Failed to start Home Manager environment for johnw"
- `ServiceRestartLooping` — `name=home-manager-johnw.service`, `[30m]` window

After confirming the loop had genuinely stopped (`increase(...[5m]) = 0`,
`NRestarts=0`), the 30m window was watched draining rather than predicted:
205 → 182 → 155 → 130 → 106 → 82 → 58 → 33 → 11 → **cleared 09:34**.

---

## Final verification

| Check | Result |
|---|---|
| Active generation | 2357 (`sff9xmifg…`) |
| HEAD | `ab687529f` |
| Git | clean, `0/0` vs `origin/main`, both commits pushed |
| Failed units / activating | **0 / 0** |
| Prometheus rules | 502 total, **0 errors**, 0 unknown |
| Active alerts | `ExposedImageFixableHighCVE` (info, predates this work), `Watchdog` (by design) |
| LiteLLM rules / alerts / units / probes | **0 / 0 / 0 / 0** |
| LiteLLM textfile collectors / unix user | 0 / gone |
| Gateway `:4000` | 200 (models + embeddings), owned by nginx |
| rspamd web | vhost 200, controller `pong`, GPT module `enabled=true` |
| `home-manager-johnw` | `Result=success`, `ExecMainStatus=0`, `NRestarts=0` |

Services active: nginx, rspamd, postfix, dovecot2, prometheus, alertmanager,
postgresql, home-assistant, grafana, nagios [Nagios removed 2026-08-19],
wyoming-openai, qdrant-inference-bridge, stock-trader, hermes-self-heal,
openclaw-self-heal.

**Zero critical, zero warning.**

Only failing probes are three Nest thermostats in `host_group=iot-noping` —
devices that never answer ICMP by design and are explicitly excluded from
paging.

### Change size

`75 files changed, 729 insertions(+), 3207 deletions(-)` in `b67dd1501`, plus a
4-file follow-up in `ab687529f`. Eleven files deleted, two added.

---

## Outstanding — operator action

**1. The last SOPS pointer.** `hera-llm-proxy.nix` → `litellm/omlx-api-key`.
Needs an interactive `sops` session to copy the value to a neutral key, then a
one-line change. Verify with
`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/v1/models`
(200 = correct, 401 = wrong value) *before* deleting the old entry.

**2. On-disk remnants — DONE 2026-08-03.** Originally left in place at the
operator's request ("leave any files related to it outside of /etc/nixos alone
until I have time to review"). Archived and destroyed on 2026-08-03;
`scripts/cleanup-litellm-remnants.sh` was retired with them.

Everything is archived under **`/tank/Backups/Machines/Vulcan/litellm`**
(root:root 0700, files 0600 — the role dump and the cert tarball carry a
password hash and a private key respectively):

| Archive | Was |
|---|---|
| `litellm.dump` (52 MB, pg custom format) | `litellm` database, 1656 MB |
| `litellm-role.sql` | the `litellm` role definition |
| `var-lib-litellm.tar.gz` (54 MB) | `/var/lib/litellm`, 183 MB / 9068 files |
| `etc-litellm.tar.gz` | `/etc/litellm` (config.yaml was 0 bytes) |
| `nginx-certs-litellm.tar.gz` | `litellm.vulcan.lan.{crt,key}` |

The dump was verified before anything was dropped: `pg_restore --list` clean,
all 68 tables present, then restored into a scratch database with 0 errors and
row counts matching live on every table checked (164882 / 2956772 / 7987 / 518).

Removed from the active system: the database, the role (its grants on `db` had
to be revoked with `DROP OWNED BY` first — it owned nothing), `/var/lib/litellm`,
`/etc/litellm`, the two nginx certs, and the stale
`/tank/Backups/PostgreSQL/db/litellm` mirror directory. The unix user, systemd
linger file and podman images were already gone. Verified after: 0 databases,
0 roles, 0 units, 0 live `litellm_*` Prometheus series.

**Expect `PgDumpSizeShrunk` to persist a little longer as a result.** Dropping
the database removes a further ~1.1 GB from the nightly dump, which lowers the
current value while the 14-day average is still inflated by the 07-25..07-30
SpendLogs balloon. The alert is arithmetic, not a fault — see the analysis in
this file's sibling notes. It clears once the balloon ages out (~08-13).

**3. stock-trader's model.** Currently the local Qwen. Decide whether that path
should return to hosted Anthropic.

---

## Background at time of writing

A scheduled ZFS scrub started 00:59 and was at 8.56T/18.5T, keeping load near
12–13. It is correctly gated: `zfs_pool_scrub_active=1` and
`ZFSPoolIOSaturated` is not firing.
