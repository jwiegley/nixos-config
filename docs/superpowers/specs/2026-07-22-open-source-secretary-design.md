# Open-Source Secretary — Design

**Status:** Approved (design), pending spec review
**Author:** Claude (Opus 4.8)
**Date:** 2026-07-22
**Related:** `2026-05-20-hermes-self-heal-and-nightly-report-design.md` (the nightly-report template this reuses), `2026-05-28-hermes-service-parity-design.md` (Hermes MCP/endpoint context).

## 1. Goal

A daily "open-source secretary" that keeps John on top of every open thread of
communication across the projects he maintains, works on, or contributes to —
so he can maintain focus across many projects without logging into each one.

Once a day it:

1. Scans **GitHub** repos owned by user `jwiegley` and org `ledger`, and
   **Gitea** repos owned by `johnw` (`gitea.vulcan.lan`) — every open issue and
   open PR, flagging what is **new** and what **received a new comment** since
   the last run.
2. Reads the full **GitHub notifications** feed and the **Gitea notifications**
   feed — including activity on repos John did *not* author (any org).
3. Hands the deterministically-computed digest to the **Hermes Agent** LLM,
   which produces a prioritized "needs your attention" section: genuinely
   **unanswered questions** and **serious issues** (bugs producing incorrect
   results, crashing users' systems, or otherwise operating far from expected).
4. **Emails** John a concise summary report.

The deterministic digest is the source of truth and is always shippable on its
own; the LLM is an advisory prioritizer layered on top, never a gate on
delivery.

## 2. Architecture

A **host-side** systemd timer + oneshot on `vulcan`, modeled on
`modules/services/hermes-nightly-report.nix`. Three stages, one process:

```
 systemd timer (07:00 daily, Persistent)
   └─ open-source-secretary.service  (oneshot, DynamicUser, strict sandbox)
        │
        │  flock(state.db)  ── exit if a run is already in progress
        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ 1. COLLECT (deterministic, requests + ETags + backoff)        │
   │    GitHub: /user/repos?affiliation=owner, /orgs/ledger/repos, │
   │            per-repo /issues?state=open&since=…, /notifications │
   │    Gitea:  /users/johnw/repos, per-repo /issues, /pulls,       │
   │            /notifications                                      │
   └──────────────────────────────────────────────────────────────┘
        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ 2. DIFF vs state.db  (keyed by (platform, node_id))           │
   │    → new items, new comments, reopened, stale; "awaiting you"  │
   │      feature bundle. Merge enumeration + notifications by id.  │
   └──────────────────────────────────────────────────────────────┘
        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ 3. TRIAGE  (Hermes api_server 10.99.1.2:8080, single-shot)    │
   │    pre-filtered/bounded digest → prioritized attention list.  │
   │    Redacted input. Validated ID-anchored output. Fallback →   │
   │    deterministic ordering if unreachable/invalid.             │
   └──────────────────────────────────────────────────────────────┘
        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ 4. RENDER + SEND  (plain-text email via /run/wrappers/sendmail)│
   │    Commit state.db transaction IFF sendmail exits 0.          │
   └──────────────────────────────────────────────────────────────┘
```

**Why host-side + hybrid:** the host already has egress, the tested `sendmail`
sandbox, the SOPS-secret plumbing, and the flake-check test harness. The
collector is deterministic and fully unit-testable; only the *judgment* step
crosses to the VM as a single chat completion (reliable even for a local model,
unlike 20+ sequential agentic tool calls).

## 3. Non-goals / YAGNI

- **No write-back.** The secretary never labels, comments, closes, or replies.
  Output is email-only. This bounds the prompt-injection blast radius and keeps
  tokens read-only.
- **No cross-host issue de-duplication.** Repo-name equality is used *only* to
  avoid scanning a mirrored repo's issues twice at enumeration time; issues/PRs
  are always keyed by `(platform, node_id)` and reported per host. Same-number
  issues on GitHub and Gitea are NOT assumed to be the same logical issue.
- **No map-reduce triage.** Single-shot triage over a pre-filtered, bounded
  digest. Map-reduce is explicitly deferred (over-engineering for a single-user
  daily digest; the Hermes model advertises a 262k context window, so the
  constraint is recall quality, not context length — pre-filtering addresses
  that).
- **No transactional outbox / run-journal.** A `flock` + a single SQLite
  transaction committed iff `sendmail` exits 0 gives the practical
  crash-safety guarantee. A send failure simply retries next day.
- **No Discord channel.** Email only, matching the existing report pipeline.
- **No label-change detection.** GitHub's `updated_at` is unreliable for
  label-only edits; we detect new items and new comments, not metadata churn.

## 4. Repository scope & credentials

### 4.1 GitHub

Enumeration (verified against GitHub REST API, 2026-07-22):

- **User leg:** when `includePrivate=false` (default) use
  `GET /users/jwiegley/repos?per_page=100` (public-only, simplest); when
  `includePrivate=true` use `GET /user/repos?affiliation=owner&per_page=100`
  (the only listing that can surface private repos; filter
  `owner.login == jwiegley`).
- **Org leg:** `GET /orgs/ledger/repos?type=public&per_page=100` by default,
  `type=all` when `includePrivate=true` (private ledger repos appear only if the
  token is authorized for the org).
- Never mix `type` with `visibility`/`affiliation` on `/user/repos` → 422.
- Paginate by following the `Link` header `rel="next"` until absent;
  `per_page=100` on repo/issue endpoints, **`per_page=50`** on `/notifications`
  (documented max is 50, not 100).

**Token: one classic PAT.** The `/notifications` endpoint is **classic-PAT-only**
(fine-grained PATs cannot call it at all), so a single-token design that
includes notifications must use a classic PAT.

- **Default scope: `public_repo` + `notifications`.** "Open source" = public;
  this reads public repos' issues/PRs and the notifications feed without any
  ability to touch private repos. This is the least-privilege classic option.
- **Upgrade path (documented, opt-in):** if John wants **private** `jwiegley`
  or `ledger` repos included, the scope becomes `repo` + `notifications`
  (note: `repo` is inherently read/write; the secretary never writes). Toggle
  in the module option `includePrivate` (default `false`), which also switches
  the user-leg enumeration to `/user/repos?affiliation=owner`.

The token belongs to `jwiegley` (private visibility and `/user/repos` only work
with his own token). It must be SSO-authorized for `ledger` if private ledger
repos are wanted.

### 4.2 Gitea (`gitea.vulcan.lan`, owner `johnw`)

Verified against the live swagger (`v1.25.5`) and the existing mirror module:

- **Repo list:** `GET /api/v1/users/johnw/repos?limit=50&page=N` — a **bare
  array**, correctly owner-scoped. Do **not** use `/repos/search?owner=…`; the
  `owner` param does not exist on that endpoint and is silently ignored.
- **Issues:** `GET /api/v1/repos/johnw/{repo}/issues?state=open&type=issues&since=…`
- **PRs:** `GET /api/v1/repos/johnw/{repo}/pulls?state=open` (richer PR fields),
  or `issues?type=pulls&since=…` for uniform time-delta filtering (the `/pulls`
  endpoint has **no** `since`). Classify defensively via the `pull_request`
  field on issue objects.
- **Notifications:** `GET /api/v1/notifications?since=…` (bare array of
  `NotificationThread`; use `subject.html_url` for the browsable link,
  `subject.type`/`subject.state` to classify, `repository.full_name` to group).
- **Auth header:** `Authorization: token <PAT>` — the literal word `token`,
  **not** `Bearer`.
- **Token:** a dedicated **read-only** Gitea PAT with scopes `read:repository`,
  `read:issue`, `read:notification`, `read:user`.
- **TLS:** `gitea.vulcan.lan` uses the internal step-ca cert. A systemd unit
  does **not** inherit the login shell's SSL env, and `requests`/`httpx` default
  to certifi's bundle which lacks the internal CA. The unit MUST set
  `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, and `NIX_SSL_CERT_FILE` to
  `/etc/ssl/certs/ca-certificates.crt` (which NixOS populates with the step-ca
  root via `security.pki.certificates`). **Never** `verify=False`.

### 4.3 SOPS secrets (three)

| SOPS key | mode | owner | Contents |
|---|---|---|---|
| `open-source-secretary/github-token` | 0400 | root | classic PAT (see 4.1) |
| `open-source-secretary/gitea-token` | 0400 | root | read-only Gitea PAT (4.2) |
| `hermes/env` (**reuse existing**) | — | — | supplies `API_SERVER_KEY` for the Hermes Bearer token |

All three are delivered via `LoadCredential` (required under `DynamicUser` — a
dynamic uid cannot read a root-owned `0400` file at `/run/secrets` directly).
The collector reads each from `$CREDENTIALS_DIRECTORY`. The Hermes key is parsed
out of the `hermes/env` credential (the `API_SERVER_KEY=` line) so there is **no
key duplication/drift** with the Hermes deployment.

## 5. Hermes triage endpoint

Verified from `hermes-mcp` + `models.yaml`:

- **URL:** `POST http://10.99.1.2:8080/v1/chat/completions`
- **Model:** `hera/omlx/Qwen3.6-27B-oQ4e-mtp` (`models.llm.agent.name`;
  context window 262144, maxTokens 81920, `maxSeconds` 3600).
- **Auth:** `Authorization: Bearer <API_SERVER_KEY>` (from `hermes/env`).
- **Body:** `{"model": <model>, "messages": [{"role":"user","content": <prompt>}]}`
  (no `temperature`/`max_tokens` — matches the existing client).
- **Response:** `choices[0].message.content` (a string).
- **Timeout:** connect 30 s, read/write up to 900 s (triage prompts are bounded
  and far smaller than a full generation; 900 s is a safe ceiling). Retry once
  on connection failure to tolerate a VM cold-start race (the service orders
  `after` but not `requires` the VM).
- **Failure = graceful degrade:** any non-200, timeout, malformed JSON, or
  invalid triage output → ship the deterministic digest with an
  `(LLM triage unavailable: <reason>)` banner. Never lose a day's report.

## 6. Data model (SQLite, metadata + hashes only — no bodies at rest)

State DB at the unit's `StateDirectory` (`/var/lib/open-source-secretary/state.db`,
StateDirectory mode `0700`, file `0600`, umask 077). **No issue/comment body text
is ever stored** — only identifiers, counts, hashes, and timestamps. (Bodies at
rest would turn the DB into a durable copy of pasted secrets + private content.)

```sql
-- One row per tracked thread (issue or PR), keyed by the STABLE platform id.
CREATE TABLE threads (
  platform            TEXT NOT NULL CHECK(platform IN ('github','gitea')),
  node_id             TEXT NOT NULL,   -- GitHub node_id / Gitea numeric id (stable, immutable)
  repo_full_name      TEXT NOT NULL,   -- display only (mutable; updated in place on rename)
  number              INTEGER NOT NULL,-- display only
  kind                TEXT NOT NULL CHECK(kind IN ('issue','pr')),
  title               TEXT,            -- display only (short, redacted)
  html_url            TEXT,
  state               TEXT NOT NULL,   -- 'open' | 'closed'
  closed_at           TEXT,            -- so reopen is 'reopened', not 'new'
  comment_count       INTEGER NOT NULL DEFAULT 0,
  last_comment_id     TEXT,            -- newest comment id seen (added-comment detection)
  last_comment_at     TEXT,            -- server timestamp
  last_commenter      TEXT,            -- login (for the 'awaiting you' bundle)
  updated_at          TEXT,            -- server updated_at (coarse change signal)
  first_seen_run      INTEGER NOT NULL,-- run id when first observed (baseline vs new)
  last_seen_run       INTEGER NOT NULL,
  PRIMARY KEY (platform, node_id)
);

-- ETag / Last-Modified cache for conditional requests (304 = free re-poll).
CREATE TABLE http_cache (
  url            TEXT PRIMARY KEY,
  etag           TEXT,
  last_modified  TEXT,
  fetched_at     TEXT
);

-- Per-source high-water marks + run bookkeeping.
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
-- keys: schema_version, baseline_established_at,
--       github_last_poll_utc, gitea_last_poll_utc, last_run_id

-- Optional: the owner-facing generated summary (still passes redaction).
-- NOT the raw source bodies. Kept only for the "since your last report" note.
CREATE TABLE run_summaries (run_id INTEGER PRIMARY KEY, created_at TEXT, summary TEXT);
```

## 7. Collector & delta behavior

### 7.1 Enumeration & de-dup

- Enumerate GitHub (`jwiegley` + `ledger`) and Gitea (`johnw`) repos.
- **Repo-name de-dup applies ONLY to enumeration efficiency** across the
  GitHub↔Gitea push-mirror pairs (scan each logical repo's issues once per
  platform, don't double-list). Issues themselves are never merged across hosts.

### 7.2 Delta computation (keyed by `(platform, node_id)`)

Using **server timestamps**, never the local run clock. Per source, store a
`*_last_poll_utc` watermark and re-query with `since = watermark − 10 min`
(overlap window), de-duping fetched items by id to avoid gaps and double-counts.

- **New item:** `node_id` not previously in `threads` (and run > baseline).
- **New comment:** `comment_count` increased since last run OR `last_comment_id`
  changed. (Comment-count delta is the cheap primary signal; for a changed
  thread the collector fetches the newest comment(s) since `last_comment_at` to
  capture author/id/short-snippet for the digest. `updated_at` alone is NOT used
  as the comment signal — it fires on labels/assignments/edits.)
- **Reopened:** `state` is open now but the stored row had `state='closed'` (or
  the row reappears after being absent) → reported as "reopened", not "new".
- **Stale:** open, no human comment in > 30 days → surfaced in a low-priority
  "quiet threads" section (helps catch dropped balls).

### 7.3 First run

**UPDATED 2026-07-22 per operator request:** the default first run is
**comprehensive**, not a silent baseline. With an empty state DB every open
thread is "new", so the first email is a full inventory summary (all open
issues/PRs + notifications, Hermes-prioritized), and the baseline is recorded
afterward so every subsequent run reports only deltas. Per-thread comment
enrichment is skipped when the first run's item count exceeds `ENRICH_CAP`
(50) to stay within `TimeoutStartSec` (the awaiting signal falls back to
coarse for that one run).

A **silent seed** (populate `threads`, mark none new, email only
"baseline established: N threads") remains available as an explicit opt-in via
`OSS_SECRETARY_BOOTSTRAP=1` — for a future flood-free re-baseline. (The original
design made the silent seed the *default* first run to avoid flooding; the
operator prefers a comprehensive first summary.)

### 7.4 "Awaiting you" feature bundle (a hint, never a gate)

For each active thread the collector computes structured signals and passes them
to the LLM — it does **not** decide "unanswered" from any single field:

- `last_commenter`, `is_last_commenter_owner` (login == `jwiegley`/`johnw`),
- `last_actor_is_bot` (login ends `[bot]` or is a known bot; bot comments are
  flagged/filtered so they don't count as "unanswered"),
- `has_owner_response` (owner has ever commented after the opener),
- `time_since_last_human_comment`,
- `author_association` (OWNER/MEMBER/CONTRIBUTOR/NONE),
- for PRs: `review_decision` + `unresolved_review_thread_count` where cheaply
  available (GitHub review threads live outside the issue-comment list; if not
  fetched, this is simply omitted — not guessed).

### 7.5 Reliability

- **Pagination:** follow `Link rel=next` (GitHub) / `X-Total-Count` + page loop
  (Gitea) on every list endpoint.
- **Conditional requests:** send stored `If-None-Match`/`If-Modified-Since`;
  304 responses are exempt from the rate limit and skip re-processing. Persist
  ETags in `http_cache`.
- **Backoff:** on GitHub 403/429 honor `Retry-After` then `x-ratelimit-reset`;
  on 5xx exponential backoff with a retry cap; requests issued serially. A daily
  scan is far under the 5000/hr budget; conditional requests make re-runs
  essentially free.
- **Auth via header only** — never token-in-URL (keeps tokens out of URLs, logs,
  tracebacks, redirect targets). Disable following redirects off the
  `api.github.com` / `gitea.vulcan.lan` host; `requests` strips `Authorization`
  on cross-host redirects (asserted by test).
- **Per-repo isolation:** a failure fetching one repo logs a redacted warning
  and continues; the run reports coverage (repos scanned, repos errored,
  truncations) in its footer — **no silent caps.**

## 8. Triage stage

### 8.1 Input (pre-filtered & bounded)

The LLM sees **only** new/changed/reopened/stale items (never the full open
inventory), each carrying a stable ID like `gh:jwiegley/ledger#123` or
`gitea:johnw/foo!45`. Item payload = title + a redacted excerpt (first ~600
chars) of the newest relevant comment/body + the awaiting-you bundle. A
configurable **hard token budget** (`llmTokenBudget`, default ~12000, to be
tuned after measuring the endpoint's real recall) bounds the prompt; if
exceeded, least-significant items (oldest/lowest-signal) are dropped and an
explicit "N items omitted from triage" notice is added — **never** silent
tail-truncation of the newest items.

### 8.2 Prompt framing (untrusted input)

All repo-derived text is wrapped in a clearly delimited, explicitly labeled
`<UNTRUSTED_INPUT>` block; the system framing instructs the model to treat its
contents strictly as data to summarize, never as instructions, and to take no
action. The model is asked to return a **fixed JSON shape**:

```json
{"attention": [{"id": "<one of the supplied ids>", "severity": "serious|question|fyi",
                "one_line": "<why it matters>"}],
 "notes": "<= 3 sentences of overall context"}
```

### 8.3 Output validation

Parse the JSON; every cited `id` must resolve to an id that was in the prompt
(unknown ids are dropped and logged). On any parse/validation failure, non-200,
or timeout → fall back to deterministic ordering (new serious-keyword hits →
questions → new items → new comments) with the `(LLM triage unavailable)`
banner. LLM output is untrusted: never `eval`'d, never triggers an action, and
is run through the redactor before it enters the email.

## 9. Report (plain-text email)

- **Subject:** `[oss-secretary] YYYY-MM-DD — N new · M awaiting reply · K serious`
- **§1 Needs your attention** — the LLM-prioritized list (serious issues +
  unanswered questions), each with its `id`, one-line reason, and URL.
- **§2 New issues / PRs** — grouped by repo (host-tagged).
- **§3 New comments on existing threads** — with last commenter + snippet.
- **§4 Elsewhere (notifications)** — threads on repos John doesn't own,
  grouped by repo, with `reason`.
- **§5 Quiet / stale** (optional, collapsed) — open threads with no human reply
  in > 30 days.
- **§6 Coverage footer** — repos scanned per host, repos errored, items sent to
  triage vs omitted, LLM status, run duration. No silent caps.

Built with the `_build_message` + `deliver` layer copied from
`agent_health_report.py` (raw RFC822 bytes; `sendmail -i -B 8BITMIME -f <from>
<to>`; `OSS_SECRETARY_DRY_RUN=1` prints the full message to stdout instead of
mailing). Every rendered field passes `redact()` first.

## 10. Security posture

Derived from the threat model; all are hard requirements.

1. **No-body-logging invariant.** Issue/comment bodies are attacker-controlled
   and routinely contain pasted secrets. The collector logs only metadata
   (repo, number, comment id, byte length, content hash, HTTP status, latency).
   Every string that could contain a body is passed through `redact()` (copied
   from `agent_health_report.py`: Bearer/`token=`/`secret=`/`password=`,
   `postgres://`/`mysql://` creds, PEM bodies, E.164 phones, `sk-ant-`/`sk-proj-`/
   `gh[pousr]_`/`AIza`/`AKIA`/`pplx-` prefixes) **before any log sink and before
   the LLM prompt.** A unit test feeds each secret pattern and asserts it never
   appears in captured log output.
2. **Redact-before-LLM.** The same redaction runs on text before it enters the
   Hermes prompt (defends against the VM-side inference server logging prompts);
   triage quality is unaffected by masking a credential. The LLM URL is pinned
   to the internal bridge IP `10.99.1.2`; redirecting it to any hosted endpoint
   is a documented policy change, not a config tweak.
3. **Tokens.** Two dedicated SOPS secrets (`0400 root`), plus reuse of
   `hermes/env`, all delivered via `LoadCredential`. Read-only scopes (§4).
   Header auth only. A top-level exception handler logs exception *type* + a
   redacted message, never raw request/response objects or headers. Test: raise
   inside the fetch path with a token in scope and assert the token never
   appears in captured logs.
4. **State DB.** Metadata + hashes only, `0600` under a `0700` StateDirectory;
   excluded from any world-readable backup path.
5. **Sandbox.** `DynamicUser=true`, `ProtectSystem=strict`, `ProtectHome=true`,
   `PrivateTmp=true`, `NoNewPrivileges=true`, `RestrictNamespaces=true`,
   `RestrictRealtime=true`, `RestrictSUIDSGID=true`, `LockPersonality=true`,
   `ProtectKernel*=true`, `MemoryDenyWriteExecute=false` (CPython needs W^X off).
   `RestrictAddressFamilies=[AF_UNIX AF_INET AF_INET6 AF_NETLINK AF_PACKET]` —
   **AF_NETLINK is load-bearing for sendmail's `getifaddrs()`; removing it →
   75/TEMPFAIL.** `ReadWritePaths=[/var/lib/postfix/queue]`. No IP allowlist
   (GitHub's CDN range is un-enumerable; containment relies on read-only tokens
   + no write actions, matching repo precedent). The service binds **no port**
   (outbound only) — asserted in the spec and by the port registry (no entry
   needed).
6. **Private-repo data flow** (only if `includePrivate=true`): confidential
   content crosses to the Hermes VM over the trusted internal bridge — a
   documented, accepted internal data flow.

## 11. Components & layout

A small Python **package** (not a single script) for isolation/clarity, packaged
with `buildPythonApplication` and mirroring `pkgs/hermes-mcp`:

```
pkgs/open-source-secretary/
  pyproject.toml
  src/oss_secretary/
    __init__.py
    config.py        # env → Config (OSS_SECRETARY_* vars, credential file reads)
    redact.py        # REDACT_PATTERNS + redact() (copied from agent_health_report)
    http.py          # requests session: pagination, ETag cache, backoff, header-auth, no off-host redirects, CA bundle
    github.py        # repo enum + issues/PRs + notifications (REST)
    gitea.py         # repo enum + issues/PRs + notifications (REST)
    state.py         # SQLite schema, flock, transaction, http_cache, watermarks
    delta.py         # (platform,node_id) diffing → new/new-comment/reopened/stale + awaiting-you bundle
    triage.py        # bound+redact prompt, Hermes call, JSON validation, fallback
    render.py        # plain-text sections + _build_message + deliver (sendmail)
    report.py        # main(): flock → collect → diff → triage → render → send → commit-iff-sent
  tests/             # pytest: fixtures per API shape, delta cases, redaction, dry-run golden, token-never-logged
```

```
modules/services/open-source-secretary.nix   # timer + oneshot, sandbox, SOPS, LoadCredential, CA env
```

- `flake.nix`: add the package to `packages` and its pytest suite to `checks`
  (mirroring the `hermes-mcp` package + check wiring).
- `hosts/vulcan/default.nix`: `services.open-source-secretary.enable = true;`.
- Module options: `enable`, `schedule` (default `*-*-* 07:00:00`), `recipient`
  (default `johnw@vulcan.lan`), `includePrivate` (default `false`),
  `llmTokenBudget` (default `12000`), `staleDays` (default `30`).

## 12. Failure modes

| Failure | Response |
|---|---|
| A repo fetch errors (404/403/5xx after retries) | Log redacted warning, skip repo, count it in the coverage footer; run continues. |
| GitHub rate/secondary limit | Honor `Retry-After`/`x-ratelimit-reset`, serial + backoff; if still blocked, partial run reported honestly in footer. |
| Gitea TLS failure | Hard error at startup only if CA env missing (build/test catches); otherwise per-repo skip. |
| Hermes api_server unreachable/slow/invalid output | Ship deterministic digest + `(LLM triage unavailable)` banner; still commit state. |
| `sendmail` TEMPFAIL / non-zero | **Roll back** the state transaction, exit non-zero (systemd shows failed); next day re-computes the same deltas. |
| Overlapping run | `flock` on the DB; second invocation exits 0 with a log line. |
| First ever run | Baseline seed: no per-item report, one-line "baseline established" email. |
| Crash mid-run | State only committed after successful send; a crash leaves prior state intact → next run recomputes. |

## 13. Testing

pytest suite wired into `flake.nix` `checks.${system}` (mirroring the
`hermes-mcp` package check):

- **API parsing:** fixtures for GitHub repo/issue/PR/notification JSON and Gitea
  equivalents; assert issue-vs-PR classification (`pull_request` key),
  pagination (`Link`/`X-Total-Count`), and ETag/304 handling.
- **Delta engine:** seeded state DB → assert new / new-comment (count delta) /
  reopened / stale classification; assert `(platform,node_id)` keying survives a
  repo rename (slug updates in place, no phantom "new"); assert no cross-host
  merge.
- **Baseline:** first run marks nothing new and sends the one-line summary.
- **Redaction (security):** each secret pattern is scrubbed from log output and
  from the LLM prompt; a raised exception with a token in scope never leaks the
  token to logs.
- **Triage:** valid JSON parsed + id-validated; unknown ids dropped; malformed
  output / non-200 → deterministic fallback + banner.
- **Dry-run golden:** `OSS_SECRETARY_DRY_RUN=1` with mocked collectors + mocked
  Hermes renders all section headers to stdout deterministically.
- **State commit gating:** `sendmail` non-zero → state rolled back (next run
  sees the same deltas); `sendmail` zero → committed.

Local end-to-end (pre-switch): `nixos-rebuild build` compiles; `nix flake check`
passes; a `--bootstrap` dry-run against live APIs (tokens provisioned) prints a
sane baseline; a second dry-run shows deltas.

## 14. Rollout (human-gated steps flagged)

1. Land the package, module, tests, flake wiring; `nix flake check` +
   `nixos-rebuild build --flake '.#vulcan'` green. *(autonomous)*
2. **[USER]** Provision the two SOPS tokens via `sops /etc/nixos/secrets.yaml`
   (classic GitHub PAT `public_repo`+`notifications`; read-only Gitea PAT).
3. **[USER]** `nixos-rebuild switch --flake '.#vulcan'` to deploy.
4. First timer fire (or manual `systemctl start`) runs the **baseline seed** →
   one-line email; the next day's run produces the first real digest.
5. Verify: `systemctl status` clean, state DB created `0600`, coverage footer
   sane, no secrets in `journalctl`.

Rollback: `services.open-source-secretary.enable = false` + switch; the timer
and unit disappear; state dir is left in place (harmless).

## 15. Acceptance criteria

1. `nix flake check` passes including the new pytest suite.
2. `nixos-rebuild build --flake '.#vulcan'` succeeds.
3. `OSS_SECRETARY_DRY_RUN=1` bootstrap prints a baseline summary with no
   per-item alerts; a second dry-run (seeded state) prints deltas + all section
   headers.
4. Redaction tests prove no secret pattern and no API token reaches log output.
5. State DB is `0600` under a `0700` StateDirectory; contains no body columns.
6. The unit binds no listening port; sandbox retains AF_NETLINK + postfix-queue
   RW; sendmail delivers.
7. State is committed only on `sendmail` exit 0 (verified by test).

## 16. Open decisions (defaults chosen; confirm at spec review)

- **GitHub scope default = `public_repo` + `notifications` (public only).**
  `includePrivate=true` upgrades to `repo` + `notifications`.
- **`llmTokenBudget` default 12000**, to be empirically tuned against the real
  Hermes endpoint recall after first deployment.
- **Notifications run daily alongside full enumeration** (the stated requirement
  is a daily full scan). A future optimization — notifications as the primary
  daily driver with enumeration on a slower cadence — is noted but not built.
- **Plain-text email** (established pattern); HTML deferred.
