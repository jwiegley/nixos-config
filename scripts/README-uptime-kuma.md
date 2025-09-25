# Uptime Kuma Setup Scripts

This directory contains scripts to help configure Uptime Kuma monitoring for your services.

## Scripts Available

### 1. uptime-kuma-setup.py (Advanced - Currently Non-functional)
A Python script that attempts to automate monitor creation via the API. However, Uptime Kuma primarily uses Socket.IO for its API, which makes automation complex. This script is provided for reference but requires additional dependencies:
- python-socketio
- requests
- urllib3

**Note:** This script is a template and would require additional work to function with Socket.IO.

### 2. uptime-kuma-setup-simple.sh (Recommended)
A simple bash script that provides a comprehensive list of all services to monitor. Run this to get a formatted list of monitors to add manually.

```bash
./uptime-kuma-setup-simple.sh
```

## Manual Setup Instructions

1. **Access Uptime Kuma**: Navigate to https://uptime.vulcan.lan

2. **Create Admin Account** (first time only):
   - Choose a strong username and password
   - These credentials will be used for all future logins

3. **Add Monitors**: For each service, click "Add New Monitor" and configure:

### Monitor Configuration Guide

#### Critical Services (60-second interval)
- PostgreSQL Database (TCP Port: 192.168.1.2:5432)
- Step-CA Certificate Authority (TCP Port: 127.0.0.1:8443)
- DNS Server (DNS: 192.168.1.2:53)
- SSH Service (TCP Port: 192.168.1.2:22)

#### Web Services (5-minute interval)
- Jellyfin: https://jellyfin.vulcan.lan
- Smokeping: https://smokeping.vulcan.lan
- pgAdmin: https://postgres.vulcan.lan
- Technitium DNS: https://dns.vulcan.lan
- Organizr: https://organizr.vulcan.lan
- Wallabag: https://wallabag.vulcan.lan
- Grafana: https://grafana.vulcan.lan

#### Mail Services (5-minute interval)
- Postfix SMTP (TCP Port: 192.168.1.2:25)
- Postfix Submission (TCP Port: 192.168.1.2:587)
- Dovecot IMAP (TCP Port: 192.168.1.2:143)
- Dovecot IMAPS (TCP Port: 192.168.1.2:993)

#### Container Services (5-minute interval)
- LiteLLM API (HTTP: http://10.88.0.1:4000/health)
- External Home Site (HTTPS: https://home.newartisans.com)

#### Monitoring Stack (10-minute interval)
- Prometheus (TCP Port: 127.0.0.1:9090)
- Node Exporter (TCP Port: 127.0.0.1:9100)

### Certificate Monitoring
For all HTTPS monitors:
1. Enable "Certificate Expiry Notification"
2. Set warning to 30 days before expiry
3. This will alert you before certificates need renewal

### Notification Setup
1. Go to Settings → Notifications
2. Add notification methods:
   - Email (using your Postfix server)
   - Discord/Telegram/Slack webhooks
   - Custom webhooks for integration

### Status Pages
1. Go to Status Pages → New Status Page
2. Create public or private status pages
3. Group monitors by category (Web, Database, Infrastructure, etc.)
4. Share the status page URL with your team

## Monitor Settings Recommendations

| Service Type | Check Interval | Retry Interval | Max Retries |
|-------------|---------------|----------------|-------------|
| Critical Infrastructure | 60 seconds | 30 seconds | 5 |
| Web Services | 5 minutes | 1 minute | 3 |
| Non-critical Services | 10 minutes | 2 minutes | 3 |
| Certificate Checks | 24 hours | 1 hour | 3 |

## Maintenance Windows
For planned maintenance:
1. Go to Settings → Maintenance
2. Create maintenance windows to suppress alerts
3. Set recurring maintenance for regular tasks

## Backup
Uptime Kuma data is stored in `/var/lib/uptime-kuma/kuma.db`
This SQLite database should be included in your regular backup routine.

## Troubleshooting

### Cannot Access Web Interface
- Check if service is running: `sudo systemctl status uptime-kuma`
- Check nginx proxy: `sudo nginx -t`
- Verify certificate: `openssl s_client -connect uptime.vulcan.lan:443`

### Monitors Show as Down
- Verify network connectivity from Uptime Kuma host
- Check firewall rules for monitored services
- For HTTPS monitors with self-signed certs, enable "Ignore TLS/SSL errors"

### High Resource Usage
- Reduce check intervals for non-critical services
- Disable unnecessary retry attempts
- Consider using push monitors for services that can self-report

## Integration Ideas

1. **Prometheus Integration**: Export Uptime Kuma metrics to Prometheus
2. **Grafana Dashboards**: Create dashboards using Uptime Kuma's metrics
3. **Automation**: Use push monitors for services to self-report their status
4. **API Monitoring**: Add API endpoint checks with expected response validation