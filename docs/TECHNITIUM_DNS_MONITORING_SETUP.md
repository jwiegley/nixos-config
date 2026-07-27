# Technitium DNS Monitoring Setup Guide

This guide explains how to complete the setup of Technitium DNS monitoring with Prometheus, Grafana, and Alertmanager.

## Overview

The Technitium DNS Prometheus Exporter has been integrated into this NixOS configuration using Podman quadlet. The integration includes:

- **Container**: Technitium DNS exporter running on `localhost:9274`
- **Prometheus**: Scraping DNS metrics every 60 seconds (job `technitium_dns`,
  `scrape_timeout` 10s — `modules/monitoring/services/technitium-dns-monitoring.nix:107-119`)
- **Grafana**: Dashboard for visualizing DNS performance
- **Alertmanager**: Alerts for DNS consistency and speed issues

## Prerequisites: Build Container Image and Generate API Token

**IMPORTANT**: The exporter container image is not available in public
registries and must be built locally.

### Step 1: Build the Container Image

The exporter must be built from source as there is no pre-built container image
available.

**This step is now automatic.** `modules/containers/technitium-dns-exporter-quadlet.nix`
carries a `system.activationScripts.technitium-dns-exporter-image` block that,
on every activation, checks `podman image exists
localhost/technitium-dns-exporter:latest` and — if it is missing — clones the
repository into a temp dir, patches out the per-scrape
`api/user/checkForUpdate` call (it cost ~5,760 external HTTP requests/day, so
`technitium_dns_update_available` keeps its default of -1), builds the image and
cleans up. The manual procedure below is only needed if you want to force a
rebuild; note that a hand-built image will NOT carry that patch.

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

The encrypted store is `secrets/secrets.yaml` — a separate git repo consumed as
the `secrets` flake input. There is no `/etc/nixos/secrets.yaml`, and an edit
only takes effect once committed in that repo and re-locked
(`nix flake update secrets`).

```bash
cd /etc/nixos
sops secrets/secrets.yaml
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
2. Verify the key is present. Prefer checking the encrypted file's structure
   over decrypting it — a full decrypt prints the API token to your terminal:
   ```bash
   grep -c technitium-dns-exporter-env secrets/secrets.yaml
   ```
   After a rebuild, confirm the deployed secret by metadata only:
   ```bash
   ls -la /run/secrets/technitium-dns-exporter-env
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

The following Technitium alerts live in `modules/monitoring/alerts/dns.yaml`.
(That file also holds the `DnsQueryExporter*`, DNSSEC/PTR correctness, DNS probe
and Cloudflare-tunnel alert groups, which are out of scope for this guide.)

#### Service Availability
- **TechnitiumDNSExporterDown**: Exporter has stopped responding
- **TechnitiumDNSServiceDown**: No metrics for 5+ minutes
- **TechnitiumDNSMetricsFrozen**: Exporter scrapes fine (`up==1`) but has
  reported zero DNS queries for 15 minutes — it has probably lost its
  connection to the Technitium API

#### Speed/Performance Alerts
- **DNSQueryRateSpike**: Query rate >10x the 1h average (potential DDoS)
- **DNSQueryRateDrop**: Query rate below 10% of the 1h average (potential outage)
- **HighDNSQueryLatency** / **CriticalDNSQueryLatency**: **not active.** Both
  are commented out in `dns.yaml` because this exporter publishes no latency
  metric (there is no `technitium_dns_stats_total_query_time_seconds`). Restore
  them only if a latency metric is added upstream.

#### Consistency/Reliability Alerts
- **HighDNSServerFailureRate**: >1% SERVFAIL responses (WARNING)
- **CriticalDNSServerFailureRate**: >5% SERVFAIL responses (CRITICAL)
- **HighDNSRefusedRate**: >2% REFUSED responses
- **HighDNSNameErrorRate**: >15% NXDOMAIN responses
- **LowDNSCacheHitRate**: Cache hit rate <70%
- **HighDNSBlockRate**: >50% of queries blocked (INFO)
- **HighDNSRecursionFailureRate**: Upstream resolver issues
- **TechnitiumUpdateAvailable**: a newer Technitium release is published.
  Note this cannot currently fire — the locally-built image is patched to skip
  the `checkForUpdate` API call, so `technitium_dns_update_available` stays at
  its "unknown" default of -1.

### Alert Destinations

Alerts are sent via email to the address configured in Alertmanager —
`johnw@vulcan.lan`, from `alertmanager@vulcan.lan`
(`modules/services/alertmanager.nix:18,191`).

To view active alerts:
- **Prometheus**: http://localhost:9090/alerts
- **Alertmanager**: https://alertmanager.vulcan.lan

## Troubleshooting

### Exporter Container Won't Start

```bash
# Check container logs
journalctl -u technitium-dns-exporter.service -n 50

# Check the secret was deployed (metadata only — the file holds the API token)
sudo ls -la /run/secrets/technitium-dns-exporter-env

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
curl -s 'http://localhost:9090/api/v1/query?query=sum(technitium_dns_request_result_count)'

# Restart Grafana to reload dashboards
sudo systemctl restart grafana
```

### Invalid API Token Error

If you see authentication errors:

1. Verify the token entry exists and was deployed (metadata only — do not print
   the token):
   ```bash
   grep -c technitium-dns-exporter-env /etc/nixos/secrets/secrets.yaml
   ls -la /run/secrets/technitium-dns-exporter-env
   ```
   If you must inspect the value, open the file interactively with
   `sops secrets/secrets.yaml` rather than piping a decrypt into `grep`.

2. Test the token manually:
   ```bash
   TOKEN="your_token_here"
   curl -H "Authorization: Bearer $TOKEN" http://localhost:5380/api/user/profile
   ```

3. If invalid, generate a new token and update secrets.yaml

## Metrics Reference

> **Corrected 2026-07-27.** This section previously listed a
> `technitium_dns_stats_total_*` family (`…_queries`, `…_query_time_seconds`,
> `…_no_error`, `…_server_failure`, `…_name_error`, `…_refused`, `…_cache_hit`,
> `…_cache_miss`, `…_blocked`, `…_recursive_queries`). **None of those metrics
> exist** — every example query built on them returns empty. The exporter
> instead emits dimensional counters that carry the outcome in a `result` label.
> The list below was taken from the live Prometheus `__name__` values for
> `job="technitium_dns"`.

Metrics actually exported:

- `technitium_dns_request_result_count{result="..."}`: queries by outcome —
  `no_error`, `server_failure`, `nx_domain`, `refused` (this replaces the whole
  former `…_stats_total_*` response-code family)
- `technitium_dns_resolve_mode_count{result="..."}`: queries by resolution mode —
  `authoritative`, `recursive`, `cached`, `blocked`, `dropped`
- `technitium_dns_record_type_count`: queries by record type (A, AAAA, MX, …)
- `technitium_dns_query_protocol_count`: queries by transport protocol
- `technitium_dns_client_count`: distinct clients seen
- `technitium_dns_cached_entry_count`: entries currently in cache
- `technitium_dns_zone_count`, `technitium_dns_allowed_zone_count`,
  `technitium_dns_blocked_zone_count`, `technitium_dns_allow_list_zone_count`,
  `technitium_dns_block_list_zone_count`: zone/list sizes
- `technitium_dns_status`: server status
- `technitium_dns_update_available`: -1 = unknown (see the image-patch note in
  Step 1), 0 = up to date, 1 = update published
- `technitium_dns_server_urls`: info series carrying the server URL

There is **no latency metric**, which is why the two query-latency alerts are
disabled.

All metrics are prefixed with `technitium_dns_` and carry a
`server="vulcan-dns"` label (from `TECHNITIUM_API_DNS_LABEL`); the scrape job
additionally adds `alias="vulcan-dns"`, `role="dns-server"` and
`service="technitium"`.
(`technitium_backup_*` is a different, unrelated exporter for the Technitium
config-backup job.)

## Maintenance

### Updating the Exporter

The exporter uses a locally-built container image. Preferred route — delete the
image and let the activation script rebuild it, so the `checkForUpdate` patch is
reapplied:

```bash
sudo systemctl stop technitium-dns-exporter.service
sudo podman rmi localhost/technitium-dns-exporter:latest
sudo nixos-rebuild switch --flake '.#vulcan'
```

Manual route (note: this produces an **unpatched** image that will call
`api/user/checkForUpdate` on every scrape, ~5,760 extra external requests/day):

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
3. Replace `/etc/nixos/modules/monitoring/dashboards/technitium-dns.json` — the
   Nix store is authoritative. `grafana-install-dashboards.service` copies the
   whole set into `/var/lib/grafana/dashboards/` before Grafana starts and
   **prunes anything not in the derivation**, so editing the file under
   `/var/lib/grafana/` directly is overwritten on the next rebuild or restart.
4. `sudo nixos-rebuild switch --flake '.#vulcan'`, then wait for Grafana's
   provisioning poll (or `sudo systemctl restart grafana`)

## Integration with Existing Services

The DNS monitoring integrates seamlessly with:

- **Prometheus**: Metrics stored alongside other system metrics
- **Grafana**: Dashboard available alongside existing dashboards
- **Alertmanager**: Alerts routed to existing receivers
- **Loki**: DNS service logs can be correlated with metrics

## Security Considerations

1. **API Token Protection**: The token is stored encrypted in SOPS. On disk it
   is `0440 dns-query-exporter:technitium-readers`
   (`modules/monitoring/services/dns-query-logs.nix:91-99` `mkForce`s this), so
   it is shared between the exporter container and `dns-query-log-exporter` —
   it is *not* root-only
2. **Network Exposure**: Exporter only binds to localhost (127.0.0.1:9274)
3. **Container Isolation**: Runs in Podman with minimal privileges
4. **TLS**: Grafana and Alertmanager accessed via HTTPS with step-ca certificates

## Additional Resources

- **Exporter GitHub**: https://github.com/brioche-works/technitium-dns-prometheus-exporter
- **Technitium DNS**: https://technitium.com/dns/
- **Prometheus Documentation**: https://prometheus.io/docs/
- **Grafana Documentation**: https://grafana.com/docs/
