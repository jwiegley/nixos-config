# Technitium DNS Monitoring Setup Guide

This guide explains how to complete the setup of Technitium DNS monitoring with Prometheus, Grafana, and Alertmanager.

## Overview

The Technitium DNS Prometheus Exporter has been integrated into this NixOS configuration using Podman quadlet. The integration includes:

- **Container**: Technitium DNS exporter running on `localhost:9274`
- **Prometheus**: Scraping DNS metrics every 15 seconds
- **Grafana**: Dashboard for visualizing DNS performance
- **Alertmanager**: Alerts for DNS consistency and speed issues

## Prerequisites: Build Container Image and Generate API Token

**IMPORTANT**: The exporter container image is not available in public registries and must be built locally before deploying the configuration.

### Step 1: Build the Container Image

The exporter must be built from source as there is no pre-built container image available.

```bash
# Clone the repository
cd /tmp
git clone https://github.com/brioche-works/technitium-dns-prometheus-exporter.git
cd technitium-dns-prometheus-exporter

# Build the container image with Podman
sudo podman build -t localhost/technitium-dns-exporter:latest .

# Verify the image was created
sudo podman images | grep technitium-dns-exporter
```

**Note**: This only needs to be done once. The image will persist across reboots. To update the exporter in the future, rebuild the image with the same commands.

### Step 2: Access Technitium DNS Admin Panel

1. Navigate to: https://dns.vulcan.lan
2. Log in with your admin credentials

### Step 3: Generate API Token

1. Click on **Settings** in the top navigation
2. Scroll down to the **API Access** section
3. Click **Generate Token** or similar option
4. **Copy the generated token** immediately (it may only be shown once)
5. Store it temporarily in a secure location

**Note**: Technitium DNS does not support read-only API tokens. The token grants full administrative access, so it must be protected carefully. The token will be stored encrypted in SOPS secrets.

## Configure SOPS Secrets

### Step 4: Edit secrets.yaml with SOPS

```bash
cd /etc/nixos
sops secrets.yaml
```

### Step 5: Add Technitium DNS Exporter Configuration

Add the following section to your `secrets.yaml` file:

```yaml
technitium-dns-exporter-env: |
  TECHNITIUM_API_DNS_BASE_URL=http://10.88.0.1:5380
  TECHNITIUM_API_DNS_TOKEN=your_actual_api_token_here
  TECHNITIUM_API_DNS_LABEL=vulcan-dns
```

**Important**:
- Replace `your_actual_api_token_here` with the actual token you generated
- Use `http://10.88.0.1:5380` (Podman gateway IP) - NOT `http://127.0.0.1:5380`
  - From inside the container, `127.0.0.1` is the container's localhost, not the host
  - `10.88.0.1` is the Podman network gateway that routes to the host
- The format is an environment file (KEY=VALUE), not YAML
- Keep the pipe (`|`) character after the colon
- Maintain proper indentation

### Step 6: Save and Verify

1. Save the file in SOPS (it will be encrypted automatically)
2. Verify the secret is accessible:
   ```bash
   sops -d secrets.yaml | grep -A 3 technitium-dns-exporter-env
   ```

## Deploy the Configuration

### Step 1: Rebuild NixOS

```bash
cd /etc/nixos
sudo nixos-rebuild switch --flake .#vulcan
```

### Step 2: Verify Services

Check that all services started successfully:

```bash
# Check the exporter container
systemctl status technitium-dns-exporter.service
podman ps | grep technitium

# Check that metrics are being exposed
curl http://localhost:9274/metrics

# Check Prometheus is scraping
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="technitium_dns")'

# Check alert rules are loaded
curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.name=="dns_alerts")'
```

### Step 3: Access Grafana Dashboard

1. Navigate to: https://grafana.vulcan.lan
2. Log in with your Grafana credentials
3. Go to **Dashboards** → **Browse**
4. Look for **Technitium DNS** dashboard
5. The dashboard should display:
   - Query rates and types
   - Response code distribution
   - Cache hit/miss ratios
   - Query latency metrics
   - Blocking statistics

## Monitoring and Alerts

### Alert Rules Configured

The following alerts are configured for DNS monitoring:

#### Service Availability
- **TechnitiumDNSExporterDown**: Exporter has stopped responding
- **TechnitiumDNSServiceDown**: No metrics for 5+ minutes

#### Speed/Performance Alerts
- **HighDNSQueryLatency**: Average latency >100ms for 5 minutes (WARNING)
- **CriticalDNSQueryLatency**: Average latency >500ms for 2 minutes (CRITICAL)
- **DNSQueryRateSpike**: Query rate >2x normal (potential DDoS)
- **DNSQueryRateDrop**: Query rate <10% normal (potential outage)

#### Consistency/Reliability Alerts
- **HighDNSServerFailureRate**: >1% SERVFAIL responses (WARNING)
- **CriticalDNSServerFailureRate**: >5% SERVFAIL responses (CRITICAL)
- **HighDNSRefusedRate**: >2% REFUSED responses
- **HighDNSNameErrorRate**: >15% NXDOMAIN responses
- **LowDNSCacheHitRate**: Cache hit rate <70%
- **HighDNSRecursionFailureRate**: Upstream resolver issues

### Alert Destinations

Alerts are sent via email to the configured address in Alertmanager (johnw@newartisans.com).

To view active alerts:
- **Prometheus**: http://localhost:9090/alerts
- **Alertmanager**: https://alertmanager.vulcan.lan

## Troubleshooting

### Exporter Container Won't Start

```bash
# Check container logs
journalctl -u technitium-dns-exporter.service -n 50

# Check if secrets are accessible
sudo cat /run/secrets/technitium-dns-exporter-env

# Verify Technitium DNS is accessible
curl -s http://localhost:5380/api/user/profile
```

### No Metrics in Prometheus

```bash
# Check if exporter is responding
curl http://localhost:9274/metrics

# Check Prometheus targets
curl http://localhost:9090/api/v1/targets

# Check Prometheus logs
journalctl -u prometheus.service -n 50
```

### Dashboard Not Showing Data

```bash
# Verify Prometheus data source in Grafana
curl -s http://localhost:3000/api/datasources

# Check if metrics exist in Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=technitium_dns_stats_total_queries'

# Restart Grafana to reload dashboards
sudo systemctl restart grafana
```

### Invalid API Token Error

If you see authentication errors:

1. Verify the token is correct:
   ```bash
   sops -d /etc/nixos/secrets.yaml | grep -A 3 technitium-dns-exporter-env
   ```

2. Test the token manually:
   ```bash
   TOKEN="your_token_here"
   curl -H "Authorization: Bearer $TOKEN" http://localhost:5380/api/user/profile
   ```

3. If invalid, generate a new token and update secrets.yaml

## Metrics Reference

Key metrics exported by Technitium DNS:

- `technitium_dns_stats_total_queries`: Total DNS queries received
- `technitium_dns_stats_total_query_time_seconds`: Total query processing time
- `technitium_dns_stats_total_no_error`: Successful queries (NOERROR)
- `technitium_dns_stats_total_server_failure`: SERVFAIL responses
- `technitium_dns_stats_total_name_error`: NXDOMAIN responses
- `technitium_dns_stats_total_refused`: REFUSED responses
- `technitium_dns_stats_total_cache_hit`: Cache hits
- `technitium_dns_stats_total_cache_miss`: Cache misses
- `technitium_dns_stats_total_blocked`: Blocked queries
- `technitium_dns_stats_total_recursive_queries`: Queries forwarded upstream

All metrics are prefixed with `technitium_dns_` and include labels for the DNS server.

## Maintenance

### Updating the Exporter

The exporter uses a locally-built container image. To update to the latest version:

```bash
# Rebuild the image from the latest source
cd /tmp
rm -rf technitium-dns-prometheus-exporter
git clone https://github.com/brioche-works/technitium-dns-prometheus-exporter.git
cd technitium-dns-prometheus-exporter
sudo podman build -t localhost/technitium-dns-exporter:latest .

# Restart the service to use the new image
sudo systemctl restart technitium-dns-exporter.service
```

### Adjusting Alert Thresholds

Edit `/etc/nixos/modules/monitoring/alerts/dns.yaml` and adjust the thresholds as needed for your environment, then rebuild:

```bash
sudo nixos-rebuild switch --flake .#vulcan
```

### Adding Custom Dashboard Panels

1. Modify the dashboard in Grafana UI
2. Export the JSON
3. Replace `/var/lib/grafana/dashboards/technitium-dns.json`
4. Restart Grafana or wait for auto-reload

## Integration with Existing Services

The DNS monitoring integrates seamlessly with:

- **Prometheus**: Metrics stored alongside other system metrics
- **Grafana**: Dashboard available alongside existing dashboards
- **Alertmanager**: Alerts routed to existing receivers
- **Loki**: DNS service logs can be correlated with metrics

## Security Considerations

1. **API Token Protection**: The token is stored encrypted in SOPS and only accessible to root
2. **Network Exposure**: Exporter only binds to localhost (127.0.0.1:9274)
3. **Container Isolation**: Runs in Podman with minimal privileges
4. **TLS**: Grafana and Alertmanager accessed via HTTPS with step-ca certificates

## Additional Resources

- **Exporter GitHub**: https://github.com/brioche-works/technitium-dns-prometheus-exporter
- **Technitium DNS**: https://technitium.com/dns/
- **Prometheus Documentation**: https://prometheus.io/docs/
- **Grafana Documentation**: https://grafana.com/docs/
