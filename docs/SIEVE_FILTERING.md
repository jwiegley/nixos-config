# Sieve Mail Filtering Setup

This document describes the Sieve filtering configuration for automatic mail sorting.

## Overview

The system has two types of Sieve filtering:

1. **Delivery-time filtering**: Runs when mail is delivered to INBOX
2. **IMAPSieve filtering**: Runs when messages are moved to special folders

## Delivery-Time Filtering

**Active script:** `/home/johnw/sieve/active.sieve`
(reached by Dovecot through the symlink `/home/johnw/.dovecot.sieve`)

**Note (corrected 2026-07-27):** personal Sieve scripts live in the user's *system*
home, `/home/<username>/sieve/`, with the active script selected via
`/home/<username>/.dovecot.sieve`, and compiled bytecode written to
`/home/<username>/sieve-bin/`. The configuration is
`sieve = file:/home/%u/sieve;active=/home/%u/.dovecot.sieve`
(`modules/services/dovecot.nix:344`, `sieve_script_bin_path` at `:353`).
Explicit `/home/%u` paths are used rather than `~` because Dovecot's userdb
overrides `home` to `/var/mail/%u` (`dovecot.nix:278,287`) so that autoexpunge lock
files are not written to the system home.
An earlier layout under `/var/lib/dovecot/sieve/users/<username>/` was replaced on
2025-11-05 (commit `c03ff26`) and again refined on 2025-12-16 (commit `77fd1ca`);
that directory no longer exists.

### How to Edit Your Rules

```bash
# Edit as johnw user
vi /home/johnw/sieve/active.sieve

# Compile to check syntax
sievec /home/johnw/sieve/active.sieve

# No Dovecot restart is needed - the active script is re-read per delivery.
# If you do need to restart:
sudo systemctl restart dovecot2
```

### Example Rules

```sieve
require ["fileinto", "mailbox", "regex", "imap4flags", "variables"];

# Filter by sender
if address :is "from" "boss@company.com" {
    fileinto :create "mail/important";
    addflag "\\Flagged";
    stop;
}

# Filter by subject
if header :contains "subject" "invoice" {
    fileinto :create "mail/billing";
    stop;
}

# Filter mailing lists by List-Id
if header :regex "List-Id" "<([^@]+)@" {
    set :lower "listname" "${1}";
    fileinto :create "list/${listname}";
    stop;
}
```

## IMAPSieve Filtering (Special Folders)

### TrainGood Folder Processing

**Folder:** `TrainGood` (corrected 2026-07-27 — there is no folder called `Good`)
**Scripts:** `/var/lib/dovecot/sieve/global/rspamd/learn-ham.sieve` (runs *before*)
and `/var/lib/dovecot/sieve/global/rspamd/process-good.sieve` (runs *after*)
**Modules:** `/etc/nixos/modules/services/dovecot.nix` defines `processGoodScript`
(`:39`), deploys it as an `L+` tmpfiles symlink (`:474`) and wires the folder up as
`imapsieve_mailbox2_*` (`:369-373`); `/etc/nixos/modules/services/rspamd.nix`
defines `learnHamScript` (`:289`) and deploys it (`:842`). There is no
`modules/services/dovecot-good-folder.nix`.

When you move messages to the **TrainGood** folder via IMAP, Rspamd learns them as
ham and the messages are then re-filtered through your personal Sieve rules.

#### Workflow

1. Move message(s) to **TrainGood** (via Thunderbird, IMAP client, etc.)
2. IMAPSieve triggers on `COPY APPEND` immediately
3. `learn-ham.sieve` runs first and trains Rspamd on the message as ham
4. `process-good.sieve` then runs: it clears `\Seen`, re-runs your personal rules
   via `include :personal "active"` so the message lands in the right folder, and
   flags the copy left in TrainGood as `\Deleted`
5. TrainGood has `autoexpunge = 1d` (`dovecot.nix:428-430`), so those `\Deleted`
   copies are cleaned up automatically within a day

The sibling folders `TrainSpam` (`imapsieve_mailbox1_*`) and `Retrain`
(`imapsieve_mailbox3_*`) work the same way with their own script pairs.

#### Customizing TrainGood Handling

`process-good.sieve` contains no filing rules of its own — it just re-runs your
personal script. To change **where re-filtered mail goes**, edit your own
`/home/<username>/sieve/active.sieve`:

```sieve
# Example: Add a rule for Fastmail notifications
if address :domain :is "from" "fastmail.com" {
  fileinto :create "mail/fastmail";
  stop;
}
```

To change the TrainGood post-processing behaviour itself, edit `processGoodScript`
in `/etc/nixos/modules/services/dovecot.nix` and rebuild:
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

### TrainSpam/TrainGood Folders

**TrainSpam:** Learn as spam → Move to Spam
**TrainGood:** Learn as ham → Re-filter through personal Sieve rules

These are used for training the Rspamd Bayes classifier.

## Testing Sieve Scripts

```bash
# Test delivery-time script
cat > /tmp/test.eml << 'EOF'
From: test@github.com
To: johnw@example.com
Subject: Test message

Body text
EOF

sudo -u johnw sieve-test /home/johnw/sieve/active.sieve /tmp/test.eml

# Test the TrainGood post-processing script.
# Note: process-good.sieve uses `include :personal`, so it only resolves inside a
# user context - dovecot.nix:511-513 skips it during activation compilation for
# exactly this reason. Run it as the mail user, not as dovecot2:
sudo -u johnw sieve-test /var/lib/dovecot/sieve/global/rspamd/process-good.sieve /tmp/test.eml
```

## Available Sieve Extensions

- `fileinto` - Move to folders
- `mailbox` - Create folders with `:create`
- `regex` - Regular expressions
- `variables` - Store and use variables
- `imap4flags` - Add IMAP flags (\\Flagged, \\Seen, etc.)
- `body` - Filter on message body
- `vacation` - Auto-responder
- `editheader` - Modify headers
- `environment` - Access environment variables
- `imapsieve` - Trigger on IMAP operations

## Common Filtering Patterns

### By Sender Domain
```sieve
if address :domain :is "from" "example.com" {
    fileinto :create "mail/example";
    stop;
}
```

### By Header
```sieve
if header :contains "X-Label" "important" {
    fileinto :create "mail/important";
    addflag "\\Flagged";
    stop;
}
```

### Multiple Conditions
```sieve
if allof (
    address :domain "from" "work.com",
    header :contains "subject" "urgent"
) {
    fileinto :create "mail/work-urgent";
    addflag "\\Flagged";
    stop;
}
```

### Regex Matching
```sieve
if header :regex "subject" "^\\[JIRA\\]" {
    fileinto :create "mail/jira";
    stop;
}
```

### Extract and Use Variables
```sieve
if header :regex "List-Id" "<([^@]+)@" {
    set :lower "listname" "${1}";
    fileinto :create "list/${listname}";
    stop;
}
```

## Troubleshooting

### Script Not Running

Check Dovecot logs:
```bash
sudo journalctl -u dovecot2 -f
```

### Compilation Errors

```bash
# Check syntax
sievec /home/johnw/sieve/active.sieve

# View compiled bytecode (sieve_script_bin_path = /home/%u/sieve-bin)
sieve-dump /home/johnw/sieve-bin/active.svbin
```

### Messages Not Being Filtered

1. Check if script exists: `ls -la /home/johnw/sieve/active.sieve`
2. Test script: `sieve-test /home/johnw/sieve/active.sieve /tmp/test.eml`
3. Check Dovecot configuration: `doveconf -n | grep sieve`

## Remote Management (ManageSieve)

You can manage scripts remotely via ManageSieve protocol (port 4190):

**Port:** 4190 (TCP)
**Firewall:** Already configured to allow connections
**Authentication:** Same credentials as IMAP. The local mail users are johnw,
assembly, bia and rbcca (`modules/services/dovecot.nix:476-479`).

**Note:** With the current Sieve location (`/home/<username>/sieve/`, active script
`/home/<username>/.dovecot.sieve`), you can edit scripts remotely via ManageSieve and they will be immediately active without needing to restart Dovecot.

### Client Options

**Thunderbird:** Install "Sieve" add-on
**Command-line:** Use `sieveshell` or `sieve-connect`

```bash
# Using sieveshell (from Dovecot Pigeonhole)
sieveshell johnw@vulcan.lan

# Using sieve-connect (install via nix-shell)
nix-shell -p sieve-connect
sieve-connect johnw@vulcan.lan

# Test connection from another host
nc -zv vulcan.lan 4190
telnet vulcan.lan 4190
```

### Testing from hera.lan

```bash
# Test port connectivity
nc -zv vulcan.lan 4190

# Connect and manage scripts
sieveshell johnw@vulcan.lan
# Commands: list, activate, deactivate, delete, put, get
```

## References

- Dovecot Sieve: https://doc.dovecot.org/configuration_manual/sieve/
- Sieve RFCs: RFC 5228 (base), RFC 5229 (variables), RFC 5230 (vacation)
- IMAPSieve: RFC 6785

---

**Last Updated:** 2026-07-27 (paths, TrainGood folder name and module references
corrected against `modules/services/dovecot.nix` / `modules/services/rspamd.nix`;
originally written 2025-11-04)
