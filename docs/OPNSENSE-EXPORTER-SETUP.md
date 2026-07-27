# OPNsense Exporter Setup

This document describes the setup and configuration of the OPNsense Prometheus exporter running as a Podman container via systemd quadlet.

## Overview

The OPNsense exporter provides detailed metrics about the OPNsense firewall.
What is actually being collected here (see *Metrics Available* for the exact
series names, verified 2026-07-27):
- Gateway status
- Firewall rules and statistics
- Interface and per-protocol (netstat) counters
- WireGuard interface/peer status — OpenVPN and IPsec report nothing on this router
- DNS (Unbound) statistics
- Service status, ARP table, cron jobs, firmware information

DHCP lease metrics are **not** collected: the Kea DHCPv4/v6 collectors are disabled
because of an upstream schema mismatch (see *Architecture*).

This complements the node_exporter metrics from the OPNsense router itself.

## Architecture

Verified against the live config 2026-07-27.

- **Container**: `ghcr.io/athennamind/opnsense-exporter:latest`
- **Runs as**: a **rootless** Home Manager quadlet owned by the system user
  `opnsense-exporter` — the unit is a *user* unit, not a root service. It is
  declared in `modules/users/home-manager/opnsense-exporter.nix`;
  `modules/containers/opnsense-exporter-quadlet.nix` keeps only the SOPS secret and
  the firewall openings.
- **Port**: `127.0.0.1:9273` on the host → `:8080` inside the container
- **Scrape Interval**: 30 seconds (`modules/monitoring/services/opnsense-monitoring.nix`,
  job `opnsense` → `localhost:9273`)
- **Target**: **not** the router directly. Because of the upstream gateway-collector
  bug ([AthennaMind/opnsense-exporter#70](https://github.com/AthennaMind/opnsense-exporter/issues/70)),
  the exporter is pointed at a local transforming proxy:
  `OPNSENSE_EXPORTER_OPS_API = "10.88.0.1:8444"`, `OPS_PROTOCOL = "http"`,
  `OPS_INSECURE = "true"`. `modules/containers/opnsense-api-transformer.nix` is that
  proxy, and it is what actually talks to `https://192.168.1.1`. The removal steps
  for this workaround are listed at the top of
  `modules/containers/opnsense-exporter-quadlet.nix`.
- **Disabled collectors**: the Kea DHCPv4/v6 collectors are turned off via
  `OPNSENSE_EXPORTER_DISABLE_KEADHCPV4` / `..._KEADHCPV6` (upstream schema
  mismatch; see the comment in the Home Manager module).

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

The OPNsense API credentials are stored securely using SOPS in
`/etc/nixos/secrets/secrets.yaml` (a separate git repo consumed as the `secrets`
flake input — there is no `/etc/nixos/secrets.yaml`).

### Required Secret Entry

Add the following entry to that file:

```yaml
opnsense-exporter-secrets: |
  OPNSENSE_EXPORTER_OPS_API_KEY=your-api-key-here
  OPNSENSE_EXPORTER_OPS_API_SECRET=your-api-secret-here
```

**Important**:
- Replace `your-api-key-here` with the API key from OPNsense
- Replace `your-api-secret-here` with the API secret from OPNsense
- The format must be an environment file (one KEY=VALUE per line)
- Use `cd /etc/nixos && sops secrets/secrets.yaml` to edit the encrypted file
- It is deployed to `/run/secrets-opnsense-exporter/opnsense-exporter-secrets`
  (mode 0400, owner `opnsense-exporter`) — **not** to `/run/secrets/`, because it
  is a per-user secret for a rootless container
  (`modules/containers/opnsense-exporter-quadlet.nix`)

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

The container is rootless, so root's podman and `systemctl` (system scope) cannot
see it. Use the container user:

```bash
# Check if the container is running
sudo -u opnsense-exporter env HOME=/var/lib/containers/opnsense-exporter \
  XDG_RUNTIME_DIR=/run/user/$(id -u opnsense-exporter) podman ps

# Check the unit (user scope)
sudo -u opnsense-exporter env XDG_RUNTIME_DIR=/run/user/$(id -u opnsense-exporter) \
  systemctl --user status opnsense-exporter.service

# Logs (the user manager still logs to the system journal)
sudo journalctl _UID=$(id -u opnsense-exporter) -f

# The Home Manager activation unit IS a system unit:
sudo systemctl status home-manager-opnsense-exporter.service

# The transforming proxy in front of the router is a normal system unit:
sudo systemctl status opnsense-api-transformer.service
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
# Check the user-scope unit / logs (see "Check Container Status" above)
sudo -u opnsense-exporter env XDG_RUNTIME_DIR=/run/user/$(id -u opnsense-exporter) \
  systemctl --user status opnsense-exporter.service
sudo journalctl _UID=$(id -u opnsense-exporter) -n 50

# Verify SOPS secret is present (metadata only - do not print its contents)
sudo ls -la /run/secrets-opnsense-exporter/opnsense-exporter-secrets
```

### "401 Unauthorized" or API Errors

- Verify API credentials in SOPS secret are correct
- Check OPNsense user has required permissions
- Ensure API is enabled on OPNsense (System > Settings > Administration)

### No Metrics Being Collected

- Verify OPNsense router is reachable from vulcan: `ping 192.168.1.1`
- Test API connectivity: `curl -k https://192.168.1.1/api/diagnostics/interface/getArp`
- Check the transforming proxy the exporter actually talks to:
  `systemctl status opnsense-api-transformer` and `curl -s http://10.88.0.1:8444/api/...`
- Check whether specific collectors are disabled — see
  `OPNSENSE_EXPORTER_DISABLE_*` in `modules/users/home-manager/opnsense-exporter.nix`
  (KeaDHCPv4/v6 are disabled on purpose)

### SSL/TLS Certificate Errors

**As of 2026-07-27 TLS is not in play on this hop.** The exporter no longer talks to
the router directly: it speaks plain HTTP to the local transforming proxy
(`OPNSENSE_EXPORTER_OPS_PROTOCOL = "http"`, `OPS_INSECURE = "true"`), and the proxy
handles the HTTPS connection to `192.168.1.1`. If TLS errors appear, they come from
`opnsense-api-transformer.service`, not from the exporter container. (The CA volume
mounts and `SSL_CERT_FILE` that the exporter used to carry were dropped in the Home
Manager migration; restoring them is step 5-6 of the workaround-removal checklist at
the top of `modules/containers/opnsense-exporter-quadlet.nix`.)

## Configuration Options

To modify exporter behavior, edit
`/etc/nixos/modules/users/home-manager/opnsense-exporter.nix` — the container
definition moved there. `modules/containers/opnsense-exporter-quadlet.nix` now holds
only the SOPS secret and the firewall openings.

### Disable Specific Collectors

This deployment configures the exporter through **environment variables**, not CLI
flags; the live `exec` is just
`--log.level=info --log.format=json --web.listen-address=:8080`. Add entries to the
`environments` attrset:

```nix
environments = {
  OPNSENSE_EXPORTER_OPS_PROTOCOL = "http";
  OPNSENSE_EXPORTER_OPS_API = "10.88.0.1:8444";
  OPNSENSE_EXPORTER_OPS_INSECURE = "true";
  OPNSENSE_EXPORTER_INSTANCE_LABEL = "opnsense-router";
  OPNSENSE_EXPORTER_DISABLE_KEADHCPV4 = "true";
  OPNSENSE_EXPORTER_DISABLE_KEADHCPV6 = "true";
  # OPNSENSE_EXPORTER_DISABLE_ARP_TABLE = "true";
};
```

Upstream also accepts the equivalent CLI flags if you prefer to put them in `exec`
(`--exporter.disable-arp-table`, `--exporter.disable-cron-table`,
`--exporter.disable-wireguard`, `--exporter.disable-unbound`,
`--exporter.disable-openvpn`, `--exporter.disable-ipsec`,
`--exporter.disable-firewall`, `--exporter.disable-firmware`); check
`--help` for the current image before relying on any particular spelling.

### Change Log Level

Modify `--log.level=info` in the `exec` string to one of: `debug`, `info`, `warn`, `error`

## Metrics Available

See the official metrics documentation:
https://github.com/AthennaMind/opnsense-exporter/blob/main/docs/metrics.md

Metric families actually present in this Prometheus (56 series names, checked
2026-07-27 — note the plurals, and that several families guessed in an earlier
revision of this doc do not exist):

- `opnsense_up`, `opnsense_exporter_scrapes_total`, `opnsense_exporter_endpoint_errors_total`
- `opnsense_gateways_*` — `gateways_info`, `gateways_monitor_info` (**plural**, not `opnsense_gateway_*`)
- `opnsense_firewall_*` — `firewall_status` plus in/out × ipv4/ipv6 × pass/block packet counters
- `opnsense_interfaces_*` — bytes/errors/collisions/multicasts/MTU per interface
- `opnsense_protocol_*` — per-protocol netstat counters (arp, icmp, tcp, udp)
- `opnsense_unbound_*` — `dns_answer_secure_total`, `dns_answer_bogus_total`, `dns_uptime_seconds`
- `opnsense_wireguard_*` — interface + peer status, handshake age, per-peer bytes
- `opnsense_arp_table_entries`, `opnsense_cron_job_status`
- `opnsense_services_status`, `opnsense_services_running_total`, `opnsense_services_stopped_total`
- `opnsense_firmware_*` — version/ABI info, pending packages, needs-reboot flags

There is **no** `opnsense_vpn_*`, `opnsense_dhcp_*` or `opnsense_system_*` family:
OpenVPN/IPsec are not reporting here (only WireGuard is), and the Kea DHCP
collectors are deliberately disabled (see *Architecture*).

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
