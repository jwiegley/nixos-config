# Rspamd Spam Filter Installation and Configuration

This document describes the comprehensive Rspamd installation on the vulcan NixOS system.

## Overview

Rspamd is an advanced spam filtering system integrated with:
- **Dovecot** IMAP server (via Sieve scripts for spam/ham training)
- **Redis** (dedicated instance for Bayes learning)
- **PostgreSQL** (for history and metadata storage)
- **Prometheus** (metrics collection)
- **Alertmanager** (health alerting)
- **Nagios** (service monitoring)
- **Grafana** (metrics visualization)
- **Glance** (quick access dashboard)

## Architecture

### Components Created

1. **`/etc/nixos/modules/services/rspamd.nix`** - Main Rspamd service configuration
2. **`/etc/nixos/modules/services/rspamd-alerts.nix`** - Prometheus alert rules
3. **Updated `/etc/nixos/modules/services/dovecot.nix`** - Added Sieve scripts for training
4. **Updated `/etc/nixos/modules/services/databases.nix`** - PostgreSQL user setup
5. **Updated `/etc/nixos/modules/services/nagios.nix`** - Service monitoring
6. **Updated `/etc/nixos/modules/services/glance.nix`** - Dashboard link

### Data Flow

```
Incoming Email → mbsync → Dovecot Maildir
                              ↓
         rspamd-scan-mailboxes (every 15min)
                              ↓
                    Rspamd Analysis
                              ↓
                    Spam → Spam folder
                    Ham → Stays in folder

User Training Workflow:
    TrainSpam folder ← User moves spam
         ↓
    Sieve: rspamc learn_spam
         ↓
    Move to IsSpam folder

    TrainGood folder ← User moves ham
         ↓
    Sieve: rspamc learn_ham
         ↓
    Move to Good folder
```

### Redis Backend

- **Instance**: `redis-rspamd` on port 6380
- **Purpose**: Bayes classifier token storage
- **Persistence**: Save to disk (900s/1key, 300s/10keys, 60s/10000keys)

### PostgreSQL Backend

- **Database**: `rspamd`
- **User**: `rspamd`
- **Purpose**: History and metadata storage (future use)

## Required Secrets (SOPS)

The following secrets must be created in `/etc/nixos/secrets.yaml`:

### 1. Rspamd Controller Password

```bash
sops /etc/nixos/secrets.yaml
```

Add under appropriate section:

```yaml
rspamd-controller-password: "GENERATE_STRONG_PASSWORD_HERE"
```

This password is used for:
- Web UI access at https://rspamd.vulcan.lan
- API authentication for rspamc commands

### 2. Rspamd PostgreSQL Password

```yaml
rspamd-db-password: "GENERATE_STRONG_PASSWORD_HERE"
```

This password will be automatically set up for the `rspamd` PostgreSQL user.

## Required SSL Certificate

Generate the SSL certificate for the Rspamd web interface:

```bash
sudo /etc/nixos/certs/renew-certificate.sh "rspamd.vulcan.lan" \
  -o "/var/lib/nginx-certs" \
  -d 365 \
  --owner "nginx:nginx" \
  --cert-perms "644" \
  --key-perms "600"
```

This certificate will be used by nginx to serve the Rspamd web UI at `https://rspamd.vulcan.lan`.

## Deployment Steps

### Step 1: Create SOPS Secrets

```bash
# Edit secrets file
sops /etc/nixos/secrets.yaml

# Add both secrets:
# - rspamd-controller-password
# - rspamd-db-password
```

### Step 2: Generate SSL Certificate

```bash
# Generate certificate for rspamd.vulcan.lan
sudo /etc/nixos/certs/renew-certificate.sh "rspamd.vulcan.lan" \
  -o "/var/lib/nginx-certs" \
  -d 365 \
  --owner "nginx:nginx" \
  --cert-perms "644" \
  --key-perms "600"
```

### Step 3: Build and Switch Configuration

```bash
# Build configuration (check for errors)
sudo nixos-rebuild build --flake '.#vulcan'

# If build succeeds, switch to new configuration
sudo nixos-rebuild switch --flake '.#vulcan'
```

### Step 4: Verify Services

```bash
# Check Rspamd service
sudo systemctl status rspamd
sudo journalctl -u rspamd -f

# Check Redis backend
sudo systemctl status redis-rspamd

# Check mailbox scanner timer
sudo systemctl status rspamd-scan-mailboxes.timer
sudo systemctl status rspamd-scan-mailboxes.service

# Check nginx reverse proxy
sudo nginx -t
sudo systemctl status nginx
```

## Testing

### Test 1: Spam Detection

```bash
# Scan a test message with rspamc
rspamc < /path/to/test/message.eml

# Check rspamd logs for activity
sudo journalctl -u rspamd --since "5 minutes ago"
```

### Test 2: Web UI Access

1. Open browser to `https://rspamd.vulcan.lan`
2. Log in with controller password from SOPS secrets
3. Verify dashboard shows statistics

### Test 3: Mailbox Scanning

```bash
# Manually trigger mailbox scan
sudo systemctl start rspamd-scan-mailboxes.service

# Check logs
sudo journalctl -u rspamd-scan-mailboxes -f

# Verify spam messages were moved to Spam folder
ls -la /var/mail/johnw/Spam/cur/
```

### Test 4: Spam Training Workflow

1. **Train Spam**:
   - Move a spam message to `TrainSpam` folder via IMAP client
   - Sieve script should run `rspamc learn_spam`
   - Message should be moved to `IsSpam` folder
   - Check Dovecot logs: `sudo journalctl -u dovecot2 -f`

2. **Train Ham**:
   - Move a legitimate message to `TrainGood` folder
   - Sieve script should run `rspamc learn_ham`
   - Message should be moved to `Good` folder

### Test 5: Monitoring

```bash
# Check Prometheus metrics
curl http://localhost:11334/metrics

# Check Prometheus target
# Visit: https://prometheus.vulcan.lan/targets

# Check Nagios monitoring
# Visit: https://nagios.vulcan.lan

# Check Alertmanager (should have no alerts initially)
# Visit: https://alertmanager.vulcan.lan
```

## Monitoring and Dashboards

### Grafana Dashboard

- **Dashboard ID**: 18075 (from grafana.com)
- **Title**: "Rspamd stat"
- **Data Source**: Prometheus
- **Import**:
  1. Go to Grafana: https://grafana.vulcan.lan
  2. Click Dashboards → Import
  3. Enter ID: 18075
  4. Select Prometheus data source
  5. Click Import

### Prometheus Alerts

The following alerts are configured (see `/etc/nixos/modules/services/rspamd-alerts.nix`):

- **RspamdServiceDown**: Rspamd service unavailable (critical)
- **RspamdHighProcessingTime**: Slow message processing (warning)
- **RspamdHighSpamRate**: >80% spam detection rate (warning)
- **RspamdNoRecentSpamLearning**: No learning in 7 days (info)
- **RspamdRedisUnavailable**: Redis backend down (critical)
- **RspamdBayesDatabaseLarge**: >10M tokens in Bayes DB (warning)
- **RspamdHighRejectionRate**: >50% message rejection (warning)

### Nagios Checks

- **rspamd.service**: SystemD service health check
- **rspamd-scan-mailboxes.timer**: Mailbox scanning timer check

## Configuration Files

### Rspamd Local Overrides

Rspamd configuration uses local overrides in `/var/lib/rspamd/local.d/`:

- **redis.conf**: Redis connection for statistics
- **classifier-bayes.conf**: Bayes learning settings
- **statistic.conf**: Statistics and autolearn configuration
- **actions.conf**: Spam score thresholds
- **worker-controller.inc**: Web UI and API settings
- **worker-normal.inc**: Normal worker settings
- **worker-proxy.inc**: Proxy worker (for future milter integration)
- **milter_headers.conf**: Email header additions
- **metrics.conf**: Prometheus metrics export

### Sieve Scripts

Located in `/var/lib/dovecot/sieve/rspamd/`:

- **learn-spam.sieve**: Triggered when message moved to TrainSpam
- **learn-ham.sieve**: Triggered when message moved to TrainGood
- **move-to-isspam.sieve**: Moves trained spam to IsSpam
- **move-to-good.sieve**: Moves trained ham to Good

Shell scripts in `/usr/local/bin/`:

- **rspamd-learn-spam.sh**: Calls `rspamc learn_spam`
- **rspamd-learn-ham.sh**: Calls `rspamc learn_ham`

## Workflow Details

### Automated Spam Scanning

Every 15 minutes, the `rspamd-scan-mailboxes.service` runs:

1. Scans mailboxes for users: `johnw`, `assembly`
2. Processes folders: INBOX, Sent, Drafts, NeedsRule, TrainGood, Good, mail/*, list/*
3. Skips: Spam, TrainSpam, IsSpam (to avoid loops)
4. For each message:
   - Calls `rspamc` to analyze
   - If score > 15 (spam threshold), moves to Spam folder
5. Logs activity to journalctl

### User Training

Users can improve spam detection by:

1. **Report False Negatives** (missed spam):
   - Move message to `TrainSpam` folder
   - Rspamd learns it as spam
   - Message automatically moves to `IsSpam`

2. **Report False Positives** (legitimate mail marked as spam):
   - Move message to `TrainGood` folder
   - Rspamd learns it as ham
   - Message automatically moves to `Good`

The Bayes classifier improves over time with user feedback.

## Troubleshooting

### Rspamd Not Starting

```bash
# Check logs
sudo journalctl -u rspamd --since "1 hour ago"

# Check configuration
rspamd -c

# Verify Redis is running
sudo systemctl status redis-rspamd
```

### Sieve Scripts Not Triggering

```bash
# Check Dovecot logs
sudo journalctl -u dovecot2 -f

# Verify Sieve scripts exist
ls -la /var/lib/dovecot/sieve/rspamd/
ls -la /usr/local/bin/rspamd-learn-*.sh

# Test Sieve script compilation
sievec /var/lib/dovecot/sieve/rspamd/learn-spam.sieve
```

### Mailbox Scanner Not Running

```bash
# Check timer status
sudo systemctl status rspamd-scan-mailboxes.timer

# Manually trigger
sudo systemctl start rspamd-scan-mailboxes.service

# Check logs
sudo journalctl -u rspamd-scan-mailboxes -f
```

### High False Positive Rate

```bash
# Check current action thresholds
rspamc stat

# Adjust thresholds in /etc/nixos/modules/services/rspamd.nix
# actions.conf section:
# - reject = 15 (default)
# - add_header = 6 (default)
# - greylist = 4 (default)

# Rebuild after changes
sudo nixos-rebuild switch --flake '.#vulcan'
```

## Security Considerations

- **Web UI Password**: Stored in SOPS, never displayed in clear text
- **PostgreSQL Password**: Managed via SOPS, auto-configured on service start
- **Redis**: Localhost-only, no password required
- **Nginx Reverse Proxy**: SSL/TLS required, certificate auto-renewed
- **Sieve Scripts**: Run as dovecot2 user, limited permissions

## Future Enhancements

Potential improvements:

1. **Milter Integration**: Connect Rspamd directly to Postfix for incoming mail filtering
2. **PostgreSQL History**: Enable history module to track long-term statistics
3. **Custom Rules**: Add domain-specific spam rules
4. **Whitelist/Blacklist**: Implement sender reputation lists
5. **DKIM Signing**: Add outgoing email signing
6. **Greylisting**: Enable greylisting for unknown senders

## References

- Rspamd Documentation: https://rspamd.com/doc/
- Dovecot Sieve: https://doc.dovecot.org/configuration_manual/sieve/
- Grafana Dashboard: https://grafana.com/grafana/dashboards/18075-rspamd/
- GitHub Integration Project: https://github.com/darix/dovecot-sieve-antispam-rspamd

## Support

For issues or questions:
- Check logs: `sudo journalctl -u rspamd -f`
- Review configuration: `rspamd -c`
- Test message scanning: `rspamc < message.eml`
- Web UI diagnostics: https://rspamd.vulcan.lan

---

**Configuration Status**: Ready for deployment (pending secrets and certificate)

**Last Updated**: 2025-01-15

**Author**: Claude Code (claude.ai/code)
