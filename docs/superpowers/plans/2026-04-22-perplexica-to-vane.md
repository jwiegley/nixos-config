# Perplexica → Vane Rebrand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the existing Perplexica deployment on host `vulcan` to Vane across all NixOS modules, swap the container image to `itzcrazykns1337/vane:slim-latest`, and migrate on-disk state in place — without losing chat history, configured API keys, or monitoring coverage.

**Architecture:** Purely declarative Nix-side work (file renames + in-place string substitutions) followed by an orchestrated host-side cutover (backup → stop → `mv` → `nixos-rebuild switch` → chown → restart → verify). Standalone SearXNG is retained unchanged.

**Tech Stack:** NixOS modules (`services.nginx`, `services.searx`, `services.nagios`, `virtualisation.quadlet`), home-manager user units, rootless podman quadlet, Prometheus/Alertmanager rules, nginx + Step-CA TLS.

---

## Preflight Context (collected before plan was written)

- **67 `perplexica` / `Perplexica` references** exist across 11 files outside of the spec and git history. Full list was captured by `grep -rIn "perplexica\|Perplexica\|PERPLEXICA" /etc/nixos/`; a fresh grep is part of Task 3 verification.
- **Current perplexica UID is 917** (`loginctl list-users`), **user linger is enabled**. The `perplexica@.host` scope is NOT visible to `machinectl` (which only lists nspawn containers). Service management uses `sudo -u perplexica XDG_RUNTIME_DIR=/run/user/917 systemctl --user …` or an `su - perplexica -c` wrapper.
- **`/var/lib` is on `/dev/nvme0n1p5` (ext4), NOT on ZFS.** No pool-level snapshot is available; `cp -a` to `/tank/Backups/` (which IS on ZFS) is the backup path. The optional ZFS-snapshot step in spec §6 is therefore skipped.
- **`autoSubUidGidRange = true`** for all container users. The `vane` user will get a fresh UID at rebuild time; no UID collision concerns.
- **No SOPS secrets** exist for perplexica today. None are introduced by this migration.

## File Structure

**Files to rename (`git mv`):**
- `modules/services/perplexica.nix` → `modules/services/vane.nix`
- `modules/users/home-manager/perplexica.nix` → `modules/users/home-manager/vane.nix`
- `modules/monitoring/alerts/perplexica.yaml` → `modules/monitoring/alerts/vane.yaml`

**Files to modify in place:**
- `hosts/vulcan/default.nix` — import paths (2 lines)
- `modules/users/container-users-dedicated.nix` — user block (lines 173–183), group (line 213), allowed-user (line 226), comment (line 279)
- `modules/users/home-manager/default.nix` — user list entry (line 51)
- `modules/services/searxng.nix` — comment (line 99)
- `modules/services/glance.nix` — dashboard tile (lines 191–192)
- `modules/services/blackbox-monitoring.nix` — probe URL (line 513)
- `modules/services/nagios.nix` — service checks (lines 1778, 2171–2172)
- `certs/renew-nginx-certs.sh` — domain list (line 48)
- `docs/ports.txt` — port registry (line 64)
- Content of the three renamed files — full token replacement from `perplexica` → `vane`

---

## Task 1: Preflight — Baseline grep + ownership capture

**Files:** (none modified)

- [ ] **Step 1.1:** Re-run the reference grep to capture the current baseline (counts may have shifted since plan was written).
   ```
   grep -rIn "perplexica\|Perplexica" /etc/nixos/ 2>/dev/null \
     | grep -v '\.git/\|/docs/superpowers/specs/\|/docs/superpowers/plans/' \
     | tee /tmp/perplexica-refs-before.txt | wc -l
   ```
   Expected: ≥ 67 matches. Keep the file; Task 13 diffs against it.

- [ ] **Step 1.2:** Capture the current perplexica UID/GID so we can match permissions during rollback if needed.
   ```
   getent passwd perplexica
   getent group perplexica
   sudo ls -lan /var/lib/perplexica /var/lib/containers/perplexica
   ```
   Save output to `/tmp/perplexica-ownership-before.txt`.

- [ ] **Step 1.3:** Confirm the perplexica service is currently healthy (so we're not accidentally migrating a broken state).
   ```
   curl -sS -o /dev/null -w "HTTP %{http_code}\n" https://perplexica.vulcan.lan/
   sudo -u perplexica XDG_RUNTIME_DIR=/run/user/917 \
     systemctl --user status perplexica.service --no-pager | head -15
   ```
   Expected: `HTTP 200` and `active (running)`.

- [ ] **Step 1.4:** No commit — this task is pure observation.

---

## Task 2: Create `modules/services/vane.nix`

**Files:**
- Create: `/etc/nixos/modules/services/vane.nix` (via `git mv` from perplexica.nix, then edit)

- [ ] **Step 2.1:** Rename the file.
   ```
   cd /etc/nixos && git mv modules/services/perplexica.nix modules/services/vane.nix
   ```

- [ ] **Step 2.2:** Rewrite the file's body. After the mv, the new file should read verbatim:

   ```nix
   {
     config,
     lib,
     pkgs,
     ...
   }:

   let
     # Vane internal port (host network mode, bound to localhost)
     vanePort = 3007;
   in
   {
     # Persistent data directory for Vane
     systemd.tmpfiles.rules = [
       "d /var/lib/vane 0750 vane vane -"
       "d /var/lib/vane/data 0750 vane vane -"
       "d /var/lib/vane/uploads 0750 vane vane -"
     ];

     # Nginx reverse proxy configuration
     services.nginx.virtualHosts."vane.vulcan.lan" = {
       forceSSL = true;
       sslCertificate = "/var/lib/nginx-certs/vane.vulcan.lan.crt";
       sslCertificateKey = "/var/lib/nginx-certs/vane.vulcan.lan.key";

       locations."/" = {
         proxyPass = "http://127.0.0.1:${toString vanePort}";
         proxyWebsockets = true;
         extraConfig = ''
           proxy_buffering off;
           proxy_read_timeout 300s;
           proxy_connect_timeout 60s;
           proxy_send_timeout 300s;
           client_max_body_size 50M;
         '';
       };
     };

     # Allow nginx to access Vane on loopback
     networking.firewall.interfaces."lo".allowedTCPPorts = [ vanePort ];
   }
   ```

   The only **semantic change** from the original is `perplexica` → `vane` in all identifiers, hostname, cert paths, tmpfiles rules, and comments. The port (3007), tmpfiles mode (0750), nginx proxy settings, and firewall rule are all preserved byte-for-byte.

- [ ] **Step 2.3:** Verify Nix syntax on the file alone.
   ```
   nix-instantiate --parse /etc/nixos/modules/services/vane.nix >/dev/null && echo "OK"
   ```
   Expected: `OK`.

- [ ] **Step 2.4:** No commit yet (bundled in Task 10).

---

## Task 3: Create `modules/users/home-manager/vane.nix`

**Files:**
- Create: `/etc/nixos/modules/users/home-manager/vane.nix` (via `git mv` from perplexica.nix, then edit)

- [ ] **Step 3.1:** Rename the file.
   ```
   cd /etc/nixos && git mv modules/users/home-manager/perplexica.nix modules/users/home-manager/vane.nix
   ```

- [ ] **Step 3.2:** Rewrite the file's body. After the mv:

   ```nix
   {
     config,
     lib,
     pkgs,
     inputs,
     ...
   }:

   {
     home-manager.users.vane =
       {
         config,
         lib,
         pkgs,
         ...
       }:
       {
         imports = [
           inputs.quadlet-nix.homeManagerModules.quadlet
         ];

         home.stateVersion = "24.11";
         home.username = "vane";
         home.homeDirectory = "/var/lib/containers/vane";

         home.sessionVariables = {
           PODMAN_USERNS = "keep-id";
         };

         home.file.".keep".text = "";

         home.packages = with pkgs; [
           podman
           coreutils
         ];

         # Rootless quadlet container using host networking for SearXNG access
         virtualisation.quadlet.containers.vane = {
           autoStart = true;

           containerConfig = {
             # Use slim image (no bundled SearXNG — we use the existing instance)
             image = "itzcrazykns1337/vane:slim-latest";

             # Host networking allows direct access to host's localhost services
             # (SearXNG at 127.0.0.1:8890, etc.)
             networks = [ "host" ];

             environments = {
               # Bind to localhost only (host network mode)
               HOSTNAME = "127.0.0.1";
               PORT = "3007";

               # Point to the existing SearXNG instance
               SEARXNG_API_URL = "http://127.0.0.1:8890";

               # Data directory inside container (maps to our volume)
               DATA_DIR = "/home/vane";

               # Trust local Step-CA for outbound HTTPS verification
               NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/vulcan-ca.crt";
             };

             # Persistent data volumes
             volumes = [
               "/var/lib/vane/data:/home/vane/data:rw"
               "/var/lib/vane/uploads:/home/vane/uploads:rw"
               # Mount Step-CA root certificate for HTTPS connections to local services
               "/etc/ssl/certs/vulcan-ca.crt:/etc/ssl/certs/vulcan-ca.crt:ro"
             ];
           };

           unitConfig = {
             After = [
               "network-online.target"
               "sops-nix.service"
             ];
             Wants = [ "sops-nix.service" ];
             StartLimitIntervalSec = "300";
             StartLimitBurst = "5";
           };

           serviceConfig = {
             Restart = "always";
             RestartSec = "15s";
             TimeoutStartSec = "300";
           };
         };
       };
   }
   ```

   Changes vs. original: `perplexica` → `vane` everywhere (user, home path, quadlet key, image, DATA_DIR, volume host+container paths).

- [ ] **Step 3.3:** Verify Nix syntax.
   ```
   nix-instantiate --parse /etc/nixos/modules/users/home-manager/vane.nix >/dev/null && echo "OK"
   ```

- [ ] **Step 3.4:** No commit yet.

---

## Task 4: Create `modules/monitoring/alerts/vane.yaml`

**Files:**
- Create: `/etc/nixos/modules/monitoring/alerts/vane.yaml` (via `git mv` from perplexica.yaml, then edit)

- [ ] **Step 4.1:** Rename the file.
   ```
   cd /etc/nixos && git mv modules/monitoring/alerts/perplexica.yaml modules/monitoring/alerts/vane.yaml
   ```

- [ ] **Step 4.2:** Rewrite the file's body:

   ```yaml
   groups:
     - name: vane_alerts
       interval: 60s
       rules:
         # Vane Container Service Alerts
         - alert: VaneServiceDown
           expr: |
             systemd_unit_state{
               name="vane.service",
               state="active",
               type="service"
             } == 0
           for: 3m
           labels:
             severity: critical
             category: ai-search
             service: vane
           annotations:
             summary: "Vane service is down"
             description: "Vane AI answering container is not active. Service is unavailable."

         - alert: VaneServiceFailed
           expr: |
             systemd_unit_state{
               name="vane.service",
               state="failed",
               type="service"
             } == 1
           for: 1m
           labels:
             severity: critical
             category: ai-search
             service: vane
           annotations:
             summary: "Vane service has failed"
             description: "Vane container is in failed state. Check logs with: journalctl -u vane"

         # HTTP Health Check (via blackbox exporter)
         - alert: VaneHTTPDown
           expr: |
             probe_success{job="blackbox_https_local", instance=~".*vane.*"} == 0
           for: 5m
           labels:
             severity: critical
             category: ai-search
             service: vane
           annotations:
             summary: "Vane HTTP endpoint is unreachable"
             description: "Vane web interface at {{ $labels.instance }} has been unreachable for more than 5 minutes."

         # SSL Certificate Alerts
         - alert: VaneCertificateExpiringSoon
           expr: |
             certificate_days_until_expiry{name="vane.vulcan.lan"} <= 30
             and
             certificate_days_until_expiry{name="vane.vulcan.lan"} > 7
           for: 1h
           labels:
             severity: warning
             category: certificates
             service: vane
           annotations:
             summary: "Vane SSL certificate expiring soon"
             description: "SSL certificate for vane.vulcan.lan expires in {{ $value }} days. Run certificate renewal."

         - alert: VaneCertificateExpiryCritical
           expr: |
             certificate_days_until_expiry{name="vane.vulcan.lan"} <= 7
           for: 30m
           labels:
             severity: critical
             category: certificates
             service: vane
           annotations:
             summary: "Vane SSL certificate expiring very soon"
             description: "SSL certificate for vane.vulcan.lan expires in {{ $value }} days. Immediate renewal required."
   ```

- [ ] **Step 4.3:** YAML syntax sanity-check.
   ```
   python3 -c "import yaml,sys; yaml.safe_load(open('/etc/nixos/modules/monitoring/alerts/vane.yaml'))" && echo "OK"
   ```

- [ ] **Step 4.4:** No commit yet.

---

## Task 5: Update `hosts/vulcan/default.nix` imports

**Files:**
- Modify: `/etc/nixos/hosts/vulcan/default.nix:55,119`

- [ ] **Step 5.1:** Change line 55:
   - From: `    ../../modules/users/home-manager/perplexica.nix`
   - To:   `    ../../modules/users/home-manager/vane.nix`

- [ ] **Step 5.2:** Change line 119:
   - From: `    ../../modules/services/perplexica.nix`
   - To:   `    ../../modules/services/vane.nix`

- [ ] **Step 5.3:** No commit yet.

---

## Task 6: Update `modules/users/container-users-dedicated.nix`

**Files:**
- Modify: `/etc/nixos/modules/users/container-users-dedicated.nix` (lines 173–183 user block, 213 group, 226 allowed-user, 279 comment)

- [ ] **Step 6.1:** Replace the perplexica user block (lines 173–183) with a vane block. The replacement is a single `perplexica` → `vane` substitution in every occurrence within the block:

   ```nix
         vane = {
           isSystemUser = true;
           group = "vane";
           home = "/var/lib/containers/vane";
           createHome = true;
           shell = pkgs.bash;
           autoSubUidGidRange = true;
           linger = true;
           extraGroups = [ "podman" ];
           description = "Container user for Vane AI answering engine";
         };
   ```

- [ ] **Step 6.2:** Replace the group entry on line 213:
   - From: `      perplexica = { };`
   - To:   `      vane = { };`

- [ ] **Step 6.3:** Replace the allowed-user entry on line 226:
   - From: `    "perplexica"`
   - To:   `    "vane"`

- [ ] **Step 6.4:** Replace the comment on line 279:
   - From: `  # Note: perplexica currently has no SOPS secrets (configured via web UI)`
   - To:   `  # Note: vane currently has no SOPS secrets (configured via web UI)`

- [ ] **Step 6.5:** No commit yet.

---

## Task 7: Update `modules/users/home-manager/default.nix`

**Files:**
- Modify: `/etc/nixos/modules/users/home-manager/default.nix:51`

- [ ] **Step 7.1:** Line 51 entry:
   - From: `        "perplexica"`
   - To:   `        "vane"`

- [ ] **Step 7.2:** No commit yet.

---

## Task 8: Update monitoring and service cross-references

**Files:**
- Modify: `/etc/nixos/modules/services/searxng.nix:99`
- Modify: `/etc/nixos/modules/services/glance.nix:191-192`
- Modify: `/etc/nixos/modules/services/blackbox-monitoring.nix:513`
- Modify: `/etc/nixos/modules/services/nagios.nix:1778,2171-2172`
- Modify: `/etc/nixos/certs/renew-nginx-certs.sh:48`
- Modify: `/etc/nixos/docs/ports.txt:64`

- [ ] **Step 8.1:** `searxng.nix` line 99 comment:
   - From: `        # Enable JSON output format so Perplexica can use SearXNG as its search backend`
   - To:   `        # Enable JSON output format so Vane can use SearXNG as its search backend`

- [ ] **Step 8.2:** `glance.nix` lines 191–192:
   - From:
     ```
                             title = "Perplexica";
                             url = "https://perplexica.vulcan.lan";
     ```
   - To:
     ```
                             title = "Vane";
                             url = "https://vane.vulcan.lan";
     ```

- [ ] **Step 8.3:** `blackbox-monitoring.nix` line 513:
   - From: `                  "https://perplexica.vulcan.lan"`
   - To:   `                  "https://vane.vulcan.lan"`

- [ ] **Step 8.4:** `nagios.nix`:
   - Line 1778 (`Perplexica HTTP` → `Vane HTTP`): exact `service_description     Perplexica HTTP` → `service_description     Vane HTTP`.
   - Lines 2171–2172: both `perplexica.vulcan.lan` → `vane.vulcan.lan` (in `service_description` and `check_command`).

- [ ] **Step 8.5:** `renew-nginx-certs.sh` line 48:
   - From: `    "perplexica.vulcan.lan"`
   - To:   `    "vane.vulcan.lan"`

- [ ] **Step 8.6:** `docs/ports.txt` line 64:
   - From: `3007 127.0.0.1 Perplexica AI search engine (host network)`
   - To:   `3007 127.0.0.1 Vane AI answering engine (host network)`

- [ ] **Step 8.7:** No commit yet.

---

## Task 9: Full-tree verification — no stray `perplexica` in config

**Files:** (none modified)

- [ ] **Step 9.1:** Grep the repo.
   ```
   grep -rIn "perplexica\|Perplexica\|PERPLEXICA" /etc/nixos/ 2>/dev/null \
     | grep -v '\.git/\|/docs/superpowers/specs/\|/docs/superpowers/plans/'
   ```
   Expected: **zero matches** (the spec and plan files retain the historical name; git history is excluded).

   If any matches appear, return to the relevant task and fix them before proceeding.

- [ ] **Step 9.2:** Grep for the new `vane` tokens to sanity-check counts.
   ```
   grep -rIn "\bvane\b\|Vane\b" /etc/nixos/ 2>/dev/null \
     | grep -v '\.git/\|/docs/superpowers/' | wc -l
   ```
   Expected: at least 50 matches (replacing the 67 perplexica refs, minus those that were comments or unique phrasing).

---

## Task 10: Dry-build and stage commit

**Files:**
- All files touched in Tasks 2–8

- [ ] **Step 10.1:** Run the nix flake check first (fast syntax-level validation).
   ```
   cd /etc/nixos && nix flake check --no-build 2>&1 | tail -40
   ```
   Expected: no evaluation errors. Warnings are acceptable.

- [ ] **Step 10.2:** Run the full dry build.
   ```
   sudo nixos-rebuild build --flake '.#vulcan' 2>&1 | tail -60
   ```
   Expected: build succeeds with no errors. The final `result` symlink in `/etc/nixos/` should update.

- [ ] **Step 10.3:** Inspect the diff summary.
   ```
   git -C /etc/nixos status
   git -C /etc/nixos diff --stat
   ```
   Expected: three renames (R100), seven modifications, plan+spec untouched (committed separately).

- [ ] **Step 10.4:** Commit the Nix changes as one atomic commit.
   ```
   cd /etc/nixos
   git add -A modules/services/vane.nix \
              modules/services/perplexica.nix \
              modules/users/home-manager/vane.nix \
              modules/users/home-manager/perplexica.nix \
              modules/monitoring/alerts/vane.yaml \
              modules/monitoring/alerts/perplexica.yaml \
              hosts/vulcan/default.nix \
              modules/users/container-users-dedicated.nix \
              modules/users/home-manager/default.nix \
              modules/services/searxng.nix \
              modules/services/glance.nix \
              modules/services/blackbox-monitoring.nix \
              modules/services/nagios.nix \
              certs/renew-nginx-certs.sh \
              docs/ports.txt
   git commit -m "$(cat <<'MSG'
   vane: rename Perplexica deployment to Vane (upstream rebrand)

   Upstream ItzCrazyKns/Perplexica was renamed to ItzCrazyKns/Vane on
   2026-03-09. This mirrors the rename across every config and monitoring
   touchpoint on vulcan:

     - services/perplexica.nix → services/vane.nix
     - home-manager/perplexica.nix → home-manager/vane.nix
     - alerts/perplexica.yaml → alerts/vane.yaml
     - container user perplexica → vane
     - nginx vhost perplexica.vulcan.lan → vane.vulcan.lan
     - container image itzcrazykns1337/perplexica:slim-latest
       → itzcrazykns1337/vane:slim-latest
     - monitoring labels, Glance tile, Nagios checks, blackbox probe,
       port-registry entry, cert-renewal domain list all renamed

   Internal port (3007), SearXNG backend, restart policy, TLS trust
   config, and quadlet ordering are unchanged. On-disk state migration
   (/var/lib/perplexica → /var/lib/vane) and cert issuance happen at
   deploy time, not in this commit.

   Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
   MSG
   )"
   ```

- [ ] **Step 10.5:** Verify the commit.
   ```
   git -C /etc/nixos log -1 --stat
   ```
   Expected: 15 files changed, three marked as renames.

---

## Task 11: USER CHECKPOINT — TLS certificate issuance

**This step requires hands-on user action.** The agent MUST NOT execute `renew-certificate.sh` autonomously; it requires the Step-CA password / SOPS-held key.

- [ ] **Step 11.1:** Prompt the user with this exact block:

   ```
   ⛔ USER ACTION REQUIRED — TLS certificate for vane.vulcan.lan

   Please issue the cert by running:

     sudo /etc/nixos/certs/renew-certificate.sh "vane.vulcan.lan" \
       -o "/var/lib/nginx-certs" -d 365 --owner "nginx:nginx"

   Then confirm:
     sudo ls -la /var/lib/nginx-certs/vane.vulcan.lan.{crt,key}
     sudo openssl x509 -in /var/lib/nginx-certs/vane.vulcan.lan.crt \
       -noout -subject -dates

   Expected: crt + key owned by nginx:nginx, mode 640/600; subject CN
   includes vane.vulcan.lan; notAfter ≥ 365 days out.

   Reply when done and I'll continue with the cutover.
   ```

- [ ] **Step 11.2:** When the user confirms, verify cert files exist before proceeding.
   ```
   sudo test -f /var/lib/nginx-certs/vane.vulcan.lan.crt \
     && sudo test -f /var/lib/nginx-certs/vane.vulcan.lan.key \
     && echo "OK: cert present" || echo "FAIL: cert missing"
   ```

---

## Task 12: USER CHECKPOINT — Confirm cutover authorization

**Why a checkpoint:** Task 13 runs `nixos-rebuild switch`, stops a running service, moves state directories, and deletes a system user. This affects a running service visible to the user's LAN and is not trivially reversible without the backups from Task 13. Per session guidance, get explicit authorization before executing.

- [ ] **Step 12.1:** Prompt the user:

   ```
   Ready to execute the cutover. This will:
     1. cp -a /var/lib/perplexica → /tank/Backups/perplexica-pre-vane-<date>
     2. cp -a /var/lib/containers/perplexica → /tank/Backups/perplexica-home-pre-vane-<date>
     3. systemctl --user stop perplexica.service (as perplexica user)
     4. mv /var/lib/perplexica → /var/lib/vane
     5. mv /var/lib/containers/perplexica → /var/lib/containers/vane
     6. sudo nixos-rebuild switch --flake '.#vulcan'
     7. sudo chown -R vane:vane /var/lib/vane /var/lib/containers/vane
     8. Start vane.service (as vane user, first time)

   Downtime: ~60-120 seconds while nixos-rebuild switch runs.

   Reply "proceed" to continue, or "hold" to pause and review.
   ```

- [ ] **Step 12.2:** Wait for `proceed`. If `hold`, stop the plan and do not execute Task 13.

---

## Task 13: Cutover execution

**Files:** (system state, no repo edits)

- [ ] **Step 13.1:** Backup state directories to ZFS-backed `/tank/Backups/`.
   ```
   BACKUP_DATE=$(date +%Y-%m-%d-%H%M)
   sudo mkdir -p /tank/Backups/vane-migration
   sudo cp -a /var/lib/perplexica \
     /tank/Backups/vane-migration/perplexica-pre-vane-${BACKUP_DATE}
   sudo cp -a /var/lib/containers/perplexica \
     /tank/Backups/vane-migration/perplexica-home-pre-vane-${BACKUP_DATE}
   ```
   Expected: both `cp` commands exit 0. Size should match originals (`du -sh` each side to confirm).

- [ ] **Step 13.2:** Stop the running perplexica service cleanly so any in-flight DB writes flush.
   ```
   sudo -u perplexica XDG_RUNTIME_DIR=/run/user/917 \
     systemctl --user stop perplexica.service
   sudo -u perplexica XDG_RUNTIME_DIR=/run/user/917 \
     systemctl --user status perplexica.service --no-pager 2>&1 | head -5
   ```
   Expected: status shows `inactive (dead)` or "not-found" if already torn down.

- [ ] **Step 13.3:** Move state directories in place.
   ```
   sudo mv /var/lib/perplexica /var/lib/vane
   sudo mv /var/lib/containers/perplexica /var/lib/containers/vane
   sudo ls -lan /var/lib/vane /var/lib/containers/vane | head -20
   ```
   Expected: directories exist at new paths; ownership still shows UID 917 / GID 917 (the old perplexica numeric IDs — will be re-chowned post-rebuild).

   Note: between this step and Step 13.6 there is an intentional window where `/var/lib/vane/` exists but is owned by a soon-to-be-deleted UID. This is expected and resolved by the post-rebuild chown.

- [ ] **Step 13.4:** Run the full switch.
   ```
   sudo nixos-rebuild switch --flake '.#vulcan' 2>&1 | tee /tmp/vane-switch.log | tail -50
   ```
   Expected: exit 0, generation increment, new `vane` user created, `perplexica` user removed. Nginx reloaded. Prometheus reloaded.

- [ ] **Step 13.5:** Verify the vane user now exists and capture its new UID.
   ```
   getent passwd vane
   getent group vane
   loginctl list-users | grep -E 'vane|perplexica'
   ```
   Expected: `vane` present with linger=yes. `perplexica` should be gone.

- [ ] **Step 13.6:** Chown the migrated directories to the new vane UID.
   ```
   sudo chown -R vane:vane /var/lib/vane /var/lib/containers/vane
   sudo ls -lan /var/lib/vane | head -5
   ```
   Expected: all files owned by the new vane numeric UID/GID.

- [ ] **Step 13.7:** Ensure the vane user-scope service started (autoStart=true should have triggered it via home-manager activation).
   ```
   VANE_UID=$(id -u vane)
   sudo -u vane XDG_RUNTIME_DIR=/run/user/${VANE_UID} \
     systemctl --user status vane.service --no-pager | head -20
   ```
   Expected: `active (running)`. If `inactive`, start it manually:
   ```
   sudo -u vane XDG_RUNTIME_DIR=/run/user/${VANE_UID} \
     systemctl --user start vane.service
   ```

---

## Task 14: DNS and endpoint verification

**Files:** (none modified)

- [ ] **Step 14.1:** DNS resolution.
   ```
   dig +short vane.vulcan.lan
   ```
   Expected: vulcan's LAN IP (same address that `perplexica.vulcan.lan` used to resolve to — they should be aliases of the same host). If empty, user must add the DNS record (OPNsense / TechnitiumDNS / dnsmasq depending on setup).

- [ ] **Step 14.2:** HTTPS round trip.
   ```
   curl -sS -o /dev/null -w "HTTP %{http_code}  TLS %{ssl_verify_result}\n" \
     --cacert /etc/ssl/certs/vulcan-ca.crt https://vane.vulcan.lan/
   ```
   Expected: `HTTP 200  TLS 0`.

- [ ] **Step 14.3:** Cert subject check.
   ```
   openssl s_client -servername vane.vulcan.lan -connect vane.vulcan.lan:443 \
     </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
   ```
   Expected: subject contains `CN=vane.vulcan.lan`; issuer is the local Step-CA; notAfter roughly 365 days out.

---

## Task 15: Functional smoke test — user validation

**Files:** (none modified)

- [ ] **Step 15.1:** Prompt the user:

   ```
   Vane is up at https://vane.vulcan.lan/. Please verify in a browser:

     1. Login/home screen loads.
     2. Previously-configured AI providers appear with saved keys.
     3. Existing chat history (if any) is visible.
     4. Send a test query — SearXNG returns results, the LLM answers,
        citations render.

   Reply "pass" if all four succeed, or paste any errors.
   ```

- [ ] **Step 15.2:** If PASS, proceed to Task 16. If FAIL, hand back with the error output for root-cause analysis; rollback plan is documented in spec §9.

---

## Task 16: Monitoring sanity check

**Files:** (none modified)

- [ ] **Step 16.1:** Confirm Prometheus loaded the new alert group.
   ```
   curl -sS https://prometheus.vulcan.lan/api/v1/rules \
     --cacert /etc/ssl/certs/vulcan-ca.crt \
     | python3 -c "import sys,json; d=json.load(sys.stdin); \
       print([g['name'] for g in d['data']['groups'] \
              if 'vane' in g['name'].lower() or 'perplexica' in g['name'].lower()])"
   ```
   Expected: `['vane_alerts']` (no stale `perplexica_alerts`).

- [ ] **Step 16.2:** Blackbox probe should be hitting the new endpoint.
   ```
   curl -sS https://prometheus.vulcan.lan/api/v1/query?query=probe_success%7Binstance%3D%22https%3A%2F%2Fvane.vulcan.lan%22%7D \
     --cacert /etc/ssl/certs/vulcan-ca.crt \
     | python3 -m json.tool | head -30
   ```
   Expected: `"value": [<ts>, "1"]`.

- [ ] **Step 16.3:** Nagios status.
   ```
   # Through the web UI — or via the nagios CLI if available:
   sudo systemctl reload nagios
   # Then browse https://nagios.vulcan.lan and confirm "Vane HTTP" and
   # "SSL Cert: vane.vulcan.lan" checks go green within one check-cycle.
   ```

- [ ] **Step 16.4:** Glance tile.
   - Open `https://glance.vulcan.lan` (or wherever Glance is mounted).
   - Confirm the tile now reads `Vane` and links to `https://vane.vulcan.lan`.

---

## Task 17: Cleanup and final commit

**Files:** (none modified unless stale artifacts are found)

- [ ] **Step 17.1:** Old TLS cert files for `perplexica.vulcan.lan` can remain on disk for 7 days as a rollback safety net. They are referenced by nothing in the new config. Schedule (mentally or as a follow-up task) to remove them after the migration is stable:
   ```
   # After 7 days of green monitoring:
   sudo rm /var/lib/nginx-certs/perplexica.vulcan.lan.crt \
           /var/lib/nginx-certs/perplexica.vulcan.lan.key
   ```

- [ ] **Step 17.2:** Old backup copies under `/tank/Backups/vane-migration/` can be pruned after 30 days. Leave them for now.

- [ ] **Step 17.3:** No further commit required — Task 10 was the single atomic commit for this migration.

---

## Rollback procedure (reference only; full details in spec §9)

If any task after Task 13 Step 13.4 fails catastrophically:

1. `sudo -u vane XDG_RUNTIME_DIR=/run/user/$(id -u vane) systemctl --user stop vane.service`
2. `sudo mv /var/lib/vane /var/lib/perplexica`
3. `sudo mv /var/lib/containers/vane /var/lib/containers/perplexica`
4. `git -C /etc/nixos revert HEAD` (or the specific commit SHA from Task 10.5)
5. `sudo nixos-rebuild switch --flake '.#vulcan'`
6. `sudo chown -R perplexica:perplexica /var/lib/perplexica /var/lib/containers/perplexica`
7. Verify `https://perplexica.vulcan.lan/` returns 200.
8. If state is corrupt: `sudo rm -rf /var/lib/perplexica && sudo cp -a /tank/Backups/vane-migration/perplexica-pre-vane-* /var/lib/perplexica`.

End of plan.
