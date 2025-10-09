# Home Assistant Alerting & Monitoring

This document describes the comprehensive Home Assistant alerting and monitoring system that has been implemented on vulcan.

## Overview

Based on community best practices and security research, we've implemented 22 alert rules across 3 severity levels to monitor your home's security, safety, and operational status. This includes presence detection with 3 alerts that trigger when the house is unoccupied.

## Alert Rules Implemented

### 🔴 CRITICAL Alerts (8 rules)

These alerts trigger immediate notifications and require urgent action:

1. **WaterLeakDetected** - Immediate (0s delay)
   - Triggers: When Flume water sensor detects a leak
   - Risk: Property damage, flooding
   - Action: Check all water sources, shut off main if necessary

2. **HighWaterFlowDetected** - 2 minute delay
   - Triggers: Abnormally high water flow detected
   - Risk: Burst pipe, major water loss
   - Action: Check for burst pipes, consider shutting off main water supply

3. **DoorLeftUnlocked** - 5 minute delay
   - Triggers: Any door (front, garage, side) unlocked for 5+ minutes
   - Risk: Security breach, unauthorized access
   - Action: Verify door should be unlocked, lock if unintended

4. **DoorLeftOpenCritical** - 30 minute delay
   - Triggers: Any door left open for 30+ minutes
   - Risk: Security risk, energy loss
   - Action: Close the door immediately

5. **GrillTemperatureDangerouslyHigh** - 15 minute delay
   - Triggers: Grill temperature >260°C (500°F) for 15+ minutes
   - Risk: Fire hazard
   - Action: Check grill immediately, reduce temperature or shut off

6. **GrillOnNobodyHome** - 10 minute delay
   - Triggers: Grill is running but everyone has left the house
   - Risk: Fire hazard with no one to monitor
   - Action: Return home or contact neighbor to check grill and turn off if necessary

7. **DoorUnlockedEveryoneAway** - 5 minute delay
   - Triggers: Door unlocked but everyone has left the house
   - Risk: Security breach, unauthorized access
   - Action: Lock door remotely via Home Assistant or return home to secure

8. **DoorOpenEveryoneAway** - 10 minute delay
   - Triggers: Door open but everyone has left the house
   - Risk: Security breach, energy loss
   - Action: Return home to close door or contact neighbor for assistance

### ⚠️ WARNING Alerts (8 rules)

These alerts indicate issues that need attention but aren't immediately critical:

9. **DoorLeftOpenWarning** - 15 minute delay
   - Triggers: Door open for 15+ minutes
   - Action: Consider closing to save energy and maintain security

10. **CriticalDeviceBatteryLow** - 1 hour delay
   - Triggers: Lock or water sensor battery <20%
   - Action: Replace battery soon

11. **CriticalDeviceOffline** - 10 minute delay
   - Triggers: Lock or thermostat unavailable for 10+ minutes
   - Action: Check device connectivity and power

12. **WaterSensorOffline** - 10 minute delay
   - Triggers: Flume water sensor lost connectivity
   - Risk: Water leak detection disabled
   - Action: Check sensor power and network connection

13. **WaterSensorBatteryLow** - 1 hour delay
    - Triggers: Flume sensor battery low
    - Action: Replace battery to maintain leak detection

14. **DishwasherProblem** - 5 minute delay
    - Triggers: Miele dishwasher reports problem state
    - Action: Check dishwasher display for error code

15. **GrillLeftOnExtended** - 3 hour delay
    - Triggers: Traeger grill running for 3+ hours
    - Action: Check if still needed, turn off if done

16. **SolarProductionLow** - 30 minute delay
    - Triggers: Solar production <0.5 kWh during peak hours (10am-3pm)
    - Action: Check Enphase app for inverter issues

### ℹ️ INFO Alerts (6 rules)

These alerts provide useful information for optimization and awareness:

17. **HVACRunningDoorOpen** - 20 minute delay
    - Triggers: HVAC active while door is open
    - Impact: Energy waste

18. **iPhoneBatteryLowAway** - 5 minute delay
    - Triggers: iPhone battery <10%
    - Impact: Loss of presence detection

19. **PoolTemperatureDeviation** - 1 hour delay
    - Triggers: Pool temp >3°C away from target
    - Impact: Comfort, equipment efficiency

20. **GrillNeedsCleaning** - 5 minute delay
    - Triggers: Traeger indicates cleaning needed
    - Action: Clean when convenient

21. **DishwasherDoorOpen** - 2 hour delay
    - Triggers: Dishwasher door open for 2+ hours
    - Action: Close door if done unloading

22. **FreezeWarning** - 10 minute delay
    - Triggers: Freezing temperatures detected
    - Action: Protect outdoor pipes and plants

## Email Notifications

All alerts are configured to send email notifications to: **johnw@newartisans.com**

### Alert Routing

- **CRITICAL alerts** → Immediate email, repeat every 15 minutes
  - Subject: `[CRITICAL] AlertName - IMMEDIATE ACTION REQUIRED`

- **WARNING alerts** → Email, repeat every 1 hour
  - Subject: `[severity] AlertName on vulcan`

- **INFO alerts** → Email, repeat every 1 hour
  - Subject: `[severity] AlertName on vulcan`

## Grafana Dashboard

A comprehensive monitoring dashboard has been created: **Home Assistant - Security & Safety**

### Access the Dashboard

1. **URL**: https://grafana.vulcan.lan
2. Navigate to: Dashboards → Home Assistant - Security & Safety
3. Default time range: Last 6 hours
4. Auto-refresh: Every 30 seconds

### Dashboard Panels

The dashboard includes:

1. **Door Locks Status** - Real-time lock states (front, garage, side)
2. **Door Sensors** - Open/closed status for all doors
3. **Water Safety** - Leak detection and high flow alerts
4. **Grill Temperature** - Current temperature monitoring
5. **Indoor Temperature** - All Nest thermostats (downstairs, family room, upstairs)
6. **Solar Energy Production** - Today's production vs 7-day average
7. **iPhone Battery Levels** - John's and Nasim's iPhones
8. **Critical Device Availability** - Locks and water sensor online status
9. **Appliance Status** - Dishwasher problem detection
10. **Dashboard Info** - Quick reference guide

### Color Coding

- 🟢 **Green** - Normal, safe, locked, online
- 🟠 **Orange** - Warning, open, attention needed
- 🔴 **Red** - Critical, unlocked, offline, leak detected

## Alertmanager Web Interface

View and manage active alerts:

**URL**: https://alertmanager.vulcan.lan

Features:
- View all active alerts
- Silence alerts temporarily
- See alert history
- Group alerts by severity

## Home Assistant Metrics

All metrics are scraped from Home Assistant every 60 seconds via the Prometheus API endpoint:
- **Endpoint**: https://hass.vulcan.lan:443/api/prometheus
- **Authentication**: Bearer token (SOPS-encrypted)

### Key Metrics Available

```
# Lock states (0=unlocked, 1=locked)
homeassistant_lock_state{entity="lock.front_door"}
homeassistant_lock_state{entity="lock.garage"}
homeassistant_lock_state{entity="lock.side_door"}

# Door sensors (0=closed, 1=open)
homeassistant_binary_sensor_state{entity="binary_sensor.front_door_door"}
homeassistant_binary_sensor_state{entity="binary_sensor.garage_door"}
homeassistant_binary_sensor_state{entity="binary_sensor.side_door_door"}

# Water safety (0=normal, 1=alert)
homeassistant_binary_sensor_state{entity="binary_sensor.flume_sensor_sierra_oaks_leak_detected"}
homeassistant_binary_sensor_state{entity="binary_sensor.flume_sensor_sierra_oaks_high_flow"}

# Grill temperature (°C)
homeassistant_sensor_temperature_celsius{entity=~"sensor.kababchi_probe.*"}

# Climate/thermostats
homeassistant_climate_current_temperature_celsius{entity=~"climate.*"}

# Energy production (kWh)
homeassistant_sensor_energy_kwh{entity="sensor.envoy_202332010883_energy_production_today"}

# Battery levels (%)
homeassistant_sensor_battery_percent{entity=~"sensor.*battery_level"}

# Device availability (0=offline, 1=online)
homeassistant_entity_available{domain=~"lock|climate"}
```

## Testing Alerts

To test if alerts are working properly:

### 1. Check Alert Rules Loaded
```bash
curl -s http://localhost:9090/api/v1/rules | jq -r '.data.groups[] | select(.file | contains("home-assistant")) | {name: .name, rules: (.rules | length)}'
```

Expected output:
```json
{"name":"home_assistant_critical","rules":5}
{"name":"home_assistant_warning","rules":8}
{"name":"home_assistant_info","rules":6}
```

### 2. View Active Alerts
```bash
curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname | test("Water|Door|Grill")) | {alert: .labels.alertname, state: .state}'
```

### 3. Check Alertmanager Alerts
```bash
curl -s http://localhost:9093/api/v2/alerts | jq -r '.[] | {alert: .labels.alertname, status: .status.state}'
```

### 4. Manual Alert Testing

Simulate a door left open:
1. Open any door (front, garage, or side)
2. Wait 15 minutes
3. Check for `DoorLeftOpenWarning` alert
4. Wait 30 minutes total
5. Check for `DoorLeftOpenCritical` alert
6. Close door - alerts should auto-resolve

## Presence Detection Implementation

✅ **Presence detection is now fully implemented!**

The system uses Home Assistant person entities (`person.john_wiegley` and `person.nasim_wiegley`) to track when John and Nasim are home or away. Template binary sensors combine these states to provide presence detection for alerting.

### Available Presence Sensors

Four binary sensors are available in Home Assistant and exported to Prometheus:

1. **binary_sensor.anyone_home**
   - True (1) if either John or Nasim is home
   - False (0) if both are away
   - Used for: Presence validation, energy optimization

2. **binary_sensor.everyone_away**
   - True (1) when both John and Nasim are away
   - False (0) if anyone is home
   - Used for: Critical security alerts

3. **binary_sensor.john_home**
   - True (1) when John is home
   - False (0) when John is away
   - Used for: Individual tracking

4. **binary_sensor.nasim_home**
   - True (1) when Nasim is home
   - False (0) when Nasim is away
   - Used for: Individual tracking

### Presence-Based Alerts

Three CRITICAL alerts use presence detection:

1. **GrillOnNobodyHome** (10 minute delay)
   - Triggers when grill is running but everyone is away
   - Prevents unattended fire hazard

2. **DoorUnlockedEveryoneAway** (5 minute delay)
   - Triggers when any door is unlocked but everyone is away
   - Prevents security breach

3. **DoorOpenEveryoneAway** (10 minute delay)
   - Triggers when any door is open but everyone is away
   - Prevents security breach and energy loss

### How It Works

Person entities are tracked via the Home Assistant mobile app on John's and Nasim's iPhones. The app reports location and provides home/away status based on the home zone defined in Home Assistant.

The template binary sensors evaluate in real-time:
```yaml
# Example: anyone_home sensor
state: "{{ is_state('person.john_wiegley', 'home') or is_state('person.nasim_wiegley', 'home') }}"
```

These sensors are exported to Prometheus every 60 seconds and monitored by alert rules that trigger emails when critical conditions are detected.

### Testing Presence Detection

To test the system:

1. Check current presence state:
```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=homeassistant_binary_sensor_state{entity="binary_sensor.everyone_away"}' \
  | jq -r '.data.result[].value[1]'
```

2. Leave home with both phones and wait 10 minutes

3. Verify presence sensors update:
   - `binary_sensor.everyone_away` should show 1 (true)
   - `binary_sensor.anyone_home` should show 0 (false)

4. Test alerts by leaving a door unlocked or opening a door

5. Check for email alerts within 5-10 minutes

## File Locations

### NixOS Configuration Files
- **Alert Rules**: `/etc/nixos/modules/monitoring/alerts/home-assistant.yaml`
- **Prometheus Config**: `/etc/nixos/modules/monitoring/services/prometheus-server.nix`
- **Grafana Config**: `/etc/nixos/modules/services/grafana.nix`
- **Dashboard JSON**: `/etc/nixos/modules/monitoring/dashboards/home-assistant.json`
- **This Documentation**: `/etc/nixos/docs/HOME_ASSISTANT_ALERTING.md`

### Runtime Files
- **Grafana Dashboard**: `/var/lib/grafana/dashboards/home-assistant.json`
- **Prometheus Data**: `/var/lib/prometheus`
- **Alertmanager Data**: `/var/lib/alertmanager`

## Modifying Alerts

To add or modify alert rules:

1. Edit the alert rules file:
```bash
sudo nano /etc/nixos/modules/monitoring/alerts/home-assistant.yaml
```

2. Add to git (required for flakes):
```bash
git add modules/monitoring/alerts/home-assistant.yaml
```

3. Rebuild NixOS configuration:
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

4. Verify new rules loaded:
```bash
curl -s http://localhost:9090/api/v1/rules | jq -r '.data.groups[] | select(.file | contains("home-assistant"))'
```

## Troubleshooting

### No Alerts Firing
- Check Prometheus is scraping Home Assistant: `curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="home_assistant")'`
- Verify metrics are available: `curl -s http://localhost:9090/api/v1/query?query=homeassistant_lock_state`
- Check alert evaluation: `curl -s http://localhost:9090/api/v1/alerts`

### Not Receiving Emails
- Check Alertmanager status: `systemctl status alertmanager`
- Verify Postfix is running: `systemctl status postfix`
- Check Alertmanager logs: `sudo journalctl -u alertmanager -f`
- Test email manually: `echo "Test alert" | mail -s "Test from vulcan" johnw@newartisans.com`

### Dashboard Not Showing Data
- Verify Grafana is running: `systemctl status grafana`
- Check Prometheus data source: Visit https://grafana.vulcan.lan/datasources
- Reload dashboards: Restart Grafana or wait for auto-refresh (10s interval)

### Metrics Missing
- Check Home Assistant Prometheus integration: `sudo journalctl -u home-assistant | grep prometheus`
- Verify token is valid: `cat /var/lib/prometheus-hass/token`
- Test endpoint manually: `curl -H "Authorization: Bearer $(cat /var/lib/prometheus-hass/token)" https://hass.vulcan.lan/api/prometheus`

## Security Notes

- All communication between Prometheus and Home Assistant uses HTTPS with step-ca certificates
- Home Assistant token is encrypted with SOPS and only accessible at runtime
- Alertmanager web interface uses step-ca TLS certificates
- Email notifications go through local Postfix (no external SMTP credentials required)

## Maintenance

### Regular Tasks

- **Monthly**: Review and tune alert thresholds based on false positive rate
- **Quarterly**: Check battery levels proactively before alerts fire
- **Annually**: Review and update alert rules for new devices

### Monitoring the Monitors

The monitoring stack itself is monitored:
- Prometheus has self-monitoring alerts
- Systemd service health is monitored
- Certificate expiration is tracked
- Backup success/failure is alerted

## Support

For issues or questions:
- Check logs: `sudo journalctl -u prometheus -u alertmanager -u grafana -f`
- Review Prometheus UI: http://localhost:9090
- Check Alertmanager UI: https://alertmanager.vulcan.lan
- View Grafana: https://grafana.vulcan.lan

## Summary

You now have a comprehensive, production-ready alerting system monitoring your home for:
- 🔒 Security issues (unlocked doors, doors left open, presence-based alerts)
- 💧 Safety hazards (water leaks, high flow, grill temperature)
- 🔋 Device health (batteries, availability)
- ⚡ Energy optimization (HVAC efficiency, solar production)
- 🏠 Operational status (appliances, climate control)
- 👥 Presence detection (alerts when nobody is home)

All alerts are routed to your email with appropriate severity levels and repeat intervals. The Grafana dashboard provides real-time visualization of all critical metrics.

**Presence Detection**:
The system now tracks when John and Nasim are home/away using Home Assistant person entities. Binary sensors provide:
- `binary_sensor.anyone_home` - True if anyone is home
- `binary_sensor.everyone_away` - True when both are away
- `binary_sensor.john_home` - John's presence
- `binary_sensor.nasim_home` - Nasim's presence

These enable critical alerts like:
- Grill on but nobody home
- Doors unlocked when everyone away
- Doors open when everyone away

**Next Steps**:
1. Access the dashboard at https://grafana.vulcan.lan
2. Monitor your email for any active alerts
3. Test presence detection by leaving home and verifying alerts trigger correctly
