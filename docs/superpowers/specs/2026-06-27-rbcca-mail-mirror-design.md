# Design: Mirror + send-as for `jwiegley@rbcca.org`

> **Archival — 2026-06-27.**
> This is a historical record of a plan/design/investigation as it stood at
> that time. It is NOT maintained and may not describe the current system.
> Current state: see `docs/README.md`.
> **Outcome:** implemented (see `modules/users/rbcca.nix`).
> **[Nagios removed 2026-08-19.]** The "full parity" claim below counted Nagios
> timer checks as one of its three legs; that leg no longer exists on this host.
> The promtail scrape and the FTS user list are still real. The record is left
> intact.

**Date:** 2026-06-27
**Status:** Implemented and deployed 2026-07-02 (plan:
`docs/superpowers/plans/2026-07-02-rbcca-mail-mirror.md`)
**Host:** vulcan

## Goal

Add `jwiegley@rbcca.org` (a Google Workspace account) as another external mail
account that is **mirrored** into a local Dovecot mailbox and can be **sent as**
through Gmail's SMTP relay — replicating the existing `bia`
(`john@bia.bahai.org`) setup exactly.

## Background

The repo already mirrors external Google accounts with `mbsync` (isync) via the
`mkMbsyncService` helper (`modules/lib/mkMbsyncModule.nix`). Two existing
variants:

- **`assembly`** (`carmichaellsa@gmail.com`) — inbound-only mirror.
- **`bia`** (`john@bia.bahai.org`) — inbound mirror **plus** outbound send-as
  (Postfix sender-canonical + sender-dependent relay/auth through
  `[smtp.gmail.com]:587`).

`bia` is the chosen template because `rbcca.org`, like `bia.bahai.org`, is a
Google **Workspace** custom domain reached through `imap.gmail.com` /
`smtp.gmail.com`, and the user wants both receive and send.

Each mirror is a **separate system user** with its own mailbox at
`/var/mail/<user>` (Dovecot `mail_location = /var/mail/%u`), read from a mail
client as its own IMAP account. Authentication to Google uses a static **app
password** stored in SOPS and read via `PassCmd`. The same app password is used
for the outbound SMTP relay.

### Decisions

- **Scope:** inbound mirror **+** send-as (bia-style). *(user-confirmed)*
- **Sync:** INBOX only, **pull**, **15-min** timer. *(user-confirmed)*
- **Monitoring:** full parity — Nagios timers, promtail scrape, FTS user list.
  *(user-confirmed)*
- **Auth:** Google app password (matches all existing Google mirrors), not
  OAuth2.
- **Local user/group name:** `rbcca`, uid/gid **1013** (next free after
  assembly=1011, bia=1012).
- **SOPS secret name:** `rbcca-imap-gmail-com` (matches the
  `carmichael-imap-gmail-com` convention; briefly deployed as
  `rbcca-imap-bahai-org` before the key was renamed on 2026-07-02).

## Detailed design — Nix changes (1 new file + 7 edits)

### 1. NEW `modules/users/rbcca.nix`

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

### 2. `hosts/vulcan/default.nix`

Add the import directly after the `bia` line (currently line 38):

```nix
    ../../modules/users/rbcca.nix
```

### 3. `modules/services/mbsync.nix`

Add a new `mkMbsyncService` block to the `imports` list (after the `bia` block,
before the closing `]`):

```nix
    # RBCCA configuration (jwiegley@rbcca.org via Google Workspace)
    (mkMbsyncService {
      name = "rbcca";
      user = "rbcca";
      group = "rbcca";
      secretName = "rbcca-imap-gmail-com";
      trash = "[Gmail]/Trash";

      remoteConfig = ''
        Host imap.gmail.com
        User jwiegley@rbcca.org
        PassCmd "cat /run/secrets/rbcca-imap-gmail-com"
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

The helper auto-declares the SOPS secret (`owner=rbcca, group=rbcca, mode=0400`),
the `mbsync-rbcca` service + timer, the health-check service + timer, the
mbsyncrc, the log dir, and the Prometheus textfile metrics. No extra wiring.

### 4. `modules/services/dovecot.nix`

Add to `systemd.tmpfiles.rules`, next to the `bia` entries (lines ~465 and
~475):

```nix
    "d /var/mail/rbcca 0700 rbcca users -"
    "d /home/rbcca/sieve-bin 0700 rbcca users -"
```

### 5. `modules/services/postfix.nix`

Outbound send-as wiring (mirror the `bia` lines):

- In `mapFiles."sender_canonical_regexp"` (after the bia line):

  ```
  /^rbcca(\+.*)?@vulcan\.lan$/    jwiegley@rbcca.org
  ```

- In `mapFiles."sender_relay"` (after the bia line):

  ```
  jwiegley@rbcca.org    [smtp.gmail.com]:587
  ```

No change to `smtp_generic_regexp`: the `sender_canonical_maps` rewrite happens
before the queue, so `rbcca@vulcan.lan` never reaches the catch-all (same as
bia). `smtp_sender_dependent_authentication = yes` is already set; it will look
up SASL creds for `jwiegley@rbcca.org` in `texthash:/run/secrets/postfix-secrets`
(see manual step 2).

### 6. `modules/services/nagios.nix`

Add two monitored timers (after the bia entries, ~line 929/941):

```nix
    {
      name = "mbsync-rbcca.timer";
      display = "Email Sync (rbcca)";
    }
```
```nix
    {
      name = "mbsync-rbcca-health-check.timer";
      display = "Email Sync Health Check (rbcca)";
    }
```

### 7. `modules/services/promtail.nix`

Add an `mbsync-rbcca` scrape job, copied from the `mbsync-bia` block (~line 516),
substituting `bia`→`rbcca` in `job_name`, `labels.user`, and `__path__`
(`/var/log/mbsync-rbcca/*.log`).

### 8. `modules/services/dovecot-fts-monitor.nix`

Add `rbcca` to the user list (line ~64):

```nix
    USERS="johnw assembly bia rbcca"
```

## Manual / out-of-band steps (NOT in Nix)

These cannot be done in the Nix change — they touch encrypted secrets and a
stateful, hand-maintained password file.

1. **Generate a Google app password** for `jwiegley@rbcca.org`. Requires the
   rbcca.org Workspace admin to have **IMAP access** and **app passwords**
   enabled. One app password serves both IMAP (mirror) and SMTP (send-as).

2. **Add the secrets** with `sops /etc/nixos/secrets/secrets.yaml`:
   - new key `rbcca-imap-gmail-com: <app-password>`
   - append to the `postfix-secrets` block:
     `jwiegley@rbcca.org    jwiegley@rbcca.org:<app-password>`

   Then, because `secrets` is a `git+file:///etc/nixos/secrets` flake input:
   ```bash
   cd /etc/nixos/secrets && git commit -am "Add rbcca IMAP/SMTP credentials"
   cd /etc/nixos && nix flake update secrets
   ```

3. **Dovecot read-login** for opening the mailbox in a mail client. Append an
   `rbcca` entry to the stateful passwd-file `/var/lib/dovecot/users`, matching
   the format of the existing `bia` line:
   ```bash
   doveadm pw -s SHA512-CRYPT     # generate the hash, then add the line by hand
   ```

4. **Apply and seed:**
   ```bash
   sudo nixos-rebuild switch --flake '.#vulcan'
   sudo systemctl start mbsync-rbcca.service   # first manual sync
   ```

## Testing / verification

- `nix flake check` / `sudo nixos-rebuild build --flake '.#vulcan'` — config
  evaluates.
- `systemctl status mbsync-rbcca.service` and `journalctl -u mbsync-rbcca` —
  first sync succeeds (watch for IMAP auth errors → app password / Workspace
  IMAP not enabled).
- `ls /var/mail/rbcca` — maildir populated.
- `cat /var/lib/prometheus-node-exporter-textfiles/mbsync_rbcca.prom` —
  `mbsync_last_sync_status{account="rbcca"} 1`.
- Mail client: add IMAP account `rbcca` against vulcan; INBOX visible.
- Send-as: compose from `jwiegley@rbcca.org` via the submission port; confirm it
  relays through Gmail and lands (check `journalctl -u postfix`).
- Nagios: "Email Sync (rbcca)" and its health check appear and go OK.

## Rollback

Revert the Nix commit + `nixos-rebuild switch`. Remove the two SOPS entries (and
re-commit/update the secrets input). Optionally remove the `rbcca` line from
`/var/lib/dovecot/users` and the `/var/mail/rbcca` maildir. The `rbcca` system
user can be left or removed.

## Out of scope

- Samba share, imapdedup, nagios-tier1-mirror entries (these are
  `assembly`-specific, not part of the bia template).
- rclone Google Drive backup of the account (bia's is disabled — testing-status
  OAuth client — so not replicated).
- A personal Sieve script for the rbcca mailbox (the global `default.sieve`
  spam-filter still applies; a personal `/home/rbcca/sieve` can be added later).
