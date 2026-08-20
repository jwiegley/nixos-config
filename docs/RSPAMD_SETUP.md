# Rspamd Spam Filter Installation and Configuration

> **Status (2026-07-27):** Rspamd is **deployed and running** on vulcan
> (`rspamd.service` active); this is no longer a pre-deployment plan. Two
> structural things changed after the original write-up and are corrected below:
>
> 1. The `rspamd-scan-mailboxes` service/timer **no longer exists.** It was removed
>    on 2025-11-06 (commit 3daa14b, "Remove 183-line mailboxScannerScript,
>    rspamd-scan-mailboxes systemd service, mbsync-johnw OnSuccess hook"). Mail is
>    now scanned inline by Rspamd as a **Postfix milter**, not by a 15-minute
>    polling sweep of the Maildir. `systemctl status rspamd-scan-mailboxes.*` will
>    report "Unit not found". (A monitoring config did still list that timer as a
>    monitored unit — a live defect at the time, not a doc error. That config was
>    deleted on 2026-08-19; as of that date nothing in the repo references the
>    timer.)
> 2. Sieve pipe scripts moved out of `/usr/local/bin` into
>    `/var/lib/dovecot/sieve-pipe-bin/` on 2025-11-06 (commit f71f7ec).

This document describes the comprehensive Rspamd installation on the vulcan NixOS system.

## Overview

Rspamd is an advanced spam filtering system integrated with:
- **Dovecot** IMAP server (via Sieve scripts for spam/ham training)
- **Redis** (dedicated instance for Bayes learning)
- **PostgreSQL** (for history and metadata storage)
- **Prometheus** (metrics collection)
- **Alertmanager** (health alerting)
- **Grafana** (metrics visualization)
- **Glance** (quick access dashboard)

## Architecture

### Components Created

1. **`/etc/nixos/modules/services/rspamd.nix`** - Main Rspamd service configuration
2. **`/etc/nixos/modules/services/rspamd-alerts.nix`** - Prometheus alert rules
3. **Updated `/etc/nixos/modules/services/dovecot.nix`** - Added Sieve scripts for training
4. **Updated `/etc/nixos/modules/services/databases.nix`** - PostgreSQL user setup
5. **Updated `/etc/nixos/modules/services/glance.nix`** - Dashboard link

### Data Flow

```
Incoming / locally-injected mail → Postfix
                              ↓
         milter (inet:localhost:11332 → rspamd_proxy worker, self_scan)
                              ↓
                    Rspamd Analysis — adds X-Spam* headers
                    (actions.conf never rejects: reject = 999)
                              ↓
                    Dovecot delivery → default.sieve (sieve_before)
                              ↓
                    X-Spam-Score / X-Spam-Level >= 4, or X-Spam: Yes
                        → fileinto "Spam", stop
                    otherwise → falls through to the user's personal Sieve

User Training Workflow:
    TrainSpam folder ← User moves spam
         ↓
    Sieve: rspamc learn_spam
         ↓
    Move to Spam folder

    TrainGood folder ← User moves ham
         ↓
    Sieve: rspamc learn_ham
         ↓
    Re-filter through personal Sieve rules

    Retrain folder ← User moves anything to re-scan
         ↓
    Sieve: retrain.sieve (rescan through rspamd, redeliver via LDA)
         ↓
    Full Sieve pipeline again (default.sieve + active.sieve)
```

### Redis Backend

- **Instance**: `redis-rspamd` on port 6381 (`modules/services/rspamd.nix:808`;
  matches `docs/ports.txt:60`)
- **Purpose**: Bayes classifier token storage
- **Persistence**: Save to disk (900s/1key, 300s/10keys, 60s/10000keys)

### PostgreSQL Backend

- **Database**: `rspamd`
- **User**: `rspamd`
- **Purpose**: History and metadata storage (future use)

## Required Secrets (SOPS)

Both of these already exist. The encrypted store is `/etc/nixos/secrets/secrets.yaml`
— a *separate* git repo consumed as the `secrets` flake input. There is no
`/etc/nixos/secrets.yaml`.

### 1. Rspamd Controller Password

```bash
sops /etc/nixos/secrets/secrets.yaml
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
# Edit secrets file (separate `secrets` flake-input repo; note that an edit does
# not take effect until it is committed there AND the flake input is re-locked)
sops /etc/nixos/secrets/secrets.yaml

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

# Check the milter path is live (Postfix -> rspamd_proxy on 11332)
sudo postconf -n | grep milter
sudo ss -tlnp | grep 11332

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

### Test 3: Inline Milter Filing

There is no mailbox scanner to trigger any more (see the status note at the top).
To exercise the live path, deliver a message through Postfix and confirm Sieve filed
it:

```bash
# Confirm rspamd is stamping headers on delivered mail
sudo journalctl -u rspamd --since "15 minutes ago" | grep -i 'proxy;'

# Verify spam messages landed in the Spam folder
ls -la /var/mail/johnw/Spam/cur/
```

To re-run an already-delivered message through the whole pipeline, move it into the
`Retrain` folder (`imapsieve_mailbox3`, `modules/services/dovecot.nix:377-380`).

### Test 4: Spam Training Workflow

1. **Train Spam**:
   - Move a spam message to `TrainSpam` folder via IMAP client
   - Sieve script should run `rspamc learn_spam`
   - Message should be moved to `Spam` folder
   - Check Dovecot logs: `sudo journalctl -u dovecot -f` (the unit is `dovecot`;
     `dovecot2` is only a unit *alias*, and `journalctl -u dovecot2` returns
     nothing)

2. **Train Ham**:
   - Move a legitimate message to `TrainGood` folder
   - Sieve script should run `rspamc learn_ham`
   - Message should be re-filtered through personal Sieve rules

### Test 5: Monitoring

```bash
# Check Prometheus metrics
curl http://localhost:11334/metrics

# Check Prometheus target
# Visit: https://prometheus.vulcan.lan/targets

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

### Unit health

Two distinct signals, deliberately not merged:

- **`RspamdServiceDown`** (above) is `up{job="rspamd"} == 0` — the scrape target,
  i.e. the controller/exporter, being unreachable. A same-named systemd-state
  rule was removed from `email-services.yaml` to avoid an alert-name collision;
  this is the canonical down-signal.
- **`SystemdServiceFailed`** (`modules/monitoring/alerts/systemd.yaml`) is the
  generic `node_systemd_unit_state{state="failed"}` rule and covers
  `rspamd.service` failing along with every other unit.

Prometheus plus Alertmanager is the only monitoring system on this host; there is
no separate service-monitoring layer.

## Configuration Files

### Rspamd Local Overrides

Rspamd configuration uses local overrides in **`/etc/rspamd/local.d/`**, generated
from the `services.rspamd.locals` attrset in `modules/services/rspamd.nix`
(`/var/lib/rspamd/override.d/` is a *different* directory, used only for the two
files that must carry secrets at runtime — see below). The full live set:

- **redis.conf**: Redis connection for statistics
- **statistic.conf**: Bayes classifier (BAYES_SPAM / BAYES_HAM statfiles) and
  autolearn configuration
- **actions.conf**: Spam score thresholds
- **milter_headers.conf**: Email header additions
- **metrics.conf**: Prometheus metrics export
- **logging.inc**: log level (`notice`, to suppress per-scrape trusted-IP noise)
- **options.inc**: DNS and general options
- **rrd.conf**: RRD graph file location
- **policies_group.conf**: policy symbol scores
- **gpt.conf**: LLM-assisted classification (API key injected at preStart)
- **dkim_signing.conf**: DKIM signing disabled for local/private domains
- **phishing.conf** + **maps.d/phishing_whitelist.inc**: phishing module with
  `vulcan.lan` whitelisted
- **settings.conf**: whitelist for intra-`vulcan.lan` mail
- **rbl.conf**: RBL configuration
- **maps.d/effective_tld_names.dat**: custom TLD map
- **worker-controller.inc**: Web UI and API settings

There is no `classifier-bayes.conf`, `worker-normal.inc`, or `worker-proxy.inc`.
The proxy (milter) and controller workers are configured through the NixOS module's
`services.rspamd.workers.rspamd_proxy` / `workers.controller` options rather than
via `local.d` includes.

Two files are written at `rspamd.service` preStart into
`/var/lib/rspamd/override.d/` (mode 600, `rspamd:rspamd`) because they embed SOPS
secrets and `/etc` is read-only on NixOS: **worker-controller.inc** (controller
password) and **gpt.conf** (LiteLLM API key).

### Sieve Scripts

Located in `/var/lib/dovecot/sieve/global/rspamd/` (symlinks into the Nix store,
created by `systemd.tmpfiles.rules`):

- **learn-spam.sieve**: Triggered when message moved to TrainSpam
- **learn-ham.sieve**: Triggered when message moved to TrainGood
- **move-to-spam.sieve**: Moves trained spam to Spam folder
- **process-good.sieve**: Re-filters trained ham through personal Sieve rules
  (defined in `dovecot.nix`, not `rspamd.nix`)
- **retrain.sieve** / **retrain-cleanup.sieve**: Retrain folder — rescan through
  rspamd and redeliver via LDA

Shell scripts in **`/var/lib/dovecot/sieve-pipe-bin/`** (Dovecot's
`sieve_pipe_bin_dir`; the old `/usr/local/bin` location was removed 2025-11-06):

- **rspamd-learn-spam.sh**: Calls `rspamc learn_spam`
- **rspamd-learn-ham.sh**: Calls `rspamc learn_ham`
- **rspamd-retrain.sh**: Rescan + redeliver for the Retrain folder

## Workflow Details

### Automated Spam Scanning

**Historical note:** until 2025-11-06 this was a `rspamd-scan-mailboxes.service`
that swept the Maildir every 15 minutes, scanning users `johnw` and `assembly`
across INBOX/Sent/Drafts/NeedsRule/TrainGood/Good/mail/*/list/* (skipping Spam and
TrainSpam to avoid loops) and moving anything over the score threshold. That
service and its timer were **deleted** in favour of inline milter scanning, and
that is the arrangement in force today:

1. Postfix hands every incoming and locally-injected message to the milter at
   `inet:localhost:11332` (`smtpd_milters` / `non_smtpd_milters`,
   `modules/services/postfix.nix:172-176`; submission ports 465/587 set
   `smtpd_milters = ""` and skip it).
2. Rspamd's `rspamd_proxy` worker scans it (`self_scan = yes`) and adds `X-Spam*`
   headers. `actions.conf` sets `reject = 999`, so Rspamd never rejects — it only
   annotates.
3. On delivery, Dovecot's `sieve_before` script `default.sieve` files the message
   into `Spam` when `X-Spam-Score` / `X-Spam-Level` >= 4 (or `X-Spam: Yes`),
   exempting anything `from` domain `vulcan.lan`. Everything else falls through to
   the user's personal Sieve.
4. Activity is logged to journalctl under the `rspamd` and `dovecot` units.

### User Training

Users can improve spam detection by:

1. **Report False Negatives** (missed spam):
   - Move message to `TrainSpam` folder
   - Rspamd learns it as spam
   - Message automatically moves to `Spam` folder

2. **Report False Positives** (legitimate mail marked as spam):
   - Move message to `TrainGood` folder
   - Rspamd learns it as ham
   - Message automatically re-filters through personal Sieve rules

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
sudo journalctl -u dovecot -f

# Verify Sieve scripts exist
ls -la /var/lib/dovecot/sieve/global/rspamd/

# Test Sieve script compilation
sievec /var/lib/dovecot/sieve/global/rspamd/learn-spam.sieve
```

### Mail Not Being Scanned

The 15-minute `rspamd-scan-mailboxes` sweep no longer exists; if mail is arriving
unscanned, the milter hand-off is the thing to check.

```bash
# Is Postfix pointed at the milter?
sudo postconf -n | grep -E 'milter'

# Is the rspamd_proxy worker listening?
sudo ss -tlnp | grep 11332

# Rspamd's own view
sudo journalctl -u rspamd --since "1 hour ago"
rspamc stat
```

### High False Positive Rate

```bash
# Check current action thresholds
rspamc stat

# Adjust thresholds in /etc/nixos/modules/services/rspamd.nix
# actions.conf section (live values as of 2026-07-27, rspamd.nix:531-537):
# - reject = 999      (rejection deliberately disabled; Sieve does the filing)
# - add_header = 4
# - greylist = 3
# Note default.sieve files to Spam at X-Spam-Score >= 4, matching add_header.

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

1. ~~**Milter Integration**~~ — **DONE.** Postfix hands mail to the `rspamd_proxy`
   worker at `inet:localhost:11332` (`modules/services/postfix.nix:172-176`).
2. **PostgreSQL History**: Enable history module to track long-term statistics. The
   `rspamd` database and role exist (`databases.nix:31-34`), but no history module
   is configured — the DB is still unused.
3. **Custom Rules**: Add domain-specific spam rules. (Partly done: there are custom
   Lua rules for gibberish detection, plus a `gpt.conf` LLM-assisted module.)
4. **Whitelist/Blacklist**: Implement sender reputation lists. (Partly done:
   `settings.conf` whitelists intra-`vulcan.lan` mail and `default.sieve` never
   spam-files a `vulcan.lan` sender.)
5. **DKIM Signing**: Add outgoing email signing. Still not enabled —
   `dkim_signing.conf` explicitly sets `sign_local = false` on the grounds that DKIM
   only helps for public internet domains.
6. **Greylisting**: Enable greylisting for unknown senders. The `greylist = 3`
   action threshold exists, but the greylisting module itself is not configured.

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

**Configuration Status**: Deployed and running. Both SOPS secrets
(`rspamd-controller-password`, `rspamd-db-password`) exist, the
`rspamd.vulcan.lan` certificate is in place, and `rspamd.service` is active.

**Last Updated**: 2026-07-27 (fact-check pass). The document was first written
2025-11-04 and last substantively revised 2025-11-26; the "2025-01-15" date this
line previously carried predates the work it describes and was never correct.

**Author**: Claude Code (claude.ai/code)
