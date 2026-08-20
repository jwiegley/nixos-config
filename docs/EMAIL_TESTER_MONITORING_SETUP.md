# Email Tester - Complete Monitoring Setup

> **Status (2026-07-27): this is a PROPOSAL, not a description of the running
> system.** None of the automated monitoring below was ever deployed. What
> actually exists is `modules/services/email-tester-manual.nix` (imported at
> `hosts/vulcan/default.nix:121`), whose header states the reason: it
> deliberately omits automated monitoring (timer, exporter, alerting) to avoid
> over-training rspamd on test messages. It provides only the SOPS secret
> `email-tester-imap-password` and an `email-tester` wrapper on `PATH`.
>
> Concretely, **none of these exist**: `email-tester.service` / `.timer`,
> `email-tester-exporter`, the `email_tester_*` metrics, the `EmailTester*`
> alerts, and the three modules the "Import All Modules" step tells you to add
> (`modules/services/email-tester.nix`,
> `modules/services/prometheus-email-tester-exporter.nix`,
> `modules/monitoring/email-tester-alerts.nix`).
>
> **Revised 2026-08-19:** this design originally had a second, parallel arm that
> ran the same check under Nagios. Nagios was removed from vulcan on 2026-08-19,
> so that arm has been struck from the design below; Prometheus + Alertmanager is
> the only monitoring system on this host. Nothing else about the proposal changed.
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

**For automated hourly testing with Prometheus alerts:**
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

  # Prometheus exporter + alerts
  ./modules/services/prometheus-email-tester-exporter.nix
  ./modules/monitoring/email-tester-alerts.nix
];
```

### Step 3: Rebuild System

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

### Step 4: Verify Everything Works

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

The three conditions worth watching are: the timer is active and running, the
last run succeeded, and the overall pass/fail count from the test summary. All
three are covered by the alert table below — `EmailTesterTimerInactive`,
`EmailTesterFailed`, and `EmailTesterMultipleFailures` respectively.

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

### Exporter Reports No Result

```bash
# Check if service exists
systemctl list-units | grep email-tester

# Check the unit's last result
systemctl show email-tester -p Result -p ExecMainStatus
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
✅ **Prometheus**: Scrapes detailed metrics every minute
✅ **Alerts**: Fire within 5 minutes of test failure
✅ **Monitoring**: Alertmanager routes the failures to you by email

The complete monitoring stack ensures you'll know immediately if your email pipeline breaks!
