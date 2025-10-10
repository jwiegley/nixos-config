# Home Assistant B-Hyve Rain Delay Automation

## Overview

This guide explains how to automatically enable rain delay on your Orbit B-Hyve sprinkler system based on weather forecasts. The automation prevents unnecessary watering when rain is expected, conserving water and reducing costs.

## Important Note: Observed vs. Forecasted Precipitation

**Your original request:** Enable rain delay "after any day that sees a certain amount of precipitation"

**Implementation challenge:** Home Assistant weather integrations (Met.no, NWS, AccuWeather) do not readily provide historical observed precipitation data for the past 24 hours.

**Recommended solution:** Use **forecast-based proactive rain delay** instead, which is actually better for irrigation because:
- Prevents wasteful watering **before** rain arrives
- Standard approach for smart irrigation systems
- More water-efficient than reactive delays
- Supported by all major weather integrations

## How It Works

1. **Daily Check:** Automation runs at 8 PM (before typical sprinkler schedules)
2. **Forecast Analysis:** Checks tomorrow's precipitation probability and/or amount
3. **Threshold Decision:** If rain exceeds your threshold (e.g., 50% probability or 0.25" expected)
4. **Enable Delay:** Calls `bhyve.enable_rain_delay` service with 72 hours (3 days)
5. **Normal Resume:** Sprinklers resume normal schedule after delay expires

## Prerequisites

### 1. B-Hyve Integration (HACS Custom Component)

The B-Hyve integration is **not** built into Home Assistant. You must install it via HACS:

#### Install HACS (if not already installed)
```bash
# Access Home Assistant terminal or SSH to vulcan
wget -O - https://get.hacs.xyz | bash -

# Restart Home Assistant
sudo systemctl restart home-assistant
```

After restart:
1. Access Home Assistant: **https://hass.vulcan.lan**
2. Go to **Settings → Devices & Services → Add Integration**
3. Search for **HACS**
4. Authenticate with GitHub
5. Complete HACS setup

#### Install B-Hyve Integration via HACS
1. In Home Assistant, go to **HACS**
2. Click **Integrations**
3. Click **⋮** menu → **Custom repositories**
4. Add repository URL: `https://github.com/sebr/bhyve-home-assistant`
5. Category: **Integration**
6. Click **Add**
7. Find **"Orbit B-Hyve"** in integrations list
8. Click **Download**
9. Restart Home Assistant: `sudo systemctl restart home-assistant`

#### Configure B-Hyve Integration
1. Go to **Settings → Devices & Services → Add Integration**
2. Search for **"Orbit B-Hyve"**
3. Enter your Orbit B-Hyve account credentials (email/password)
4. Your sprinkler timers and zones will be discovered

### 2. Weather Integration

You already have these configured:
- ✅ **AccuWeather** (`weather.YOUR_LOCATION`)
- ✅ **National Weather Service** (`weather.YOUR_NWS_STATION`)

You'll need to identify your weather entity IDs (see "Finding Entity IDs" section below).

## Finding Entity IDs

### Find Your B-Hyve Timer Entity

1. Access Home Assistant: **https://hass.vulcan.lan**
2. Go to **Settings → Devices & Services → Orbit B-Hyve**
3. Click on your sprinkler timer device
4. Look for the **rain delay switch** entity, e.g.:
   - `switch.front_yard_timer_rain_delay`
   - `switch.back_yard_timer_rain_delay`
5. Copy the entity ID - you'll need it for the automation

### Find Your Weather Entity

1. Go to **Settings → Integrations**
2. Find **AccuWeather** or **National Weather Service**
3. Click to view entities
4. Look for the main weather entity, e.g.:
   - AccuWeather: `weather.home` or `weather.sacramento`
   - NWS: `weather.ksac_daynight` or `weather.kmcc_daynight`
5. Copy the entity ID

## Installation

### Step 1: Create Template Sensors (Optional but Recommended)

Template sensors extract precipitation data from weather forecasts for easier use in automations.

**Option A: Add to configuration.yaml**

1. SSH into vulcan or use console
2. Edit Home Assistant configuration:
   ```bash
   sudo -u hass nano /var/lib/hass/configuration.yaml
   ```

3. Add this line to include template sensors:
   ```yaml
   template: !include bhyve-rain-delay-sensors.yaml
   ```

4. Copy the sensor template file:
   ```bash
   sudo cp /etc/nixos/config/home-assistant/bhyve-rain-delay-sensors.yaml /var/lib/hass/
   sudo chown hass:hass /var/lib/hass/bhyve-rain-delay-sensors.yaml
   ```

5. Edit the file and replace `YOUR_NWS_STATION` and `YOUR_LOCATION` with your actual weather entity IDs:
   ```bash
   sudo -u hass nano /var/lib/hass/bhyve-rain-delay-sensors.yaml
   ```

6. Reload templates:
   - Go to **Developer Tools → YAML → Template Entities → Reload Template Entities**
   - Or restart Home Assistant

**Option B: Skip Templates (Simpler)**

If you prefer not to create template sensors, you can use the weather.get_forecasts service directly in automations (see Approach 7 below).

### Step 2: Add Automation

Choose **ONE** of the following approaches based on your needs:

#### Approach 1: Simple Probability-Based (Recommended)

Best for: Most users who want a simple, reliable solution

```yaml
# Enables 3-day rain delay when precipitation probability > 50%
```

1. Go to **Settings → Automations & Scenes → Create Automation → Create new automation**
2. Click **⋮** menu → **Edit in YAML**
3. Copy the "APPROACH 1" automation from:
   ```bash
   cat /etc/nixos/config/home-assistant/bhyve-rain-delay-automation.yaml
   ```
4. **IMPORTANT:** Replace these placeholders:
   - `sensor.accuweather_tomorrow_precipitation_probability` → Your sensor
   - `switch.front_yard_timer_rain_delay` → Your B-Hyve entity
5. Save with name: "B-Hyve Rain Delay - High Precipitation Probability"

#### Approach 2: Amount-Based

Best for: Users who want precision based on expected rainfall amount

```yaml
# Enables delay only if > 0.25 inches of rain expected
```

More precise than probability alone. Prevents delay for light drizzle.

#### Approach 3: Combined (Probability AND Amount)

Best for: Conservative approach requiring both high probability and significant amount

```yaml
# Requires BOTH >50% probability AND >0.20 inches
```

Most conservative - reduces false positives.

#### Approach 4: Smart Delay Extension

Best for: Advanced users who want to avoid unnecessary delay resets

```yaml
# Only enables new delay if current delay < 24 hours remaining
```

Prevents resetting a freshly-enabled 3-day delay the next evening.

#### Approach 5: 3-Day Forecast

Best for: Users who want to consider multiple days of forecasted rain

```yaml
# Enables delay if > 0.5 inches expected over next 3 days
```

Accounts for cumulative rainfall over multiple days.

#### Approach 6: Multiple Zones

Best for: Systems with multiple B-Hyve timers/zones

```yaml
# Enables rain delay on all zones simultaneously
```

Add or remove zones as needed in the entity_id list.

#### Approach 7: Without Template Sensors (Alternative)

If you skipped Step 1 and don't want template sensors:

```yaml
automation:
  - id: bhyve_rain_delay_no_template
    alias: "B-Hyve Rain Delay - Direct Forecast"
    description: "Enable rain delay using direct weather forecast call"

    trigger:
      - platform: time
        at: "20:00:00"

    action:
      # Get weather forecast
      - service: weather.get_forecasts
        data:
          type: daily
        target:
          entity_id: weather.YOUR_LOCATION  # Change this
        response_variable: forecast

      # Check if rain is forecasted
      - if:
          - condition: template
            value_template: >
              {% set tomorrow = forecast['weather.YOUR_LOCATION'].forecast[1] %}
              {{ tomorrow.precipitation_probability | float(0) > 50 }}
        then:
          - service: bhyve.enable_rain_delay
            target:
              entity_id: switch.front_yard_timer_rain_delay  # Change this
            data:
              hours: 72

          - service: notify.notify
            data:
              title: "Sprinkler Rain Delay Enabled"
              message: "Rain delay enabled for 3 days due to forecasted rain."

    mode: single
```

## Customization

### Change Rain Delay Duration

Default is 3 days (72 hours). To change:

```yaml
data:
  hours: 48  # 2 days
  hours: 96  # 4 days
  hours: 120  # 5 days
```

### Adjust Precipitation Threshold

**Probability threshold:**
```yaml
above: 50  # Default: 50% chance
above: 60  # Conservative: 60% chance
above: 40  # Aggressive: 40% chance
```

**Amount threshold:**
```yaml
above: 0.25  # Default: 0.25 inches
above: 0.50  # Conservative: 0.50 inches
above: 0.10  # Aggressive: 0.10 inches (light rain)
```

**3-day total threshold:**
```yaml
above: 0.50  # Default: 0.5 inches over 3 days
above: 0.75  # Conservative: 0.75 inches
above: 0.30  # Aggressive: 0.30 inches
```

### Change Trigger Time

Default is 8 PM (before typical sprinkler schedules):

```yaml
trigger:
  - platform: time
    at: "20:00:00"  # 8 PM

# Examples:
at: "18:00:00"  # 6 PM
at: "21:00:00"  # 9 PM
at: "07:00:00"  # 7 AM
```

### Add Multiple Daily Checks

Check forecast twice daily:

```yaml
trigger:
  - platform: time
    at: "08:00:00"  # Morning check
  - platform: time
    at: "20:00:00"  # Evening check
```

### Seasonal Adjustments

Only run during irrigation season (April-October):

```yaml
condition:
  - condition: and
    conditions:
      - condition: numeric_state
        entity_id: sensor.accuweather_tomorrow_precipitation_probability
        above: 50
      - condition: template
        value_template: >
          {{ now().month >= 4 and now().month <= 10 }}
```

## Testing

### Test Before Relying On It

**Method 1: Manual Trigger**
1. Go to **Settings → Automations & Scenes**
2. Find your B-Hyve rain delay automation
3. Click **Run** (▶️ icon)
4. Automation executes immediately (ignores time trigger)
5. Check B-Hyve app or Home Assistant to verify rain delay is active

**Method 2: Change Trigger Time**
1. Temporarily change trigger time to 1 minute from now
2. Wait for automation to run
3. Verify rain delay enabled
4. Change trigger time back to `20:00:00`

**Method 3: Developer Tools**
1. Go to **Developer Tools → Services**
2. Service: `automation.trigger`
3. Target: Select your rain delay automation
4. Click **Call Service**
5. Check if rain delay was enabled

**Method 4: Test Service Call Directly**
1. Go to **Developer Tools → Services**
2. Service: `bhyve.enable_rain_delay`
3. Target: Your B-Hyve timer entity
4. Service data:
   ```yaml
   hours: 1
   ```
5. Click **Call Service**
6. Verify 1-hour rain delay appears in B-Hyve app

### Verify Weather Sensors

**Check template sensor values:**
1. Go to **Developer Tools → States**
2. Search for your precipitation sensors:
   - `sensor.accuweather_tomorrow_precipitation_probability`
   - `sensor.nws_tomorrow_precip_prob`
3. Verify they show reasonable values (not 0, unknown, or unavailable)

**Test template in Template Editor:**
1. Go to **Developer Tools → Template**
2. Test this template:
   ```jinja
   {{ states('sensor.accuweather_tomorrow_precipitation_probability') }}
   ```
3. Should show a number (e.g., 30, 60, 80)

## Monitoring

### View Automation History

1. Go to **Settings → Automations & Scenes**
2. Click on your rain delay automation
3. Click **Traces** tab
4. See when automation ran and what actions were taken

### Check B-Hyve Rain Delay Status

**Via Home Assistant:**
1. Go to **Overview** dashboard
2. Find your B-Hyve timer
3. Check rain delay switch status (on/off)
4. View attributes for hours remaining

**Via B-Hyve Mobile App:**
1. Open Orbit B-Hyve app
2. Select your timer
3. Check for rain delay indicator
4. View delay expiration date/time

### View Logs

```bash
# Home Assistant logs
sudo journalctl -u home-assistant -f

# Filter for B-Hyve events
sudo journalctl -u home-assistant | grep -i bhyve

# Filter for automation triggers
sudo journalctl -u home-assistant | grep -i "rain delay"
```

### Check Weather Forecast

```bash
# View current forecast data
# In Home Assistant: Developer Tools → States → weather.YOUR_LOCATION
```

## Troubleshooting

### Automation Not Running

**Check automation is enabled:**
1. Settings → Automations & Scenes
2. Find your automation
3. Verify toggle is ON (blue)

**Check time trigger:**
- Ensure trigger time hasn't passed for today
- Wait until next trigger time or test manually

**Check conditions:**
- Verify precipitation sensor has valid data
- Check threshold values are appropriate

**View automation trace:**
- Click automation → **Traces** tab
- See why it didn't run (condition failed, etc.)

### Rain Delay Not Enabling

**Verify B-Hyve integration is working:**
```bash
sudo journalctl -u home-assistant | grep -i bhyve
```

**Test service call manually:**
1. Developer Tools → Services
2. Service: `bhyve.enable_rain_delay`
3. Target: Your timer entity
4. Data: `hours: 1`
5. Call service
6. Check if 1-hour delay appears

**Check B-Hyve cloud connection:**
- Verify B-Hyve mobile app works
- Check internet connectivity
- Restart Home Assistant if needed

### Precipitation Sensors Showing 0 or Unknown

**NWS sensors:**
- Verify NWS station is correct for your area
- Check NWS website for service status
- Some stations may not provide precipitation forecasts

**AccuWeather sensors:**
- Verify AccuWeather API key is valid
- Check AccuWeather integration status
- Free tier has request limits

**Template sensors:**
- Check template syntax in configuration.yaml
- Reload template entities
- View Developer Tools → Template to debug

### Wrong Entity IDs

**Symptoms:**
- Automation fails with "entity not found"
- Services don't execute

**Fix:**
1. Go to Developer Tools → States
2. Search for "bhyve" to find correct B-Hyve entities
3. Search for "weather" to find correct weather entities
4. Update automation with correct entity IDs
5. Save and test again

### Rain Delay Enabled Too Often

**Adjust thresholds:**
- Increase probability threshold (50% → 60% or 70%)
- Increase amount threshold (0.25" → 0.50")
- Use combined approach (probability AND amount)

**Use smart delay extension:**
- Implement Approach 4 to avoid resetting active delays

### Rain Delay Not Enabling Often Enough

**Adjust thresholds:**
- Decrease probability threshold (50% → 40%)
- Decrease amount threshold (0.25" → 0.10")
- Use 3-day forecast approach instead of next-day

**Check forecast data:**
- Verify weather integration is updating
- Compare forecast to actual weather conditions
- Consider switching weather providers

## Advanced Features

### Weather-Based Cancel

Automatically cancel rain delay if forecast improves (see Approach 7 in automation file).

### Integration with Smart Home Routines

**Example: Good Morning Routine**
```yaml
# Check sprinkler status in morning routine
action:
  - if:
      - condition: state
        entity_id: switch.front_yard_timer_rain_delay
        state: "on"
    then:
      - service: tts.google_say
        data:
          message: "Sprinkler rain delay is active. Watering paused for {{ state_attr('switch.front_yard_timer_rain_delay', 'hours') }} more hours."
```

### Notifications

Add rich notifications with actionable buttons:

```yaml
- service: notify.mobile_app_iphone
  data:
    title: "Sprinkler Rain Delay"
    message: "Rain delay enabled for 3 days"
    data:
      actions:
        - action: "CANCEL_DELAY"
          title: "Cancel Delay"
        - action: "VIEW_FORECAST"
          title: "View Forecast"
```

### Dashboard Card

Add B-Hyve controls to dashboard:

```yaml
type: entities
title: Sprinkler System
entities:
  - entity: switch.front_yard_timer_rain_delay
    name: Rain Delay
  - type: attribute
    entity: switch.front_yard_timer_rain_delay
    attribute: hours
    name: Hours Remaining
  - entity: sensor.accuweather_tomorrow_precipitation_probability
    name: Tomorrow's Rain Chance
  - entity: sensor.accuweather_tomorrow_precipitation_amount
    name: Expected Rainfall
```

## Best Practices

1. **Start Conservative:** Use 50% probability threshold initially, adjust based on results
2. **Monitor First Month:** Track automation performance before trusting completely
3. **Multiple Checks:** Consider checking forecast twice daily (morning and evening)
4. **Seasonal Adjustment:** Disable or adjust thresholds during rainy season
5. **Backup Plan:** Keep manual control via B-Hyve app for overrides
6. **Test Regularly:** Manually test automation before each irrigation season
7. **Smart Extension:** Use Approach 4 to avoid resetting fresh delays

## Water Conservation Tips

- **Soil Moisture Sensors:** Consider adding to skip watering when soil is already wet
- **Rain Sensors:** Physical rain sensors provide immediate detection
- **Historical Data:** Track water savings with utility bill monitoring
- **Multiple Zones:** Apply different thresholds to different zones based on plant needs
- **Seasonal Schedules:** Reduce watering frequency during naturally wet seasons

## Related Documentation

- Main configuration: `/etc/nixos/modules/services/home-assistant.nix`
- Sensor templates: `/etc/nixos/config/home-assistant/bhyve-rain-delay-sensors.yaml`
- Automation YAML: `/etc/nixos/config/home-assistant/bhyve-rain-delay-automation.yaml`
- Home Assistant devices: `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md`
- Vacation mode automation: `/etc/nixos/docs/HOME_ASSISTANT_VACATION_MODE.md`

## Support Resources

**B-Hyve Integration:**
- GitHub: https://github.com/sebr/bhyve-home-assistant
- Issues: https://github.com/sebr/bhyve-home-assistant/issues

**Home Assistant:**
- Community: https://community.home-assistant.io/
- Weather Integrations: https://www.home-assistant.io/integrations/#weather
- Automation Docs: https://www.home-assistant.io/docs/automation/

**Orbit B-Hyve:**
- Support: https://bhyve.orbitonline.com/support
- Mobile App: iOS App Store / Google Play Store

## NixOS Configuration

B-Hyve is a HACS custom component, so no NixOS configuration changes are needed. However, if you want to document its presence:

```nix
# /etc/nixos/modules/services/home-assistant.nix
# Note: B-Hyve is installed via HACS, not NixOS
# See /etc/nixos/docs/HOME_ASSISTANT_BHYVE_RAIN_DELAY.md
```

## FAQs

**Q: Can I use observed precipitation instead of forecast?**
A: Not easily. Home Assistant weather integrations don't readily provide historical precipitation data. Forecast-based is more practical and actually more water-efficient.

**Q: What if it rains less than forecasted?**
A: The delay will still expire after 3 days and watering resumes. Consider implementing the "weather-based cancel" feature to remove delay early if forecast improves.

**Q: Will this work with non-B-Hyve systems?**
A: The concept is the same, but service calls will differ. Check your irrigation system's integration documentation for equivalent rain delay services.

**Q: Can I have different thresholds for different zones?**
A: Yes! Create separate automations for each zone with different thresholds based on plant water needs.

**Q: Does this work with Rachio or RainMachine?**
A: No, this guide is specific to B-Hyve. Those systems have their own integrations with similar rain delay capabilities.

**Q: How accurate are weather forecasts?**
A: 24-hour forecasts are generally 80-90% accurate. 3-day forecasts are less accurate (70-80%). Monitor performance and adjust thresholds accordingly.

**Q: Can I override the automation manually?**
A: Yes! Use the B-Hyve mobile app or Home Assistant to manually enable/disable rain delay at any time.
