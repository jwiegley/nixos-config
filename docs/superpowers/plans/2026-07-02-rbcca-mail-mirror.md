# RBCCA Mail Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror `jwiegley@rbcca.org` (Google Workspace) into a local Dovecot mailbox and enable send-as through Gmail SMTP, replicating the existing `bia` template exactly.

**Architecture:** A new `rbcca` system user gets its own maildir at `/var/mail/rbcca`, filled by an `mbsync` pull (INBOX only, 15-min timer) declared via the existing `mkMbsyncService` helper. Postfix sender-canonical + sender-dependent-relay maps route outbound `jwiegley@rbcca.org` mail through `[smtp.gmail.com]:587` with per-sender SASL auth. Monitoring parity: Nagios timer checks, promtail log scrape, FTS staleness list.

**Tech Stack:** NixOS flake (`.#vulcan`), isync/mbsync, Dovecot, Postfix, sops-nix (secrets flake input at `git+file:///etc/nixos/secrets`), Nagios, promtail.

**Spec:** `docs/superpowers/specs/2026-06-27-rbcca-mail-mirror-design.md`

## Global Constraints

- uid/gid **1013** for user/group `rbcca` (next free after assembly=1011, bia=1012).
- SOPS secret name: **`rbcca-imap-bahai-org`** (as created in sops, following the `bia-imap-bahai-org` style).
- Remote: `imap.gmail.com:993` / user `jwiegley@rbcca.org`; sync **INBOX only, Pull**, timer **15min**, `trash = "[Gmail]/Trash"`.
- **NEVER display the app password or any decrypted secret in terminal output.** The user performs all `sops` edits interactively. Never run `sops -d`.
- Do not change `system.stateVersion` (25.11).
- Run `nix fmt` before each commit; commits go directly to `main` (repo convention — see recent history).
- New files must be `git add`ed before any `nix eval`/build (flake source = git tree; untracked files are invisible to evaluation).
- The full build (Task 7) MUST come after the secrets exist (Task 1) — sops-nix validates key presence at build time.

---

### Task 1: Add secrets (USER ACTION — interactive, agent must not touch the password)

**Files:**
- Modify: `/etc/nixos/secrets/secrets.yaml` (via `sops`, user-driven)
- Modify: `/etc/nixos/flake.lock` (via `nix flake update secrets`)

**Interfaces:**
- Produces: SOPS key `rbcca-imap-bahai-org` (raw app password, 16 chars, **spaces removed**) consumed by Task 3's `PassCmd`; a new line inside the existing `postfix-secrets` value consumed by Postfix `smtp_sasl_password_maps` (Task 5).

- [ ] **Step 1 (USER): Edit the secrets file**

Run in a terminal (not via the agent):

```bash
sops /etc/nixos/secrets/secrets.yaml
```

Make two changes:

1. Add a new top-level key (value = the 16-character Google app password with the display spaces removed):

   ```yaml
   rbcca-imap-bahai-org: abcdabcdabcdabcd
   ```

2. Inside the existing multi-line `postfix-secrets` value, add a line for the new sender, copying the exact format of the existing `john@bia.bahai.org` line:

   ```
   jwiegley@rbcca.org    jwiegley@rbcca.org:abcdabcdabcdabcd
   ```

- [ ] **Step 2 (USER or agent): Commit the secrets repo and refresh the flake input**

```bash
cd /etc/nixos/secrets && git add secrets.yaml && git commit -m "Add rbcca IMAP/SMTP credentials"
cd /etc/nixos && nix flake update secrets
```

- [ ] **Step 3: Verify (safe — key names only, values stay encrypted)**

Run: `grep -c '^rbcca-imap-bahai-org:' /etc/nixos/secrets/secrets.yaml`
Expected: `1`

Run: `grep -A2 '"secrets"' /etc/nixos/flake.lock | grep rev` and confirm the rev changed (matches `git -C /etc/nixos/secrets rev-parse HEAD`).

---

### Task 2: Create the rbcca user module and import it

**Files:**
- Create: `modules/users/rbcca.nix`
- Modify: `hosts/vulcan/default.nix:38` (insert import after the `bia.nix` line)

**Interfaces:**
- Produces: system user/group `rbcca` (uid/gid 1013, home `/home/rbcca`) consumed by Tasks 3–4.

- [ ] **Step 1: Write `modules/users/rbcca.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}:

{
  users = {
    groups.rbcca = {
      gid = 1013;
    };

    users.rbcca = {
      isNormalUser = true;
      uid = 1013;
      group = "rbcca";
      home = "/home/rbcca";
      description = "RBCCA mirror user (jwiegley@rbcca.org)";
    };
  };
}
```

- [ ] **Step 2: Add the import in `hosts/vulcan/default.nix`**

Find (line ~38):

```nix
    ../../modules/users/bia.nix
```

Insert directly after it:

```nix
    ../../modules/users/rbcca.nix
```

- [ ] **Step 3: Stage and verify by evaluation**

```bash
cd /etc/nixos && git add modules/users/rbcca.nix hosts/vulcan/default.nix
nix eval '.#nixosConfigurations.vulcan.config.users.users.rbcca.uid'
```

Expected output: `1013`

- [ ] **Step 4: Format and commit**

```bash
cd /etc/nixos && nix fmt modules/users/rbcca.nix hosts/vulcan/default.nix
git add modules/users/rbcca.nix hosts/vulcan/default.nix
git commit -m "users: add rbcca mirror user (jwiegley@rbcca.org)"
```

---

### Task 3: Add the mbsync service block

**Files:**
- Modify: `modules/services/mbsync.nix:125-126` (append a `mkMbsyncService` block after the bia block, inside `imports`)

**Interfaces:**
- Consumes: user/group `rbcca` (Task 2); SOPS key `rbcca-imap-bahai-org` (Task 1).
- Produces: `mbsync-rbcca.service` + `.timer`, `mbsync-rbcca-health-check.service` + `.timer`, `/etc/mbsync/mbsyncrc-rbcca`, log dir `/var/log/mbsync-rbcca/`, metrics file `mbsync_rbcca.prom` — consumed by Tasks 6 and 8.

- [ ] **Step 1: Append the block**

In `modules/services/mbsync.nix`, the bia block ends at line 125 with `})` followed by the closing `];` of `imports` (line 126). Insert between them:

```nix
    # RBCCA configuration (jwiegley@rbcca.org via Google Workspace)
    (mkMbsyncService {
      name = "rbcca";
      user = "rbcca";
      group = "rbcca";
      secretName = "rbcca-imap-bahai-org";
      trash = "[Gmail]/Trash";

      remoteConfig = ''
        Host imap.gmail.com
        User jwiegley@rbcca.org
        PassCmd "cat /run/secrets/rbcca-imap-bahai-org"
        Port 993
        TLSType IMAPS
        CertificateFile /etc/ssl/certs/ca-certificates.crt
      '';

      channels = ''
        # Google Workspace to Dovecot channel
        Channel gmail-all
        Far :rbcca-remote:
        Near :dovecot-local:
        Patterns INBOX !"[Gmail]/All Mail" !"[Gmail]/Important" !"[Gmail]/Starred" !"[Gmail]/Trash"
        Create Near
        Remove Near
        Expunge Near
        Sync Pull
        SyncState /var/lib/mbsync-rbcca/
      '';

      timerInterval = "15min";

      # Don't use RemainAfterExit with OnUnitActiveSec timer
      # The service needs to become inactive for the timer to schedule the next run
      extraServiceConfig = { };
    })
```

- [ ] **Step 2: Verify by evaluation**

```bash
cd /etc/nixos && nix eval '.#nixosConfigurations.vulcan.config.systemd.services."mbsync-rbcca".description'
```

Expected output: `"mbsync synchronization for rbcca"`

(Note: evaluation succeeds even before Task 1 — sops key presence is checked at build time, not eval time.)

- [ ] **Step 3: Format and commit**

```bash
cd /etc/nixos && nix fmt modules/services/mbsync.nix
git add modules/services/mbsync.nix
git commit -m "mbsync: add rbcca mirror (jwiegley@rbcca.org, INBOX pull, 15min)"
```

---

### Task 4: Dovecot maildir/sieve dirs + FTS monitor user list

**Files:**
- Modify: `modules/services/dovecot.nix:465` and `:475` (tmpfiles rules)
- Modify: `modules/services/dovecot-fts-monitor.nix:61-64` (USERS list + comment line-ref)

**Interfaces:**
- Consumes: user `rbcca` (Task 2).
- Produces: `/var/mail/rbcca` and `/home/rbcca/sieve-bin` directories used by mbsync's Dovecot tunnel (Task 3) and first sync (Task 8).

**IMPORTANT tmpfiles safety rule (CLAUDE.md):** use the `d` directive ONLY (creates, never empties). Never `D`.

- [ ] **Step 1: Add tmpfiles rules in `modules/services/dovecot.nix`**

After line 465 (`"d /var/mail/bia 0700 bia users -"`) insert:

```nix
    "d /var/mail/rbcca 0700 rbcca users -"
```

After line 475 (`"d /home/bia/sieve-bin 0700 bia users -"`) insert:

```nix
    "d /home/rbcca/sieve-bin 0700 rbcca users -"
```

(Note both existing bia rules use group `users`, not the per-account group — replicate exactly.)

- [ ] **Step 2: Update `modules/services/dovecot-fts-monitor.nix`**

Change line 64:

```sh
    USERS="johnw assembly bia"
```

to:

```sh
    USERS="johnw assembly bia rbcca"
```

And update the comment above it (line ~61-62) from `dovecot.nix:463-465` to `dovecot.nix:463-466` so the cross-reference stays true.

- [ ] **Step 3: Verify by evaluation**

```bash
cd /etc/nixos && nix eval --json '.#nixosConfigurations.vulcan.config.systemd.tmpfiles.rules' | tr ',' '\n' | grep rbcca
```

Expected: both new rules appear (plus the two `mkMbsyncService`-generated `/var/lib/mbsync-rbcca` and `/var/log/mbsync-rbcca` rules from Task 3).

- [ ] **Step 4: Format and commit**

```bash
cd /etc/nixos && nix fmt modules/services/dovecot.nix modules/services/dovecot-fts-monitor.nix
git add modules/services/dovecot.nix modules/services/dovecot-fts-monitor.nix
git commit -m "dovecot: add rbcca maildir/sieve dirs and FTS monitoring"
```

---

### Task 5: Postfix send-as wiring

**Files:**
- Modify: `modules/services/postfix.nix:85-87` (`sender_canonical_regexp`) and `:93-95` (`sender_relay`)

**Interfaces:**
- Consumes: `postfix-secrets` line for `jwiegley@rbcca.org` (Task 1) via the existing `smtp_sasl_password_maps = "texthash:/run/secrets/postfix-secrets"`.
- Produces: outbound routing — mail authored as `rbcca@vulcan.lan` or `jwiegley@rbcca.org` relays via `[smtp.gmail.com]:587` with sender-keyed SASL. No changes needed to `smtp_generic_regexp` (canonical rewrite happens first, same as bia).

- [ ] **Step 1: Extend `sender_canonical_regexp`**

Change:

```nix
    mapFiles."sender_canonical_regexp" = pkgs.writeText "sender_canonical_regexp" ''
      /^bia(\+.*)?@vulcan\.lan$/    john@bia.bahai.org
    '';
```

to:

```nix
    mapFiles."sender_canonical_regexp" = pkgs.writeText "sender_canonical_regexp" ''
      /^bia(\+.*)?@vulcan\.lan$/    john@bia.bahai.org
      /^rbcca(\+.*)?@vulcan\.lan$/    jwiegley@rbcca.org
    '';
```

- [ ] **Step 2: Extend `sender_relay`**

Change:

```nix
    mapFiles."sender_relay" = pkgs.writeText "sender_relay" ''
      john@bia.bahai.org    [smtp.gmail.com]:587
    '';
```

to:

```nix
    mapFiles."sender_relay" = pkgs.writeText "sender_relay" ''
      john@bia.bahai.org    [smtp.gmail.com]:587
      jwiegley@rbcca.org    [smtp.gmail.com]:587
    '';
```

- [ ] **Step 3: Verify (syntax + content)**

```bash
cd /etc/nixos && nix-instantiate --parse modules/services/postfix.nix > /dev/null && echo PARSE-OK
grep -n 'rbcca' modules/services/postfix.nix
```

Expected: `PARSE-OK` and the two new map lines.

- [ ] **Step 4: Format and commit**

```bash
cd /etc/nixos && nix fmt modules/services/postfix.nix
git add modules/services/postfix.nix
git commit -m "postfix: send-as jwiegley@rbcca.org via Gmail relay"
```

---

### Task 6: Monitoring parity — Nagios timers + promtail scrape

**Files:**
- Modify: `modules/services/nagios.nix:929` and `:941` (timer list entries)
- Modify: `modules/services/promtail.nix:542` (append scrape job after the `mbsync-bia` block)

**Interfaces:**
- Consumes: `mbsync-rbcca.timer`, `mbsync-rbcca-health-check.timer`, `/var/log/mbsync-rbcca/*.log` (Task 3).

- [ ] **Step 1: Nagios — add two entries**

In `modules/services/nagios.nix`, after the entry ending at line 929 (`display = "Email Sync (bia)";` block) insert:

```nix
    {
      name = "mbsync-rbcca.timer";
      display = "Email Sync (rbcca)";
    }
```

After the bia health-check entry ending at line ~941 (`display = "Email Sync Health Check (bia)";` block, which will have shifted +4 lines) insert:

```nix
    {
      name = "mbsync-rbcca-health-check.timer";
      display = "Email Sync Health Check (rbcca)";
    }
```

- [ ] **Step 2: promtail — add the scrape job**

In `modules/services/promtail.nix`, after the `mbsync-bia` job's closing `}` (line 542, just before the `# Audit logs` comment) insert:

```nix
        {
          job_name = "mbsync-rbcca";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "mbsync";
                host = "vulcan";
                user = "rbcca";
                __path__ = "/var/log/mbsync-rbcca/*.log";
              };
            }
          ];
          pipeline_stages = [
            {
              multiline = {
                firstline = ''^(\d{4}-\d{2}-\d{2}|\w+\s+\d+)'';
                max_wait_time = "3s";
              };
            }
            {
              regex = {
                expression = "^(?P<message>.*)$";
              };
            }
          ];
        }
```

- [ ] **Step 3: Verify (syntax + content)**

```bash
cd /etc/nixos && nix-instantiate --parse modules/services/nagios.nix > /dev/null \
  && nix-instantiate --parse modules/services/promtail.nix > /dev/null && echo PARSE-OK
grep -n 'rbcca' modules/services/nagios.nix modules/services/promtail.nix
```

Expected: `PARSE-OK`; two nagios entries; one promtail job (3 matching lines: job_name, user label, __path__).

- [ ] **Step 4: Format and commit**

```bash
cd /etc/nixos && nix fmt modules/services/nagios.nix modules/services/promtail.nix
git add modules/services/nagios.nix modules/services/promtail.nix
git commit -m "monitoring: nagios + promtail coverage for mbsync-rbcca"
```

---

### Task 7: Full build verification

**Files:** none (verification only). **Requires Task 1 complete** (sops-nix validates the `rbcca-imap-bahai-org` key at build time).

- [ ] **Step 1: Build**

```bash
cd /etc/nixos && sudo nixos-rebuild build --flake '.#vulcan'
```

Expected: builds to completion with no errors. If it fails with a sops key-validation error naming `rbcca-imap-bahai-org`, Task 1 wasn't completed/flake-updated. Any other failure: fix the offending edit and rebuild (use `--show-trace` if the error is opaque).

---

### Task 8: Deploy, seed, and verify end-to-end

**Files:** none in the repo. Touches live system state; includes one USER step for the stateful Dovecot passwd-file.

- [ ] **Step 1: Switch**

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

Expected: activation completes; `systemctl --failed` shows no new failures.

- [ ] **Step 2: Confirm directories and units exist**

```bash
ls -ld /var/mail/rbcca /var/lib/mbsync-rbcca /var/log/mbsync-rbcca /home/rbcca
systemctl list-timers 'mbsync-rbcca*' --no-pager
```

Expected: dirs owned `rbcca` (mail dir mode 0700, group `users`); both timers scheduled.

- [ ] **Step 3: First sync**

```bash
sudo systemctl start mbsync-rbcca.service
systemctl status mbsync-rbcca.service --no-pager -n 5
```

Expected: `status=0/SUCCESS`. **Do not dump the full journal** — if it fails, read only the error summary lines (auth failures here usually mean app password typo'd in SOPS, or Workspace IMAP disabled). Then:

```bash
sudo ls /var/mail/rbcca | head
cat /var/lib/prometheus-node-exporter-textfiles/mbsync_rbcca.prom
```

Expected: maildir folders present; `mbsync_last_sync_status{account="rbcca"} 1`.

- [ ] **Step 4 (USER): Dovecot read-login for your mail client**

Generate a hash and append an `rbcca` line to the stateful passwd-file, matching the format of your existing `bia` line (the agent does not read this file):

```bash
doveadm pw -s SHA512-CRYPT     # enter the IMAP password you want your client to use
# then edit /var/lib/dovecot/users and add:  rbcca:{SHA512-CRYPT}$6$...
```

- [ ] **Step 5 (USER): Client-side checks**

- Add the `rbcca` IMAP account against vulcan in your mail client; INBOX shows the mirrored mail.
- Send a test message from `jwiegley@rbcca.org` via vulcan's submission port; confirm it arrives externally and `journalctl -u postfix -n 20` shows relay via `smtp.gmail.com` (eyeball summary lines only — never paste the full block).

- [ ] **Step 6: Monitoring checks (after ~30 min)**

- Nagios: "Email Sync (rbcca)" + "Email Sync Health Check (rbcca)" appear and go green.
- `curl -s 'https://prometheus.vulcan.lan/api/v1/query?query=mbsync_last_sync_status{account="rbcca"}'` returns value `1`.

- [ ] **Step 7: Commit the spec + plan docs (plus any doc updates)**

```bash
cd /etc/nixos && git add docs/superpowers/specs/2026-06-27-rbcca-mail-mirror-design.md docs/superpowers/plans/2026-07-02-rbcca-mail-mirror.md
git commit -m "docs: rbcca mail mirror design + implementation plan"
```
