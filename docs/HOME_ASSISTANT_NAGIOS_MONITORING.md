# Home Assistant Integration Monitoring for Nagios

This guide explains how to monitor Home Assistant integration health using Nagios or standalone health checks.

## Overview

The `check_homeassistant_integrations` script monitors:
- **Total entities** across all integrations
- **Unavailable entities** (devices/sensors that are offline or unreachable)
- **Failed integrations** (integrations that are disabled or in error state)
- **Specific integration health** (optional filtering)

Returns standard Nagios exit codes:
- `OK (0)`: All integrations healthy, unavailable entities below warning threshold
- `WARNING (1)`: Unavailable entities >= warning threshold (default: 5)
- `CRITICAL (2)`: Unavailable entities >= critical threshold (default: 10) OR any integration failures
- `UNKNOWN (3)`: Unable to connect to Home Assistant API

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
# Edit SOPS secrets file
sops /etc/nixos/secrets.yaml

# Add under a monitoring section:
monitoring:
  home-assistant-token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."

# Save and exit
```

### 3. Enable Monitoring Module

Add to your NixOS configuration:

```nix
# In configuration.nix or flake.nix
imports = [
  ./modules/monitoring/homeassistant-nagios-check.nix
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
CRITICAL - Total: 247 entities, Unavailable: 12, Failed integrations: nest (disabled) | Unavailable: sensor.ring_front_door_battery, lock.front_door, climate.upstairs, sensor.pool_temperature, binary_sensor.garage_door (+7 more) | entities=247 unavailable=12;5;10;0;247
```

## Nagios Configuration

### Command Definition

Add to `/etc/nagios/objects/commands.cfg`:

```cfg
define command {
    command_name    check_homeassistant_integrations
    command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s -w $ARG1$ -c $ARG2$
}

define command {
    check_homeassistant_specific_integration
    command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s -w $ARG1$ -c $ARG2$ -i $ARG3$
}
```

### Service Definition

Add to `/etc/nagios/objects/services.cfg`:

```cfg
define service {
    use                     generic-service
    host_name               vulcan
    service_description     Home Assistant - All Integrations
    check_command           check_homeassistant_integrations!5!10
    check_interval          5
    retry_interval          1
    max_check_attempts      3
    notification_interval   30
}

define service {
    use                     generic-service
    host_name               vulcan
    service_description     Home Assistant - Critical Integrations
    check_command           check_homeassistant_specific_integration!2!5!nest,yale_home,ring,enphase_envoy
    check_interval          5
    retry_interval          1
    max_check_attempts      3
    notification_interval   15
}
```

### Host Definition

Add to `/etc/nagios/objects/hosts.cfg`:

```cfg
define host {
    use                     linux-server
    host_name               vulcan
    alias                   Vulcan NixOS Server
    address                 192.168.1.2
}
```

## Systemd Timer (Alternative to Nagios)

The module includes an optional systemd timer that runs the health check every 5 minutes.

### Enable Timer

```bash
# Enable the timer
sudo systemctl enable homeassistant-health-check.timer
sudo systemctl start homeassistant-health-check.timer

# Check timer status
sudo systemctl status homeassistant-health-check.timer

# View check results
sudo journalctl -u homeassistant-health-check -f
```

### Disable Timer (if using Nagios)

```bash
sudo systemctl stop homeassistant-health-check.timer
sudo systemctl disable homeassistant-health-check.timer
```

## Prometheus Integration (Optional)

You can export the check results to Prometheus using the `node_exporter` textfile collector:

```bash
# Create textfile directory if not exists
sudo mkdir -p /var/lib/node_exporter/textfile_collector

# Run check and export metrics
check_homeassistant_integrations_wrapper -H hass.vulcan.lan -s | \
  awk '/entities=/ {
    match($0, /entities=([0-9]+)/, e);
    match($0, /unavailable=([0-9]+)/, u);
    print "homeassistant_entities_total " e[1];
    print "homeassistant_entities_unavailable " u[1];
  }' | sudo tee /var/lib/node_exporter/textfile_collector/homeassistant.prom
```

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

- `247` = current value (unavailable entities)
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
