# OPNsense Exporter Setup

This document describes the setup and configuration of the OPNsense Prometheus exporter running as a Podman container via systemd quadlet.

## Overview

The OPNsense exporter provides detailed metrics about the OPNsense firewall including:
- Gateway status and latency
- Firewall rules and statistics
- VPN status (OpenVPN, IPsec, WireGuard)
- DNS (Unbound) statistics
- DHCP leases
- ARP table
- Cron jobs
- Firmware information

This complements the node_exporter metrics from the OPNsense router itself.

## Architecture

- **Container**: `ghcr.io/athennamind/opnsense-exporter:latest`
- **Port**: 9273 (localhost only)
- **Scrape Interval**: 30 seconds
- **Target**: OPNsense router at 192.168.1.1

## Prerequisites

### 1. Create OPNsense API Credentials

On your OPNsense router (192.168.1.1):

1. Navigate to **System > Access > Users**
2. Create a new user or select an existing user
3. Grant the following permissions (required for the exporter):
   - GUI: Diagnostics: ARP Table
   - GUI: Diagnostics: Firewall statistics
   - GUI: Diagnostics: Netstat
   - GUI: Reporting: Traffic
   - GUI: Services: Unbound (MVC)
   - GUI: Status: DHCP leases
   - GUI: Status: DNS Overview
   - GUI: Status: IPsec
   - GUI: Status: OpenVPN
   - GUI: Status: Services
   - GUI: System: Firmware
   - GUI: System: Gateways
   - GUI: System: Settings: Cron
   - GUI: System: Status
   - GUI: VPN: OpenVPN: Instances
   - GUI: VPN: WireGuard

4. Generate API key:
   - Click on the user
   - Scroll to "API keys" section
   - Click "+ Add"
   - Save the generated **API Key** and **API Secret** (you'll need these for SOPS)

### 2. Enable Extended Statistics in Unbound (Optional but Recommended)

For detailed DNS metrics:
1. Navigate to **Services > Unbound DNS > Advanced**
2. Enable **Extended Statistics**
3. Apply changes

## SOPS Secret Configuration

The OPNsense API credentials are stored securely using SOPS in `secrets.yaml`.

### Required Secret Entry

Add the following entry to your `secrets.yaml` file:

```yaml
opnsense-exporter-secrets: |
  OPNSENSE_EXPORTER_OPS_API_KEY=your-api-key-here
  OPNSENSE_EXPORTER_OPS_API_SECRET=your-api-secret-here
```

**Important**:
- Replace `your-api-key-here` with the API key from OPNsense
- Replace `your-api-secret-here` with the API secret from OPNsense
- The format must be an environment file (one KEY=VALUE per line)
- Use `sops secrets.yaml` to edit the encrypted file

### Verify Secret Format

After adding the secret, the decrypted content should look like:
```
OPNSENSE_EXPORTER_OPS_API_KEY=ABC123XYZ...
OPNSENSE_EXPORTER_OPS_API_SECRET=DEF456UVW...
```

## Deployment

After configuring the SOPS secret:

```bash
# Build and switch to the new configuration
sudo nixos-rebuild switch --flake .#vulcan
```

## Verification

### 1. Check Container Status

```bash
# Check if the container is running
podman ps | grep opnsense-exporter

# Check container logs
sudo journalctl -u opnsense-exporter.service -f

# Or use podman logs
podman logs opnsense-exporter
```

### 2. Test Metrics Endpoint

```bash
# Verify metrics are being collected
curl -s http://localhost:9273/metrics | head -20

# Check for specific OPNsense metrics
curl -s http://localhost:9273/metrics | grep opnsense_
```

### 3. Verify Prometheus Scraping

```bash
# Check if Prometheus is scraping the target
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="opnsense")'

# Query for OPNsense metrics in Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=up{job="opnsense"}' | jq
```

### 4. View in Prometheus UI

Navigate to `https://prometheus.vulcan.lan/targets` and verify:
- Target `opnsense` shows as "UP"
- Last scrape was successful

## Grafana Dashboard

Import the official OPNsense Exporter dashboard:
- Dashboard ID: **21113**
- Or download from: https://grafana.com/grafana/dashboards/21113

The dashboard provides comprehensive visualizations for:
- Gateway status and latency graphs
- Firewall statistics
- VPN connection status
- DNS query statistics
- System resource usage (when combined with node_exporter)

## Troubleshooting

### Container Won't Start

```bash
# Check systemd service status
systemctl status opnsense-exporter.service

# View detailed logs
journalctl -u opnsense-exporter.service -n 50

# Verify SOPS secret is accessible
sudo ls -la /run/secrets/opnsense-exporter-secrets
```

### "401 Unauthorized" or API Errors

- Verify API credentials in SOPS secret are correct
- Check OPNsense user has required permissions
- Ensure API is enabled on OPNsense (System > Settings > Administration)

### No Metrics Being Collected

- Verify OPNsense router is reachable from vulcan: `ping 192.168.1.1`
- Test API connectivity: `curl -k https://192.168.1.1/api/diagnostics/interface/getArp`
- Check if specific exporters are disabled in the container configuration

### SSL/TLS Certificate Errors

The exporter is configured with `--opnsense.insecure=false` by default. If you have a self-signed certificate:
- Either add the CA certificate to the system trust store
- Or modify the container config to use `--opnsense.insecure=true` (not recommended for production)

## Configuration Options

To modify exporter behavior, edit `/etc/nixos/modules/containers/opnsense-exporter-quadlet.nix`:

### Disable Specific Collectors

Add flags to the `exec` section:
```nix
exec = ''
  --log.level=info \
  --opnsense.protocol=https \
  --opnsense.address=192.168.1.1 \
  --exporter.instance-label=opnsense-router \
  --exporter.disable-arp-table \
  --exporter.disable-cron-table \
  --web.listen-address=:8080
'';
```

Available disable flags:
- `--exporter.disable-arp-table`
- `--exporter.disable-cron-table`
- `--exporter.disable-wireguard`
- `--exporter.disable-unbound`
- `--exporter.disable-openvpn`
- `--exporter.disable-ipsec`
- `--exporter.disable-firewall`
- `--exporter.disable-firmware`

### Change Log Level

Modify `--log.level=info` to one of: `debug`, `info`, `warn`, `error`

## Metrics Available

See the official metrics documentation:
https://github.com/AthennaMind/opnsense-exporter/blob/main/docs/metrics.md

Common metric families:
- `opnsense_gateway_*` - Gateway status and RTT
- `opnsense_firewall_*` - Firewall statistics
- `opnsense_vpn_*` - VPN connection status
- `opnsense_unbound_*` - DNS statistics
- `opnsense_dhcp_*` - DHCP lease information
- `opnsense_arp_*` - ARP table entries
- `opnsense_system_*` - System information

## Monitoring Both Exporters

You now have two exporters monitoring your OPNsense router:

1. **node_opnsense** (job) - General system metrics from node_exporter on OPNsense
   - Port: 9100
   - Location: On the OPNsense router itself
   - Metrics: CPU, memory, disk, network interfaces

2. **opnsense** (job) - OPNsense-specific metrics
   - Port: 9273
   - Location: Container on vulcan
   - Metrics: Gateways, firewall, VPN, DNS, DHCP

Both use the same labels (`alias="opnsense-router"`) for easy correlation in Grafana.

## References

- OPNsense Exporter GitHub: https://github.com/AthennaMind/opnsense-exporter
- Grafana Dashboard: https://grafana.com/grafana/dashboards/21113
- Container Image: ghcr.io/athennamind/opnsense-exporter
