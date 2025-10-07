# Home Assistant Device Integration Guide

This document provides setup instructions for all IoT devices integrated with Home Assistant on this system.

## Overview

**Built-in Integrations (13)**: Configured via NixOS extraComponents
**Custom Integrations (4)**: Require HACS or manual installation

---

## Built-in Integrations

These integrations are pre-configured in the NixOS Home Assistant module and will be available after rebuild.

### 1. ASUS WiFi Routers (asuswrt)

**Component**: `asuswrt`

**Setup**:
1. Go to Settings > Devices & Services > Add Integration
2. Search for "ASUSWRT"
3. Enter router IP address (typically 192.168.1.1)
4. Enter admin username and password
5. Choose connection method (SSH recommended for device tracking)

**Features**:
- Device presence detection
- Network traffic monitoring
- Connected device list
- Upload/download statistics

**Requirements**:
- Router admin credentials
- SSH enabled on router (for best device tracking)

---

### 2. Enphase Solar Inverter (enphase_envoy)

**Component**: `enphase_envoy`

**Setup**:
1. Locate your Envoy gateway IP address (check router or Enphase app)
2. Go to Settings > Devices & Services > Add Integration
3. Search for "Enphase Envoy"
4. Enter Envoy IP address
5. Enter Envoy serial number (found on device or in Enphase app)
6. Provide Enlighten cloud credentials if using newer firmware

**Features**:
- Real-time solar production
- Lifetime energy production
- Individual microinverter status
- Grid import/export monitoring
- Battery status (if applicable)

**Requirements**:
- Enphase Envoy gateway on local network
- Enphase Enlighten account (for firmware 7+)

**Energy Dashboard**: Automatically integrates with HA Energy Dashboard

---

### 3. Tesla Wall Connector (tesla)

**Component**: `tesla`

**Setup**:
1. Go to Settings > Devices & Services > Add Integration
2. Search for "Tesla"
3. Authenticate with your Tesla account
4. Select your Wall Connector from discovered devices

**Features**:
- Charging status and power
- Energy delivered per session
- Charging schedule control
- Real-time power monitoring

**Requirements**:
- Tesla account credentials
- Wall Connector on same network

**Energy Dashboard**: Charging data integrates with Energy Dashboard

---

### 4. Flume Water Meter (flume)

**Component**: `flume`

**Setup**:
1. Ensure Flume device is set up with Flume mobile app first
2. Go to Settings > Devices & Services > Add Integration
3. Search for "Flume"
4. Enter Flume account credentials
5. Grant Home Assistant access

**Features**:
- Real-time water usage monitoring
- Leak detection alerts
- Daily/monthly usage statistics
- Historical data analysis

**Requirements**:
- Flume account with active subscription
- Flume device installed and online

---

### 5. Google Nest Thermostats (nest)

**Component**: `nest`

**Setup** (Device Access Console method):
1. Create a Google Cloud Project at console.cloud.google.com
2. Enable Device Access API
3. Create OAuth 2.0 credentials
4. Subscribe to Device Access ($5 one-time fee)
5. In Home Assistant: Settings > Devices & Services > Add Integration
6. Search for "Nest"
7. Follow OAuth authentication flow

**Features**:
- Temperature control
- Mode switching (heat/cool/off)
- Eco mode control
- Current temperature and humidity
- HVAC state monitoring

**Requirements**:
- Google account
- Google Cloud project with Device Access API
- $5 one-time Device Access subscription

**Alternative**: Nest thermostats with Matter support can use the Matter integration instead

---

### 6. Ring Doorbell & Chimes (ring)

**Component**: `ring`

**Setup**:
1. Go to Settings > Devices & Services > Add Integration
2. Search for "Ring"
3. Enter Ring account credentials
4. Complete 2FA if enabled
5. Select devices to integrate

**Features**:
- Doorbell press events
- Motion detection
- Camera snapshots
- Video streaming (with Ring subscription)
- Chime control
- Battery status

**Requirements**:
- Ring account
- Ring devices set up in Ring app
- Ring Protect subscription (for video history)

---

### 7. MyQ Garage Door Opener (myq)

**Component**: `myq`

**Setup**:
1. Go to Settings > Devices & Services > Add Integration
2. Search for "MyQ"
3. Enter MyQ account credentials
4. Authorize Home Assistant

**Features**:
- Open/close garage door
- Door status monitoring
- Control multiple doors
- Automation support

**Requirements**:
- MyQ account
- MyQ-compatible garage door opener

**Note**: MyQ integration can be unreliable due to frequent API changes by Chamberlain

---

### 8. Pentair Pool Systems (screenlogic)

**Component**: `screenlogic`

**Supported Devices**:
- Pentair IntelliCenter
- Pentair IntelliFlo pool pump
- Other Pentair ScreenLogic-compatible devices

**Setup**:
1. Ensure ScreenLogic Protocol Adapter is on network
2. Go to Settings > Devices & Services
3. ScreenLogic should auto-discover
4. If not, manually add and enter IP address

**Features**:
- Pool/spa temperature monitoring
- Pump speed control
- Filter and light control
- Chemical monitoring (if equipped)
- Automation scheduling

**Requirements**:
- Pentair ScreenLogic Protocol Adapter
- Pentair IntelliCenter or compatible system

---

### 9. Miele Dishwasher (miele)

**Component**: `miele`

**Setup**:
1. Ensure Miele appliance is connected to Miele app
2. Go to Settings > Devices & Services > Add Integration
3. Search for "Miele"
4. Enter Miele account credentials
5. Select appliances to integrate

**Features**:
- Cycle status monitoring
- Remaining time
- Cycle completion notifications
- Remote start (if supported by model)
- Program selection

**Requirements**:
- Miele account
- Miele appliance with WiFi (Miele@home)

---

### 10. LG ThinQ Smart Appliances (lg_thinq)

**Component**: `lg_thinq`

**Setup** (requires Personal Access Token):
1. Create a Personal Access Token (PAT):
   - Visit https://connect-pat.lgthinq.com/ (requires LG ThinQ account)
   - Click **ADD NEW TOKEN**
   - Enter a token name
   - Select ALL authorized scopes:
     - Permission to view all devices
     - Permission to view all device statuses
     - All device control rights
     - All device event subscription rights
     - All device push notification permissions
     - Permission to inquiry device energy consumption
   - Click **CREATE TOKEN**
   - Copy the generated PAT token value

2. Add the token to secrets:
```bash
sops /etc/nixos/secrets.yaml
# Add under home-assistant section:
# lg-thinq-token: "your_personal_access_token_here"
```

3. Rebuild NixOS configuration:
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

4. Add integration in Home Assistant:
   - Go to Settings > Devices & Services > Add Integration
   - Search for "LG ThinQ"
   - Enter your PAT token value
   - Select your region/country
   - Choose devices to integrate

**Features**:
- Full control of LG smart appliances
- Real-time status monitoring
- Energy consumption tracking (yesterday, this month, last month)
- Device notifications and error events
- Automation support for all device states

**Supported Devices**:
- **Laundry**: Washers, dryers, stylers, washtowers, washcombos
- **Kitchen**: Refrigerators, dishwashers, ovens, microwaves, cooktops
- **Cooking**: Range hoods, wine cellars, kimchi refrigerators
- **Climate**: Air conditioners, air purifiers, dehumidifiers, humidifiers
- **Cleaning**: Robot vacuums, stick vacuums
- **Other**: Water heaters, system boilers, water purifiers, plant cultivators

**Requirements**:
- LG ThinQ account
- LG smart appliances registered in LG ThinQ app
- Personal Access Token (PAT) from https://connect-pat.lgthinq.com/
- Internet connection (cloud-based integration)

**Energy Dashboard**: Supports energy consumption sensors for compatible devices

**Available Platforms**:
- Binary Sensors (door open, remote start enabled, etc.)
- Buttons (start/pause operations)
- Climate (temperature control for HVAC)
- Events (notifications, errors, completion alerts)
- Fans (ceiling fans)
- Numbers (timers, temperature setpoints, delays)
- Selects (operating modes, speeds, cook modes)
- Sensors (status, temperature, humidity, air quality, timers)
- Switches (power, modes, features)
- Vacuums (robot cleaner control)

**Data Updates**:
- Status changes: Real-time events (new models)
- Status (legacy models): Every 5 minutes
- Energy consumption: Daily (updated each morning with previous day's data)

**Troubleshooting**:
- **Token not valid**: Verify PAT at https://connect-pat.lgthinq.com/
- **Country not supported**: Check PAT's valid countries, select correct region
- **API calls exceeded**: Wait some time, LG limits API rate per token
- **Device not appearing**: Ensure device is registered in LG ThinQ mobile app first

**Automation Examples**:
```yaml
# Notification when washer cycle completes
alias: Washer Complete Notification
triggers:
  - trigger: state
    entity_id: event.washer_notification
actions:
  - condition: state
    entity_id: event.washer_notification
    attribute: event_type
    state: washing_is_complete
  - service: notify.mobile_app
    data:
      message: "Washer cycle is complete!"
```

**Note**: LG ThinQ uses the official LG ThinQ Connect API introduced in Home Assistant 2024.11+

---

### 11. Google Home Hub (cast)

**Component**: `cast`

**Setup**:
1. Google Cast devices should auto-discover
2. Go to Settings > Devices & Services
3. Look for "Google Cast" discovered devices
4. Configure each Cast device

**Features**:
- Cast Home Assistant dashboards
- Media playback control
- TTS (Text-to-Speech) announcements
- Display control

**Requirements**:
- Google Home Hub or Chromecast device on same network

**Dashboard Casting**:
```yaml
# Use the Home Assistant Cast feature to display dashboards
# Access via: https://hass.vulcan.lan/lovelace-cast/default
```

---

### 12. Withings Digital Scale (withings)

**Component**: `withings`

**Setup**:
1. Create a Withings Developer Account at https://account.withings.com/partner/add_oauth2
2. Create a new application:
   - Application Name: "Home Assistant"
   - Description: "Home Assistant Integration"
   - Callback URL: `https://my.home-assistant.io/redirect/oauth`
   - Logo: (optional)
3. Note your Client ID and Consumer Secret
4. In Home Assistant:
   - Go to Settings > Devices & Services > Add Integration
   - Search for "Withings"
   - Enter your Client ID and Consumer Secret
   - Follow the OAuth authentication flow
5. Authorize Home Assistant to access your Withings data

**Features**:
- Weight measurements
- Body composition (fat %, muscle %, water %)
- Heart rate data
- Blood pressure readings
- Sleep tracking data
- Activity data (steps, distance, calories)
- Temperature measurements
- SpO2 levels (if device supports)

**Supported Devices**:
- Body+ Smart Scale
- Body Cardio
- Body Comp
- Blood Pressure Monitor
- Sleep Analyzer
- Thermo
- Other Withings health products

**Requirements**:
- Withings account with device(s) registered
- Withings Developer account (free)
- Client ID and Consumer Secret from Withings Developer Portal
- Internet connection (cloud-based integration)

**Data Refresh**:
- Data updates automatically when synced to Withings cloud
- Sensors dynamically appear based on recent measurements
- Historical data available via attributes

**Privacy Note**:
- Integration uses OAuth 2.0 for secure authentication
- Only data you authorize is shared with Home Assistant
- Data pulled from Withings cloud, not directly from devices

---

### 13. LG webOS Smart TV (webostv)

**Component**: `webostv`

**Setup**:
1. Ensure your LG TV is powered on and connected to the network
2. Go to Settings > Devices & Services
3. LG webOS TV should auto-discover on your network
4. If not auto-discovered, manually add:
   - Click "Add Integration"
   - Search for "LG webOS Smart TV"
   - Enter TV IP address
5. Accept the pairing request on your TV screen
6. TV will be added to Home Assistant

**Features**:
- Power on/off control
- Volume control
- Media playback control
- Input source switching
- Channel control
- App launching
- Notifications on TV screen
- Media information display
- Screenshot capability

**Requirements**:
- LG Smart TV with webOS 2.0 or later
- TV connected to same network as Home Assistant
- TV powered on for initial pairing

**Wake on LAN**:
- To power on TV remotely, enable "LG Connect Apps" in TV settings
- TV must be connected via Ethernet (WiFi Wake-on-LAN unreliable)
- Settings path: General > Mobile TV On > Turn On Via WiFi (or Ethernet)

**App Launching**:
```yaml
# Example automation to launch Netflix
service: webostv.button
target:
  entity_id: media_player.lg_webos_smart_tv
data:
  button: NETFLIX
```

**Sending Notifications**:
```yaml
# Display notification on TV
service: notify.lg_webos_tv
data:
  message: "Your message here"
```

**Supported Models**:
- All LG TVs with webOS 2.0+ (2015 and newer)
- Verified compatibility with webOS 3.0, 4.0, 5.0, 6.0, 22, 23

**Network Discovery**:
- Integration uses SSDP for auto-discovery
- Ensure multicast is enabled on your network
- mDNS/Zeroconf must be enabled in Home Assistant (already configured)

**Troubleshooting**:
- **TV not discovered**: Check TV and Home Assistant are on same network/VLAN
- **Pairing fails**: Ensure TV is powered on and not in screen saver mode
- **Wake-on-LAN not working**:
  - Enable "LG Connect Apps" or "Mobile TV On" in TV settings
  - Use Ethernet connection instead of WiFi
  - Check if TV supports WoL (most 2015+ models do)
- **Commands not working**: Verify TV is on and paired
- **Connection lost**: Re-pair the integration via UI

**Privacy Note**:
- Integration communicates locally over your network
- No cloud connection required
- TV MAC address and IP stored in Home Assistant

---

## Custom Integrations (via HACS)

These integrations require manual installation through HACS (Home Assistant Community Store).

### Installing HACS

1. Install HACS:
```bash
# SSH into Home Assistant or use terminal
wget -O - https://get.hacs.xyz | bash -
```

2. Restart Home Assistant
3. Go to Settings > Devices & Services > Add Integration
4. Search for "HACS"
5. Follow authentication with GitHub

### 14. B-Hyve Sprinkler Control

**Repository**: `sebr/bhyve-home-assistant`
**Installation**: Via HACS

**Setup**:
1. Install via HACS:
   - HACS > Integrations > Explore & Download Repositories
   - Search for "B-Hyve"
   - Install
2. Restart Home Assistant
3. Settings > Devices & Services > Add Integration
4. Search for "B-Hyve"
5. Enter Orbit B-Hyve account credentials

**Features**:
- Zone control (start/stop watering)
- Schedule management
- Rain delay
- Water usage tracking
- Smart watering control

**Requirements**:
- Orbit B-Hyve account
- B-Hyve compatible timer/controller

---

### 15. Dreame Robot Vacuum

**Repository**: `Tasshack/dreame-vacuum`
**Installation**: Via HACS

**Setup**:
1. Install via HACS:
   - HACS > Integrations > Explore & Download Repositories
   - Search for "Dreame Vacuum"
   - Install
2. Restart Home Assistant
3. Settings > Devices & Services > Add Integration
4. Search for "Dreame Vacuum"
5. Enter vacuum IP address and token

**Getting Token**:
```bash
# Use the Xiaomi Cloud Tokens Extractor
# or extract from Mi Home app logs
```

**Features**:
- Start/stop/pause cleaning
- Return to dock
- Zone and room cleaning
- Map visualization
- Consumable status (brush, filter, etc.)
- Cleaning history

**Requirements**:
- Dreame robot vacuum with WiFi
- Vacuum on same subnet as Home Assistant
- Device token from Mi Home app

---

### 16. Hubspace Devices (Porch Light)

**Repository**: `jdeath/Hubspace-Homeassistant`
**Installation**: Via HACS

**Setup**:
1. Install via HACS:
   - HACS > Integrations > Explore & Download Repositories
   - Search for "Hubspace"
   - Install
2. Restart Home Assistant
3. Settings > Devices & Services > Add Integration
4. Search for "Hubspace"
5. Enter Hubspace account credentials

**Features**:
- Light control (on/off, brightness)
- Color temperature (if supported)
- Device status monitoring

**Requirements**:
- Hubspace account
- Hubspace devices set up in Hubspace app
- Internet connection (cloud-dependent)

**Note**: Hubspace is cloud-first, requires internet connectivity

---

### 17. Traeger Ironwood Grill

**Repository**: `nocturnal11/homeassistant-traeger`
**Installation**: Manual or via HACS

**Manual Installation**:
```bash
# SSH into Home Assistant
cd /config/custom_components
git clone https://github.com/nocturnal11/homeassistant-traeger.git traeger
# Restart Home Assistant
```

**Setup**:
1. After installation, restart Home Assistant
2. Settings > Devices & Services > Add Integration
3. Search for "Traeger"
4. Enter Traeger WiFIRE account credentials

**Features**:
- Grill temperature monitoring
- Probe temperature monitoring
- Target temperature control
- Cook timer
- Grill on/off status
- Notifications for temperature reached

**Requirements**:
- Traeger account
- Traeger WiFIRE-enabled grill
- Grill connected to WiFi

---

## Secrets Management

Many integrations require credentials. Add these to your SOPS secrets.yaml:

```yaml
# Example secrets structure (encrypt with sops)
# Network
asus-router-password: "your_password"

# Energy
enphase-username: "your_enlighten_email"
enphase-password: "your_enlighten_password"
tesla-username: "your_tesla_email"
tesla-password: "your_tesla_password"

# Water
flume-username: "your_flume_email"
flume-password: "your_flume_password"

# Climate
nest-client-id: "your_google_cloud_client_id"
nest-client-secret: "your_google_cloud_secret"

# Security
ring-username: "your_ring_email"
ring-password: "your_ring_password"
myq-username: "your_myq_email"
myq-password: "your_myq_password"

# Appliances
miele-username: "your_miele_email"
miele-password: "your_miele_password"
lg-thinq-token: "your_lg_thinq_personal_access_token"

# Custom integrations
bhyve-username: "your_orbit_email"
bhyve-password: "your_orbit_password"
dreame-token: "your_vacuum_token"
hubspace-username: "your_hubspace_email"
hubspace-password: "your_hubspace_password"
traeger-username: "your_traeger_email"
traeger-password: "your_traeger_password"
```

To encrypt and edit secrets:
```bash
sops /etc/nixos/secrets.yaml
```

---

## Post-Installation

After adding integrations:

1. **Rebuild NixOS** (for built-in components):
   ```bash
   sudo nixos-rebuild switch --flake '.#vulcan'
   ```

2. **Configure each integration** via Home Assistant UI

3. **Set up dashboards** to display device data

4. **Create automations** for device interactions

5. **Monitor logs** for any errors:
   ```bash
   sudo journalctl -u home-assistant -f
   ```

---

## Energy Dashboard Setup

Many of these devices integrate with Home Assistant's Energy Dashboard:

1. Go to Settings > Dashboards > Energy
2. Configure:
   - **Solar Production**: Enphase Envoy
   - **Grid Consumption**: Enphase Envoy (if monitoring grid)
   - **EV Charging**: Tesla Wall Connector
   - **Water**: Flume (custom energy sensor)

---

## Troubleshooting

### Integration Not Discovered
- Ensure device is on same network
- Check firewall rules
- Verify device is powered on and connected

### Authentication Failures
- Verify credentials in secrets.yaml
- Check 2FA settings on accounts
- Some services may require app-specific passwords

### Custom Integration Not Loading
- Verify HACS installation
- Check custom_components directory
- Review Home Assistant logs for errors
- Ensure dependencies are met

### Cloud-Dependent Issues
- Ring, MyQ, Nest, Tesla, Flume, Hubspace, Traeger require internet
- Check cloud service status
- Verify account subscriptions are active

---

## Additional Resources

- [Home Assistant Integrations](https://www.home-assistant.io/integrations/)
- [HACS Documentation](https://hacs.xyz/)
- [Energy Dashboard Guide](https://www.home-assistant.io/docs/energy/)
- [Automation Basics](https://www.home-assistant.io/docs/automation/basics/)
