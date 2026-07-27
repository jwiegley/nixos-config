# Email Tester - Complete Monitoring Setup

> **Status (2026-07-27): this is a PROPOSAL, not a description of the running
> system.** None of the automated monitoring below was ever deployed. What
> actually exists is `modules/services/email-tester-manual.nix` (imported at
> `hosts/vulcan/default.nix:121`), whose header states the reason:
> *"Does NOT include automated monitoring (timer, Prometheus, Nagios) to avoid
> over-training rspamd on test messages."* It provides only the SOPS secret
> `email-tester-imap-password` and an `email-tester` wrapper on `PATH`.
>
> Concretely, **none of these exist**: `email-tester.service` / `.timer`,
> `email-tester-exporter`, the `email_tester_*` metrics, the `EmailTester*`
> alerts, the Nagios `check_email_tester` command, and the four modules the
> "Import All Modules" step tells you to add (`modules/services/email-tester.nix`,
> `modules/services/nagios-email-tester-check.nix`,
> `modules/services/prometheus-email-tester-exporter.nix`,
> `modules/monitoring/email-tester-alerts.nix`).
>
> **Working today:** `sudo email-tester` (or `sudo /etc/nixos/scripts/email-tester.py`).
> Everything from "Complete Setup Guide" onward is a design that would have to be
> written before it could be followed; it is kept for background. If it is ever
> implemented, note that the entry point named in Step 2 is wrong too — this repo
> has no `/etc/nixos/configuration.nix`; the host module is
> `hosts/vulcan/default.nix`.

## Quick Answer

**To use the tester manually:**
```bash
sudo email-tester                          # wrapper installed by email-tester-manual.nix
sudo /etc/nixos/scripts/email-tester.py    # equivalent, direct
```

**For automated hourly testing with Nagios & Prometheus alerts:**
Not implemented — see the status note above. The setup below is the (unbuilt) design.

---

## Complete Setup Guide

### Step 1: Add IMAP Password to SOPS

```bash
cd /etc/nixos
sudo sops secrets/secrets.yaml
```

Add:
```yaml
email-tester-imap-password: "your-johnw-imap-password"
```

Save (`:wq`).

### Step 2: Import All Modules

Edit the host module `hosts/vulcan/default.nix` (there is no
`/etc/nixos/configuration.nix`):

```nix
imports = [
  # ... your existing imports ...

  # Email tester - hourly automated testing
  ./modules/services/email-tester.nix

  # Nagios integration
  ./modules/services/nagios-email-tester-check.nix

  # Prometheus exporter + alerts
  ./modules/services/prometheus-email-tester-exporter.nix
  ./modules/monitoring/email-tester-alerts.nix
];
```

### Step 3: Add Nagios Service Check

Add to your Nagios host configuration. The private topology lives in the separate
`nagios` flake-input repo at `/etc/nixos/nagios/hosts.nix`, imported at
`modules/services/nagios.nix:537`; there is no `/etc/nixos/nagios-hosts.nix`.

```nix
{
  service_description = "Email Pipeline Tests";
  host_name = "vulcan";
  check_command = "check_email_tester";
  check_interval = 60;  # Check every 60 minutes
  retry_interval = 15;  # Retry every 15 minutes if failed
  max_check_attempts = 3;
  notification_interval = 240;  # Notify every 4 hours if still failing
  notifications_enabled = 1;
}
```

### Step 4: Rebuild System

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

### Step 5: Verify Everything Works

#### Check Email Tester Timer
```bash
# Should show next run time
systemctl list-timers email-tester

# Run manual test
sudo systemctl start email-tester

# Check results
sudo journalctl -u email-tester -n 50
```

#### Check Prometheus Exporter
```bash
# Check exporter running
systemctl status email-tester-exporter

# Check metrics
curl http://localhost:9101/metrics

# Should show metrics like:
# email_tester_last_run_success 1
# email_tester_test_passed{test="normal_delivery"} 1
# email_tester_test_passed{test="spam_delivery"} 1
# etc.
```

#### Check Nagios
```bash
# Test the check command manually
/nix/store/.../check_email_tester

# Should output:
# OK: Overall: 5/5 tests passed | last_run=...

# Check in Nagios UI
# https://nagios.vulcan.lan
# Look for "Email Pipeline Tests" service on vulcan host
```

#### Check Prometheus Alerts
```bash
# View alert rules in Prometheus UI
# https://prometheus.vulcan.lan/alerts

# Should see email_tester alerts:
# - EmailTesterFailed
# - EmailTesterTimerInactive
# - EmailTesterStale
# - EmailNormalDeliveryFailed
# - EmailSpamDetectionFailed
# - etc.
```

---

## What Gets Monitored

### Nagios Checks (Every Hour)

- ✅ Timer is active and running
- ✅ Last run succeeded
- ✅ Gets overall pass/fail from test summary
- 🚨 **CRITICAL** if tests fail
- ⚠️ **WARNING** if timer inactive or never run

### Prometheus Metrics

**Service Health:**
- `email_tester_last_run_success` - 1 = success, 0 = failed
- `email_tester_timer_active` - 1 = timer active, 0 = inactive
- `email_tester_last_run_timestamp` - Unix timestamp of last run

**Test Results:**
- `email_tester_test_passed{test="normal_delivery"}` - 1 = passed, 0 = failed
- `email_tester_test_passed{test="spam_delivery"}` - 1 = passed, 0 = failed
- `email_tester_test_passed{test="train_good"}` - 1 = passed, 0 = failed
- `email_tester_test_passed{test="train_spam"}` - 1 = passed, 0 = failed
- `email_tester_test_passed{test="log_verification"}` - 1 = passed, 0 = failed

**Summary:**
- `email_tester_tests_passed_total` - Number of tests that passed
- `email_tester_tests_total` - Total number of tests run

### Prometheus Alerts

| Alert | Severity | Condition | Meaning |
|-------|----------|-----------|---------|
| `EmailTesterFailed` | **CRITICAL** | Last run failed (for 5min) | Email pipeline broken |
| `EmailTesterTimerInactive` | WARNING | Timer not running (for 10min) | No automated testing |
| `EmailTesterStale` | WARNING | No run in 2+ hours (for 10min) | Timer may be stuck |
| `EmailNormalDeliveryFailed` | **CRITICAL** | Normal delivery test failed | Can't receive email |
| `EmailSpamDetectionFailed` | **CRITICAL** | Spam test failed | Spam not being blocked |
| `EmailTrainGoodFailed` | WARNING | TrainGood test failed | Can't untrain false positives |
| `EmailTrainSpamFailed` | WARNING | TrainSpam test failed | Can't train on missed spam |
| `EmailTesterMultipleFailures` | **CRITICAL** | <60% tests pass | Major email system failure |

---

## Grafana Dashboard (Optional)

Create a dashboard to visualize email testing:

```promql
# Overall test success rate (gauge)
(email_tester_tests_passed_total / email_tester_tests_total) * 100

# Individual test status (graph over time)
email_tester_test_passed

# Time since last run (stat)
(time() - email_tester_last_run_timestamp) / 60

# Test pass rate over 24 hours (graph)
rate(email_tester_tests_passed_total[24h]) / rate(email_tester_tests_total[24h])
```

---

## Troubleshooting

### No Metrics in Prometheus

```bash
# Check exporter running
systemctl status email-tester-exporter

# Check Prometheus scrape config
grep -A 5 "job_name.*email-tester" /nix/store/*/prometheus.yml

# Check Prometheus targets
# https://prometheus.vulcan.lan/targets
# Should show email-tester target as UP
```

### Nagios Shows UNKNOWN

```bash
# Run check manually
/nix/store/.../check_email_tester

# Check if service exists
systemctl list-units | grep email-tester

# Check Nagios can access systemctl
sudo -u nagios systemctl status email-tester
```

### Tests Keep Failing

```bash
# Check which test is failing
sudo journalctl -u email-tester | grep "FAILED"

# Run with more detail
sudo /etc/nixos/scripts/email-tester.py

# Check service dependencies
systemctl list-dependencies email-tester
```

---

## Alert Notification Setup

Your existing Prometheus Alertmanager should route these alerts. Example:

```yaml
# alertmanager.yml
route:
  receiver: 'default'
  group_by: ['alertname', 'component']

  routes:
    - match:
        component: email
      receiver: 'email-admin'
      group_wait: 10s
      group_interval: 5m
      repeat_interval: 4h

receivers:
  - name: 'email-admin'
    email_configs:
      - to: 'admin@example.com'
        subject: '{{ .GroupLabels.alertname }}: Email System Issue'
```

---

## Manual Test Commands

```bash
# Run all tests
sudo /etc/nixos/scripts/email-tester.py

# Run via systemd (same as hourly run)
sudo systemctl start email-tester

# View results
sudo journalctl -u email-tester -n 100

# Check next scheduled run
systemctl list-timers email-tester

# Force timer to run now
sudo systemctl start email-tester.timer

# Disable automated testing (emergency)
sudo systemctl stop email-tester.timer
sudo systemctl disable email-tester.timer

# Re-enable
sudo systemctl enable email-tester.timer
sudo systemctl start email-tester.timer
```

---

## Summary

**(Describes the proposed end state, not the current one — see the status note at
the top of this file.)**

✅ **Email Tester**: Runs every hour automatically
✅ **Nagios**: Checks service status every hour, alerts on failure
✅ **Prometheus**: Scrapes detailed metrics every minute
✅ **Alerts**: Fire within 5 minutes of test failure
✅ **Monitoring**: Both Nagios and Prometheus will notify you

The complete monitoring stack ensures you'll know immediately if your email pipeline breaks!
