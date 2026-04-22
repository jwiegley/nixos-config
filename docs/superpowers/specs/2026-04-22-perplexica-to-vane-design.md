# Perplexica → Vane Rebrand: Design Spec

**Status:** Approved (brainstormed 2026-04-22 with user)
**Scope:** Rename the existing Perplexica deployment on host `vulcan` to Vane across all NixOS modules, swap the container image, preserve on-disk state, and keep the standalone SearXNG backend intact.

---

## 1. Background

Upstream `ItzCrazyKns/Perplexica` was renamed to `ItzCrazyKns/Vane` on 2026-03-09 (commit `39c0f19`, `feat(app): rename to 'vane'`). The rename was more than cosmetic: Docker image names, container filesystem paths, and project identity all changed. Subsequent releases `v1.12.0` through `v1.12.2` (latest, 2026-04-10) added breaking internals — Langchain removed, a new session manager, focus-modes replaced by web/academic/discussions sources, Deep Research mode, and a Chromium/Playwright scraper — but the on-disk config and chat-history format for the `/home/<user>/data` volume remained compatible.

Our current deployment runs `itzcrazykns1337/perplexica:slim-latest` as a rootless quadlet container on `vulcan` under the dedicated `perplexica` user, proxied via nginx at `perplexica.vulcan.lan`, consuming the host's standalone SearXNG at `127.0.0.1:8890`.

## 2. Goals

- Every reference to `perplexica` in `/etc/nixos/` (except the historical filename in Git log) becomes `vane` after this change.
- Existing user data — AI provider API keys, chat history, uploaded files — carries over unmodified.
- Public endpoint becomes `https://vane.vulcan.lan/`.
- Zero loss of monitoring coverage (Glance tile, Nagios checks, Prometheus alerts, blackbox probe).
- Safe rollback if the new Vane image misbehaves against migrated data.

## 3. Non-Goals

- Exposing or configuring new Vane features (Deep Research mode, Chromium-scraper tuning, new widgets). Post-migration activity, out of scope.
- Switching to Vane's bundled-SearXNG (`:latest` full image). Our standalone `services.searx` is a first-class NixOS service with 18 customized engines, its own public `searxng.vulcan.lan` endpoint, query logging, SOPS-managed secrets, and dedicated Redis limiter — none of which Vane's bundled SearXNG provides. Decision recorded; out of scope for this migration.
- Pinning the container tag. User chose to stay on `slim-latest` floating, accepting the upstream-churn risk exemplified by the 2026-04-22 OpenClaw outage. Decision recorded; out of scope.
- Port change. Internal 3007 is retained; nginx terminates TLS on 443 regardless, so the port is never user-visible.

## 4. Architecture

Same rootless quadlet-container pattern as before, with these changes:

- **Container image:** `itzcrazykns1337/perplexica:slim-latest` → `itzcrazykns1337/vane:slim-latest`
- **Linux account:** `perplexica` user/group deleted, `vane` user/group created (fresh UID/GID assignment by NixOS)
- **Quadlet home:** `/var/lib/containers/perplexica` → `/var/lib/containers/vane`
- **State directory:** `/var/lib/perplexica/{data,uploads}` → `/var/lib/vane/{data,uploads}` (moved, not regenerated)
- **In-container mounts:** `/home/perplexica/{data,uploads}` → `/home/vane/{data,uploads}`
- **Public endpoint:** `perplexica.vulcan.lan` → `vane.vulcan.lan` (new TLS cert from local Step-CA)
- **Monitoring labels:** all alert/group/service-name tokens flip `perplexica` → `vane`

No changes to: host networking mode, internal port (3007), SearXNG backend (`127.0.0.1:8890`), CA trust mount (`/etc/ssl/certs/vulcan-ca.crt`), restart policy, or quadlet unit ordering.

## 5. Components & File Changes

### 5.1 Files to rename (git mv)

| From | To |
|---|---|
| `modules/services/perplexica.nix` | `modules/services/vane.nix` |
| `modules/users/home-manager/perplexica.nix` | `modules/users/home-manager/vane.nix` |
| `modules/monitoring/alerts/perplexica.yaml` | `modules/monitoring/alerts/vane.yaml` |

### 5.2 Files to modify (in-place string substitution)

| File | What changes |
|---|---|
| `hosts/vulcan/default.nix` | Two import-list entries: `perplexica.nix` → `vane.nix` (lines 55, 119) |
| `modules/users/container-users-dedicated.nix` | User/group definition block (lines 173–213), user list entries (226, 279), comment mentioning perplexica |
| `modules/users/home-manager/default.nix` | User list entry `"perplexica"` → `"vane"` (line 51) |
| `modules/services/searxng.nix` | Comment at line 99 (`Perplexica can use…` → `Vane can use…`) |
| `modules/services/glance.nix` | Dashboard tile `title`/`url` (lines 191–192) |
| `modules/services/blackbox-monitoring.nix` | Probe URL `https://perplexica.vulcan.lan` → `https://vane.vulcan.lan` (line 513) |
| `modules/services/nagios.nix` | `service_description "Perplexica HTTP"` (line 1778) and SSL check block (lines 2171–2172) |
| `certs/renew-nginx-certs.sh` | Domain entry `perplexica.vulcan.lan` → `vane.vulcan.lan` (line 48) |
| `docs/ports.txt` | Line 64: `3007 127.0.0.1 Perplexica AI search engine (host network)` → `3007 127.0.0.1 Vane AI answering engine (host network)` |

### 5.3 Content changes inside the renamed files

- **`modules/services/vane.nix`** — all `perplexica` tokens → `vane`; `perplexicaPort` variable → `vanePort`; nginx vhost key `"perplexica.vulcan.lan"` → `"vane.vulcan.lan"`; cert paths `/var/lib/nginx-certs/vane.vulcan.lan.{crt,key}`; tmpfiles owner `vane:vane`.
- **`modules/users/home-manager/vane.nix`** — `home-manager.users.vane`; home dir `/var/lib/containers/vane`; `virtualisation.quadlet.containers.vane`; image `itzcrazykns1337/vane:slim-latest`; env `DATA_DIR=/home/vane`; volumes `/var/lib/vane/data:/home/vane/data:rw` and `/var/lib/vane/uploads:/home/vane/uploads:rw`.
- **`modules/monitoring/alerts/vane.yaml`** — group `vane_alerts`; alert names `VaneServiceDown`, `VaneServiceFailed`, `VaneHTTPDown`, `VaneCertificateExpiringSoon`, `VaneCertificateExpiryCritical`; `systemd_unit_state{name="vane.service"}`; blackbox match `instance=~".*vane.*"`; cert name `vane.vulcan.lan`; annotation text updated; `service: vane` and `category: ai-search` labels.

### 5.4 Container-user block (`container-users-dedicated.nix`)

Replace the existing perplexica block (lines 173–213) with an equivalent vane block — same group/description pattern, home `/var/lib/containers/vane`, description "Container user for Vane AI answering engine." Remove all three `perplexica` string occurrences (lines 213, 226, 279 comment).

## 6. On-Disk State Migration

The current volumes contain:

- `/var/lib/perplexica/data/` — `config.toml` (or successor), chat history SQLite DB, saved provider credentials, preferences
- `/var/lib/perplexica/uploads/` — any user-uploaded files

Vane's v1.12.x changes are internal to the container (code refactor, not data-format migration). The `data/` directory layout is compatible across the Perplexica → Vane transition. Migration is therefore a simple directory rename after a full backup.

Operational sequence (executed as part of the cutover procedure in §7):

1. ZFS snapshot of the pool containing `/var/lib` (if `/var/lib` is on ZFS; otherwise rely on step 2 only).
2. `sudo cp -a /var/lib/perplexica /tank/Backups/perplexica-pre-vane-$(date +%F)`
3. `sudo cp -a /var/lib/containers/perplexica /tank/Backups/perplexica-home-pre-vane-$(date +%F)`
4. Stop old service.
5. `sudo mv /var/lib/perplexica /var/lib/vane`
6. `sudo mv /var/lib/containers/perplexica /var/lib/containers/vane`
7. `nixos-rebuild switch` (creates `vane` user/group with fresh UID/GID).
8. `sudo chown -R vane:vane /var/lib/vane /var/lib/containers/vane` — restores ownership under the new UID.
9. Restart `vane.service` (or equivalent user-scope unit) so podman re-reads the new mount paths.

## 7. Cutover Procedure

Ordered steps, intended to be executed task-by-task from the implementation plan:

1. **Pre-flight backups** (§6 steps 1–3). No config changes yet; reversible.
2. **Stage Nix changes** — all file renames + content edits from §5.1–5.4. `git add -A` but do not commit yet; confirm `git diff --cached` matches expected.
3. **USER-ACTION CHECKPOINT — TLS certificate issuance.** Halt and prompt the user. They run:
   ```
   sudo /etc/nixos/certs/renew-certificate.sh "vane.vulcan.lan" \
     -o "/var/lib/nginx-certs" -d 365 --owner "nginx:nginx"
   ```
   The agent does not execute this step autonomously; user cooperation with the Step-CA password / SOPS-held key is required. (No SOPS secret additions are needed for this migration — Vane stores its API keys in its web-UI-managed `data/` dir, not in SOPS.)
4. **Dry-build.** `sudo nixos-rebuild build --flake '.#vulcan'` — catches Nix syntax/type errors before switching.
5. **Stop old service.** From the `perplexica` user scope, stop the quadlet service cleanly.
6. **Move state directories** (§6 steps 5–6).
7. **Switch.** `sudo nixos-rebuild switch --flake '.#vulcan'` — creates `vane` user, applies new nginx vhost, loads new Prometheus rules, brings up `vane.service` (initially with ownership mismatch on the moved dirs).
8. **Fix ownership.** `sudo chown -R vane:vane /var/lib/vane /var/lib/containers/vane`.
9. **Restart service.** `sudo systemctl --user -M vane@ restart vane.service` (or equivalent for how our rootless quadlets are wired).
10. **DNS.** Ensure `vane.vulcan.lan` resolves on the LAN. If DNS is managed in this repo (NixOS `services.dnsmasq`, `services.unbound`, or a Home Assistant / OPNsense-managed zone), make the required entry part of this change; otherwise add it manually as a separate user action.
11. **Verify** per §8.
12. **Commit.** Single atomic commit, or two logical commits (name-map changes + any DNS bits), following the repo's existing commit-message style.

## 8. Verification

Post-switch checklist:

- [ ] `sudo systemctl --user -M vane@ status vane.service` — `active (running)`, no recent failures
- [ ] `sudo -u vane podman ps` — image is `itzcrazykns1337/vane:slim-latest`, container healthy
- [ ] `curl -sS -o /dev/null -w "%{http_code}\n" https://vane.vulcan.lan/` — returns `200`
- [ ] `openssl s_client -servername vane.vulcan.lan -connect vane.vulcan.lan:443 </dev/null 2>/dev/null | openssl x509 -noout -subject -dates` — cert CN = `vane.vulcan.lan`, not-expired
- [ ] Browser: `https://vane.vulcan.lan/` loads; existing chat history is visible; configured AI providers appear with saved API keys
- [ ] Fire a test query (pick a known-simple one) — SearXNG returns results, the LLM answers, citations render
- [ ] `journalctl --user -u vane.service -n 200` — no repeated errors after startup settles (~2 min)
- [ ] Prometheus UI shows `vane_alerts` group; no alerts firing
- [ ] Glance dashboard tile labeled "Vane" loads `https://vane.vulcan.lan`
- [ ] Nagios "Vane HTTP" and "SSL Cert: vane.vulcan.lan" checks both green
- [ ] Blackbox probe for `vane.vulcan.lan` shows `probe_success == 1`

## 9. Rollback

If verification fails irrecoverably:

1. Stop `vane.service`.
2. `sudo mv /var/lib/vane /var/lib/perplexica`
3. `sudo mv /var/lib/containers/vane /var/lib/containers/perplexica`
4. `git revert` the cutover commit(s); `sudo nixos-rebuild switch --flake '.#vulcan'` — recreates `perplexica` user, old nginx vhost, old alert rules, old service.
5. `sudo chown -R perplexica:perplexica /var/lib/perplexica /var/lib/containers/perplexica` (UID under the recreated perplexica user).
6. Restart old service; verify health.
7. If on-disk state is corrupted: `sudo rm -rf /var/lib/perplexica && sudo cp -a /tank/Backups/perplexica-pre-vane-$(date +%F) /var/lib/perplexica`.

The old TLS cert files for `perplexica.vulcan.lan` remain on disk throughout; leaving them in place is harmless and they become orphan files after rollback succeeds. Cleanup is a separate concern once the migration is stable for 7+ days.

## 10. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `PORT=3007` env var not honored by Vane's `server.js` | Low | High (service binds to 3000, nginx 502) | Next.js standalone server reads `PORT` from env by default. Verify during dry-build by inspecting `entrypoint.sh`. If broken, drop `PORT` env var and switch internal port to 3000 in both `vane.nix` and port registry. |
| On-disk data format incompatible (v1.12.0 Langchain removal side-effects) | Low | Medium (settings lost, must re-enter via UI) | Pre-flight backup (§6) is the answer. Also: pre-flight-test idea — temporarily deploy Vane with an empty data dir in a scratch vhost first to validate upstream before migrating real data. Deferred as optional if user wants belt+suspenders. |
| Vane's Chromium scraper consumes too much RAM on arm64 | Medium | Medium (OOM, service flaps) | Post-deploy, watch `journalctl` and `systemctl status` memory numbers. If problematic, disable the Chromium scraper (v1.12.2 feature) via whatever in-app toggle or env var Vane exposes; escalate to pin `:slim-v1.12.1` (last pre-Chromium release) if no toggle exists. |
| Floating `:slim-latest` pulls a broken image between rebuilds (as happened to OpenClaw) | Medium | High (service unreachable) | User accepted this risk (see §3). Mitigation is the existing Prometheus alerts (renamed to `VaneServiceDown` etc.) — they'll fire within minutes of a bad pull. Longer-term, the user can pin on any future rebuild by switching tag to `:slim-v1.12.x`. |
| Glance / Nagios / Prometheus caching old `perplexica` labels after switch | Low | Low (cosmetic) | Restart `glance.service`, `nagios.service`, and `prometheus.service` (the last via its built-in config reload) as part of cutover verification. |
| DNS entry for `vane.vulcan.lan` missing | Medium | High (service unreachable even though healthy) | §7 step 10 calls this out explicitly. Verify with `dig +short vane.vulcan.lan` before marking cutover complete. |

## 11. Open Items for Implementation Plan

- Confirm exact mechanism for stopping/starting the rootless user-scope quadlet service (project-level inspection in the implementation plan, not in this design).
- Confirm whether `/var/lib` is on ZFS (determines whether the step-1 snapshot is cheap/free or skipped).
- Confirm the nagios-hosts.nix and nagios-services references that also match `perplexica` — the tables above only list `modules/services/nagios.nix`. Implementation plan should grep a final time right before commit.
- Confirm whether `modules/services/searxng.nix` has a blackbox-exporter entry that happens to live elsewhere and references perplexica indirectly.

## 12. Approval Record

- Option A (full rebrand) — approved
- Option B (backup-and-migrate data) — approved
- Option A for port (keep 3007) — approved
- Option B for tag (floating `:slim-latest`) — approved against agent recommendation; user accepts upstream-churn risk
- Standalone SearXNG retained (not bundled) — approved after research

End of design.
