# Home Assistant Integration Monitoring for Nagios

This guide explains how to monitor Home Assistant integration health using Nagios or standalone health checks.

## Overview

The `check_homeassistant_integrations` script
(`modules/monitoring/check_homeassistant_integrations.sh`) monitors:
- **Total entities** across all integrations (from `/api/states`)
- **Unavailable entities** (devices/sensors whose state is literally `unavailable`)
- **Missing integrations** — for each name passed to `-i`, whether it appears in
  the loaded-components list from `/api/config`. The script has no visibility into
  "disabled" or "error" config-entry states; a named integration is either loaded
  or it is not.
- **Integration-only mode** (`-I`): skip entity counting entirely and report only
  loaded/missing integrations. Requires `-i`.

Returns standard Nagios exit codes:
- `OK (0)`: All named integrations loaded, unavailable entities below warning threshold
- `WARNING (1)`: Unavailable entities >= warning threshold (default: 5)
- `CRITICAL (2)`: Unavailable entities >= critical threshold (default: 10), OR any
  `-i` integration is not loaded, OR the Home Assistant API is unreachable /
  unparseable
- `UNKNOWN (3)`: No token supplied (`-t`), an invalid option, or `-I` without `-i`

## Setup Instructions

### 1. Generate Home Assistant Long-Lived Access Token

1. Log in to Home Assistant: https://hass.vulcan.lan
2. Click your profile icon (bottom left)
3. Scroll to **Long-Lived Access Tokens** section
4. Click **Create Token**
5. Name: `Nagios Monitoring`
6. Copy the generated token (you won't be able to see it again)

### 2. Add Token to SOPS Secrets

```bash
# Edit SOPS secrets file (the encrypted store is secrets/secrets.yaml, a
# separate git repo consumed as the `secrets` flake input — there is no
# /etc/nixos/secrets.yaml)
sops /etc/nixos/secrets/secrets.yaml

# Add under a monitoring section:
monitoring:
  home-assistant-token: "<long-lived access token>"

# Save and exit
```

The secret is declared as `monitoring/home-assistant-token`
(`modules/monitoring/homeassistant-nagios-check.nix:36`) and deploys to
`/run/secrets/monitoring/home-assistant-token` owned `nagios:nagios`, mode `0400`.

### 3. Enable Monitoring Module

**Already enabled on vulcan** — `hosts/vulcan/default.nix:115` imports
`../../modules/monitoring/homeassistant-nagios-check.nix`. On another host, add the
import to that host's module (there is no `/etc/nixos/configuration.nix`):

```nix
# In hosts/<host>/default.nix
imports = [
  ../../modules/monitoring/homeassistant-nagios-check.nix
];
```

### 4. Rebuild System

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

The script will be available at:
- `/run/current-system/sw/bin/check_homeassistant_integrations` (requires manual token)
- `/run/current-system/sw/bin/check_homeassistant_integrations_wrapper` (reads token from SOPS)

## Usage Examples

### Manual Testing

```bash
# Using wrapper script (recommended - reads token from SOPS)
sudo -u nagios check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s -w 5 -c 10

# Using direct script with manual token
check_homeassistant_integrations -H localhost:8123 -t "YOUR_TOKEN_HERE" -w 5 -c 10

# Check via HTTPS
check_homeassistant_integrations -H hass.vulcan.lan -s -t "YOUR_TOKEN_HERE"

# Check specific integrations only
check_homeassistant_integrations -H hass.vulcan.lan -s -t "YOUR_TOKEN_HERE" -i "nest,ring,yale_home"
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-H` | Home Assistant host (host:port) | `localhost:8123` |
| `-t` | Long-lived access token | *required* |
| `-w` | Warning threshold (unavailable entities) | `5` |
| `-c` | Critical threshold (unavailable entities) | `10` |
| `-s` | Use HTTPS instead of HTTP | HTTP |
| `-i` | Check specific integrations (comma-separated) | All integrations |
| `-I` | Integration-only mode: check only that the `-i` integrations are loaded, ignore entities | Off (entity mode) |
| `-h` | Print usage and exit 0 | — |

### Example Output

**OK Status:**
```
OK - Total: 247 entities, Unavailable: 2 | entities=247 unavailable=2;5;10;0;247
```

**Warning Status:**
```
WARNING - Total: 247 entities, Unavailable: 7 | Unavailable: sensor.ring_front_door_battery, lock.front_door, climate.upstairs (+4 more) | entities=247 unavailable=7;5;10;0;247
```

**Critical Status:**
```
CRITICAL - Total: 247 entities, Unavailable: 12, Missing integrations: nest | Unavailable: sensor.ring_front_door_battery, lock.front_door, climate.upstairs, sensor.pool_temperature, binary_sensor.garage_door (+7 more) | entities=247 unavailable=12;5;10;0;247
```

**Integration-only mode (`-I`), which is what the systemd timer runs:**
```
OK - Integrations: 12/12 loaded
CRITICAL - Integrations: 11/12 loaded, Missing: nest
```
Note that `-I` output carries **no** performance data.

## Nagios Configuration

> **Note (2026-07-27):** on vulcan Nagios is fully declarative. There is no
> `/etc/nagios` directory at all — `services.nagios.objectDefs` points at a single
> generated `nagios-objects.cfg` in the Nix store
> (`modules/services/nagios.nix:1157`, wired at `:2508`). The `.cfg` snippets below
> are the *shape* of what to write; the place to write them is
> `modules/services/nagios.nix`, followed by a rebuild. Editing files under
> `/etc/nagios/objects/` does nothing.
>
> All three commands and the Home Assistant service are **already defined** there —
> see `modules/services/nagios.nix:1502` / `:1507` / `:1512` (commands) and `:2339`
> (service `Home Assistant - Integration Status`).

### Command Definition

Already present in `modules/services/nagios.nix` (lines 1500-1514). Note that the
live definitions take the host as `$ARG1$` rather than hardcoding it:

```cfg
define command {
    command_name    check_homeassistant_integrations
    command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -s -w $ARG2$ -c $ARG3$
}

define command {
    command_name    check_homeassistant_specific_integration
    command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -s -w $ARG2$ -c $ARG3$ -i $ARG4$
}

define command {
    command_name    check_homeassistant_integration_status
    command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -I -i $ARG2$
}
```

### Service Definition

Add to `modules/services/nagios.nix` (the `nagiosObjectDefs` block). The service
that is actually deployed today is the integration-status one:

```cfg
define service {
    use                     generic-service
    host_name               vulcan
    service_description     Home Assistant - Integration Status
    check_command           check_homeassistant_integration_status!127.0.0.1:8123!august,nest,ring,enphase_envoy,flume,miele,lg_thinq,cast,withings,webostv,homekit,nws
    check_interval          5
    max_check_attempts      2
    service_groups          home-assistant-integrations
}
```

Entity-threshold variants, if you want them, look like this — note that the host is
`$ARG1$`, so it comes first in the `!`-separated argument list:

```cfg
define service {
    use                     generic-service
    host_name               vulcan
    service_description     Home Assistant - All Integrations
    check_command           check_homeassistant_integrations!hass.vulcan.lan!5!10
    check_interval          5
    retry_interval          1
    max_check_attempts      3
    notification_interval   30
}

define service {
    use                     generic-service
    host_name               vulcan
    service_description     Home Assistant - Critical Integrations
    check_command           check_homeassistant_specific_integration!hass.vulcan.lan!2!5!nest,yale_home,ring,enphase_envoy
    check_interval          5
    retry_interval          1
    max_check_attempts      3
    notification_interval   15
}
```

### Host Definition

Host objects are **not** written by hand here. They are imported from the private
`nagios` flake input (`import (nagios.outPath + "/hosts.nix")`,
`modules/services/nagios.nix:537`), which is a separate git repo excluded from this
one. The generated shape is:

```cfg
define host {
    use                     linux-server
    host_name               vulcan
    alias                   Vulcan NixOS Server
    address                 <vulcan's LAN address>
}
```

## Systemd Timer (runs alongside Nagios)

The module defines a systemd timer that runs the health check every 5 minutes
(`OnBootSec=5min`, `OnUnitActiveSec=5min`, `Persistent=true`). It is **not optional
and not an example**: the timer is unconditionally `wantedBy = [ "timers.target" ]`
(`modules/monitoring/homeassistant-nagios-check.nix:69-77`), so it is enabled and
active whenever the module is imported — verified enabled + active 2026-07-27. It
runs *in addition to* the Nagios service definition, and both invoke the same
wrapper.

The service runs as `nagios:nagios` with a fixed argument list:
`-H 127.0.0.1:8123 -I -i august,nest,ring,enphase_envoy,flume,miele,lg_thinq,cast,withings,webostv,homekit,nws`.

### Inspect the Timer

```bash
# Check timer status
sudo systemctl status homeassistant-health-check.timer

# View check results
sudo journalctl -u homeassistant-health-check -f
```

### Turn the Timer Off

`systemctl disable` will not stick across a rebuild, because the unit is declared
`wantedBy = [ "timers.target" ]`. To turn it off durably, remove or guard the
`systemd.timers.homeassistant-health-check` block in
`modules/monitoring/homeassistant-nagios-check.nix` and rebuild. For a temporary
stop until the next boot or rebuild:

```bash
sudo systemctl stop homeassistant-health-check.timer
```

## Prometheus Integration (Optional)

You can export the check results to Prometheus using the `node_exporter` textfile collector:

On this host the node-exporter textfile directory is
`/var/lib/prometheus-node-exporter-textfiles`
(`--collector.textfile.directory=`, `modules/monitoring/services/system-exporters.nix:38`),
and it is created by that module — not `/var/lib/node_exporter/textfile_collector`.

```bash
# Run check and export metrics
check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s | \
  awk '/entities=/ {
    match($0, /entities=([0-9]+)/, e);
    match($0, /unavailable=([0-9]+)/, u);
    print "homeassistant_entities_total " e[1];
    print "homeassistant_entities_unavailable " u[1];
  }' | sudo tee /var/lib/prometheus-node-exporter-textfiles/homeassistant.prom
```

Note the `-I` integration-only mode emits no perfdata, so this only works in the
default entity-counting mode. Also beware `TextfileCollectorStale` alerting on a
`.prom` file that stops being refreshed.

Add to cron or systemd timer for periodic updates.

## Troubleshooting

### "API unreachable" Error

**Check Home Assistant is running:**
```bash
sudo systemctl status home-assistant
curl -k https://hass.vulcan.lan
```

**Check SSL certificate:**
```bash
openssl s_client -connect hass.vulcan.lan:443 -servername hass.vulcan.lan
```

### "Access token required" Error

**Verify SOPS secret exists:**
```bash
sudo ls -la /run/secrets/monitoring/home-assistant-token
```

**Verify token is valid:**
```bash
TOKEN=$(sudo cat /run/secrets/monitoring/home-assistant-token)
curl -H "Authorization: Bearer $TOKEN" https://hass.vulcan.lan/api/
```

### Permission Issues

**Ensure nagios user has access:**
```bash
# Check SOPS secret ownership
sudo ls -la /run/secrets/monitoring/home-assistant-token

# Should show: -r-------- 1 nagios nagios ...

# Test as nagios user
sudo -u nagios check_homeassistant_integrations_wrapper -H 127.0.0.1:8123 -I -i august,nest,ring
```

### "API unreachable" in Systemd/Nagios but Works Manually

**Symptoms:**
- Manual execution as nagios user succeeds
- Systemd service or Nagios check fails with "API unreachable"

**Cause:**
Systemd services don't inherit the same PATH as interactive shells, so `curl`, `jq`, and other commands may not be found.

**Solution:**
The wrapper script explicitly sets PATH to include required binaries:
```nix
export PATH="${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:$PATH"
```

This is already configured in the NixOS module. If you encounter this issue, verify the wrapper script includes the PATH export.

### High Unavailable Count

**Check which entities are unavailable:**
```bash
# Query Home Assistant API directly
TOKEN=$(sudo cat /run/secrets/monitoring/home-assistant-token)
curl -H "Authorization: Bearer $TOKEN" https://hass.vulcan.lan/api/states | \
  jq '.[] | select(.state == "unavailable") | .entity_id'
```

**Common causes:**
- Devices powered off or disconnected
- Network connectivity issues
- Cloud service outages (Ring, Nest, etc.)
- Integration authentication expired
- Device battery dead

## Integration-Specific Monitoring

To monitor only critical integrations and reduce false positives:

```bash
# Monitor only security and climate devices
check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s \
  -i "yale_home,ring,nest,august" -w 1 -c 3
```

## Performance Metrics

The script outputs Nagios performance data:

```
entities=247 unavailable=2;5;10;0;247
```

Format: `label=value;warn;crit;min;max`

- `2` = current value of the `unavailable` label (unavailable entities); `247` is
  the separate `entities` label (total entities)
- `5` = warning threshold
- `10` = critical threshold
- `0` = minimum value
- `247` = maximum value (total entities)

This data can be graphed by Nagios plugins like PNP4Nagios or exported to Prometheus/Grafana.

## Adjusting Thresholds

Adjust warning/critical thresholds based on your environment:

**Conservative (fewer false alerts):**
```bash
check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s -w 10 -c 20
```

**Aggressive (catch issues early):**
```bash
check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s -w 2 -c 5
```

**Critical integrations only (zero tolerance):**
```bash
check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s \
  -i "yale_home,nest,ring" -w 1 -c 1
```

## Security Considerations

- **Token Storage**: Token is stored in SOPS-encrypted secrets, only readable by `nagios` user
- **Token Rotation**: Regenerate tokens periodically (every 6-12 months)
- **API Access**: Token has full Home Assistant API access - protect accordingly
- **Network Security**: Use HTTPS (`-s` flag) to prevent token interception
- **Least Privilege**: Consider creating a dedicated "read-only" Home Assistant user for monitoring

## Automation Examples

### Alert on Critical Integration Failure

Create a Nagios notification command that sends alerts only for critical integrations:

```cfg
define service {
    use                     generic-service
    host_name               vulcan
    service_description     Home Assistant - Security Devices
    check_command           check_homeassistant_specific_integration!0!1!yale_home,ring,august
    notifications_enabled   1
    notification_period     24x7
    notification_options    c,r
    contact_groups          admins
}
```

### Grafana Dashboard

If using Prometheus exporters, create a Grafana dashboard with:
- Total entities gauge
- Unavailable entities over time (line graph)
- Integration status table
- Alerts for critical thresholds

## References

- Home Assistant REST API: https://developers.home-assistant.io/docs/api/rest
- Home Assistant WebSocket API: https://developers.home-assistant.io/docs/api/websocket
- Nagios Plugin Development: https://nagios-plugins.org/doc/guidelines.html
