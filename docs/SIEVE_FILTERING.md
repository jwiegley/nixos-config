# Sieve Mail Filtering Setup

This document describes the Sieve filtering configuration for automatic mail sorting.

## Overview

The system has two types of Sieve filtering:

1. **Delivery-time filtering**: Runs when mail is delivered to INBOX
2. **IMAPSieve filtering**: Runs when messages are moved to special folders

## Delivery-Time Filtering

**Active script:** `/var/lib/dovecot/sieve/users/johnw/active.sieve`

**Note:** Sieve scripts are stored in `/var/lib/dovecot/sieve/users/<username>/` to avoid conflicts with mailbox listings.

### How to Edit Your Rules

```bash
# Edit as johnw user
vi /var/lib/dovecot/sieve/users/johnw/active.sieve

# Compile to check syntax
sievec /var/lib/dovecot/sieve/users/johnw/active.sieve

# Restart Dovecot to apply changes
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

### Good Folder Processing

**Folder:** `Good`
**Script:** `/var/lib/dovecot/sieve/process-good.sieve`
**Module:** `/etc/nixos/modules/services/dovecot-good-folder.nix`

When you move messages to the **Good** folder via IMAP, they are automatically filtered according to rules similar to delivery-time filtering.

#### Workflow

1. Move message(s) to **Good** folder (via Thunderbird, IMAP client, etc.)
2. IMAPSieve triggers immediately
3. `process-good.sieve` script runs
4. Messages matching rules are moved to target folders
5. Messages not matching any rule stay in **Good**

#### Customizing Good Folder Rules

Edit `/etc/nixos/modules/services/dovecot-good-folder.nix` to change the filtering rules:

```nix
# Example: Add a rule for Fastmail notifications
if address :domain :is "from" "fastmail.com" {
  fileinto :create "mail/fastmail";
  stop;
}
```

After editing, rebuild:
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

### TrainSpam/TrainGood Folders

**TrainSpam:** Learn as spam → Move to IsSpam
**TrainGood:** Learn as ham → Move to Good

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

sudo -u johnw sieve-test /var/lib/dovecot/sieve/users/johnw/active.sieve /tmp/test.eml

# Test Good folder script
sudo -u dovecot2 sieve-test /var/lib/dovecot/sieve/process-good.sieve /tmp/test.eml
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
sievec /var/mail/johnw/sieve/filters.sieve

# View compiled bytecode
sieve-dump /var/mail/johnw/sieve/filters.svbin
```

### Messages Not Being Filtered

1. Check if script exists: `ls -la /var/lib/dovecot/sieve/users/johnw/active.sieve`
2. Test script: `sieve-test /var/lib/dovecot/sieve/users/johnw/active.sieve /tmp/test.eml`
3. Check Dovecot configuration: `doveconf -n | grep sieve`

## Remote Management (ManageSieve)

You can manage scripts remotely via ManageSieve protocol (port 4190):

**Port:** 4190 (TCP)
**Firewall:** Already configured to allow connections
**Authentication:** Same credentials as IMAP (johnw, assembly)

**Note:** With the new Sieve location (`/var/lib/dovecot/sieve/users/<username>/active.sieve`), you can edit scripts remotely via ManageSieve and they will be immediately active without needing to restart Dovecot.

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

**Last Updated:** 2025-11-04
