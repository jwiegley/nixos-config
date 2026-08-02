# LAN plaintext exposure audit — vulcan, 2026-08-02

Census of every network listener on vulcan, classified by reachability and by
whether it is encrypted. Prompted by the policy decision that **no service
offered by vulcan to the LAN may be unencrypted**, and by the discovery that the
Hermes agent endpoint had briefly been published over plain HTTP while carrying
`API_SERVER_KEY`.

**Headline: 16 plaintext HTTP services and 2 plaintext non-HTTP services are
reachable from the LAN.** Loopback-only listeners are out of scope and are fine.

---

## Method

Listeners were enumerated from `/proc/net/tcp` and `/proc/net/tcp6` (state `0A`
= LISTEN), with socket inodes mapped back to processes via `/proc/*/fd/*`.
`ss` was unusable — it is shadowed by an ssh alias in the working shell and
exits 255.

Reachability was then **probed over `end0` against `vulcan.lan`**, not over
loopback. This matters: several services bind a wildcard address, so a loopback
probe would have wrongly reported them as reachable-but-local. Everything listed
as LAN-reachable below answered on the external path.

Encryption status is by observation (does it answer plain HTTP?) plus
configuration review for the non-HTTP protocols, not by inference from port
number.

### Census

| | count |
|---|---|
| Total TCP listeners | 121 |
| Loopback-only (out of scope) | 74 |
| Reachable off-host | 47 |
| — of those, plaintext HTTP | 16 |
| — of those, plaintext non-HTTP | 2 |

---

## Group A — plaintext backends that ALREADY have an HTTPS vhost

The clearest problem class: nginx terminates TLS for these on 443, but the
backend is *also* directly reachable in the clear, so the TLS layer is optional
rather than mandatory. Anyone on the LAN can simply skip it.

| Port | Service | HTTPS vhost that fronts it | Probe |
|---|---|---|---|
| 8084 | Open WebUI | `chat.vulcan.lan` | 200 |
| 8096 | Jellyfin | `jellyfin.vulcan.lan` | 302 |
| 5380 | Technitium DNS admin UI | `dns.vulcan.lan` | 200 |
| 5061 | Kiwix | `kiwix.vulcan.lan` | 200 |

**8084 is the most consequential.** Open WebUI holds the Hermes
`API_SERVER_KEY` and the LLM-gateway configuration, and it answers 200 in the
clear on the LAN.

**Fix:** bind each to loopback. nginx already proxies all four, so there is no
functional loss. This is the lowest-risk, highest-value group.

---

## Group B — plaintext with no HTTPS equivalent at all

| Port | Service | Probe | Exposure |
|---|---|---|---|
| 9100 | node_exporter | 200 | filesystems, units, network, hardware inventory |
| 9115 | blackbox_exporter | 200 | probe targets and results |
| 9134 | zfs_exporter | 200 | pool/dataset layout and capacity |
| 9154 | postfix_exporter | 200 | mail flow volumes |
| 9166 | dovecot_exporter | 200 | IMAP session data |
| 9187 | postgres_exporter | 200 | database internals |
| 3100 | Loki HTTP | 404 | log ingest/query API |
| 9096 | Loki gRPC | — | log ingest |
| 9283 | Immich API metrics | 404 | |
| 9284 | Immich microservices metrics | 404 | |
| 61208 | Glances | 200 | live process and resource data |
| 8444 | opnsense-exporter backend | 200 | firewall/router metrics |
| 21065 | Home Assistant | 500 | |

The exporter set collectively publishes a detailed system inventory to anything
on the network. None of it is authenticated.

**Fix:** bind to loopback. Prometheus scrapes from this host, so this should be
invisible to it.

**Two caveats before moving these** — verify rather than assume:
- `blackbox_exporter` (9115) may be invoked by other hosts, not just locally.
- `node_exporter` (9100) is the conventional federation target; confirm nothing
  external scrapes it.

---

## Group C — plaintext non-HTTP

### 6383 — Redis, open from the LAN
**The most serious finding.** OpenProject's Redis is reachable from the LAN and
appears unauthenticated. An open Redis port is a well-known foothold: it can be
read, written, and in some configurations used to write files. This should be
bound to loopback first, ahead of everything else in this report.

### 1883 — MQTT (mosquitto), plaintext
Carries Home Assistant device traffic in the clear. The TLS port would be 8883.
This is the largest job in the report: it needs a certificate and a
client-by-client migration of every device and integration.

### 2525 — plain SMTP, wildcard-bound
Documented as the microVM submission path, but it is bound to a wildcard rather
than the bridge and **answers from the LAN**, banner `220 vulcan.lan ESMTP
Postfix`. Intent appears to be bridge-only; the bind does not match the intent.
Worth restricting to the microVM bridges.

---

## Already compliant — verified, not assumed

| Port(s) | Service | Basis |
|---|---|---|
| 22, 2022, 2222 | ssh, Eternal Terminal, gitea-ssh | protocol-encrypted |
| 443 | nginx | TLS; **every** vhost except hermes already redirected 80→443 |
| 465, 587 | Postfix submission | `smtpd_tls_security_level = "encrypt"` — enforced, not opportunistic |
| 993 | IMAPS | implicit TLS |
| 143 | IMAP plaintext | **loopback only** — confirmed closed from the LAN |
| 139, 445 | Samba | `server smb encrypt = "required"`, `server min protocol = SMB3_11` |
| 5432 | PostgreSQL | TLS configured with its own certificate |
| 4190 | ManageSieve | LAN-open; Dovecot sets `ssl = required` and `disable_plaintext_auth = yes` globally |
| 25 | Postfix MX | opportunistic TLS — correct and expected for an internet-facing MX; cannot demand TLS from arbitrary senders |

Dovecot's global posture is `ssl = required`, `ssl_min_protocol = TLSv1.2`,
`disable_plaintext_auth = yes`. The `ssl = no` at `dovecot.nix:159` applies to
the port-143 `inet_listener`, which is loopback-only and therefore not an
exposure.

---

## Remediation order

1. **Redis 6383 → loopback.** Highest severity, smallest change.
2. **Group A → loopback** (8084, 8096, 5380, 5061). Four services, no
   functional loss; nginx already fronts all four. 8084 first — it holds the
   Hermes key.
3. **2525 → bridge-only.** Align the bind with the documented intent.
4. **Group B exporters → loopback.** Confirm the 9115 and 9100 caveats first.
5. **MQTT → 8883 with TLS.** Largest effort; schedule separately.

---

## Hermes endpoint — resolved during this audit

`https://hermes.vulcan.lan` is **HTTPS only** (commit `f8c8468d0`):

- `/health` → 200, `ssl_verify_result=0`
- `/v1/*`, `/api/*` → 401 (reached the agent, key enforced)
- `/health/detailed` → 404 (blocked: unauthenticated upstream, leaks gateway
  state, platform inventory, agent count, exit reason and pid)
- `/` and everything else → 404
- plain HTTP → 301, does not serve

**Conduit connects successfully over HTTPS** — confirmed by the operator on
2026-08-02. This contradicted a source-level prediction that the app's Hermes
path would ignore the iOS trust store (it builds a bare Dio client with no
`badCertificateCallback`). In practice the CA installed on the phone is
honoured. The module comment records this so nobody "fixes" a future failure by
reverting to plaintext.

Note `forceSSL` means port 80 accepts the request before redirecting, so a
client misconfigured with `http://` still puts one Authorization header on the
wire before failing. Nothing server-side can prevent that — any listener must
read a request before it can answer — but Conduit's `followRedirects: false`
means it fails on the first request rather than leaking silently on every one.

---

## Limits of this audit

- **TCP only.** UDP listeners were not enumerated; DNS (53), MQTT discovery,
  mDNS and WireGuard-style services would need a separate pass.
- **Reachability was probed from vulcan itself over `end0`.** That proves the
  service answers on a LAN-facing interface, but does not model per-subnet
  firewalling between the wired and wireless networks.
- **Authentication was not assessed** except where noted. A service can be
  plaintext but authenticated, or encrypted but unauthenticated; this report
  classifies encryption and reachability, not authorisation.
- **Redis was confirmed reachable, not confirmed unauthenticated** — the port
  accepts connections; no credential probe was performed.
