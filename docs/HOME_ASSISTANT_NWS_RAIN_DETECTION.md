# Home Assistant NWS Rain Detection

## Overview

This guide explains how to set up rain detection sensors using the National Weather Service (NWS) integration in Home Assistant. These sensors extract precipitation and weather condition data from your NWS weather entity (`weather.kmhr`) to enable rain-based automations.

## Background

This implementation is based on [Jeffrey Stone's 2020 blog post](https://web.archive.org/web/20200804025652/https://jeffreystone.net/2020/04/07/migrating-from-the-darksky-api-to-nws-weather-api/) about migrating from DarkSky to NWS after Apple's acquisition of DarkSky.

**Key Update:** This guide has been modernized for Home Assistant 2025, which uses the `weather.get_forecasts` service instead of direct forecast attribute access.

## What You Get

### Sensors Created

**Current Conditions:**
- `sensor.nws_current_condition` - Weather state (rainy, cloudy, sunny, etc.)
- `sensor.nws_current_temperature` - Current temperature
- `sensor.nws_current_humidity` - Current humidity percentage
- `sensor.nws_current_wind_speed` - Current wind speed
- `sensor.nws_current_visibility` - Current visibility distance

**Current Forecast:**
- `sensor.nws_current_forecast` - Detailed forecast for next period
- `sensor.nws_current_rain_chance` - Precipitation probability for next period
- `sensor.nws_daytime_temperature` - Next daytime temperature
- `sensor.nws_overnight_low` - Next overnight low temperature

**Tomorrow's Forecast:**
- `sensor.nws_forecast_tomorrow` - Tomorrow's detailed forecast
- `sensor.nws_rain_chance_tomorrow` - Tomorrow's precipitation probability
- `sensor.nws_forecast_tomorrow_night` - Tomorrow night's forecast
- `sensor.nws_rain_chance_tomorrow_night` - Tomorrow night's rain chance

**Binary Sensors (for easier automation):**
- `binary_sensor.rain_detected` - Is it currently raining?
- `binary_sensor.rain_expected_soon` - High chance of rain in next period (>50%)
- `binary_sensor.rain_expected_tomorrow` - High chance of rain tomorrow (>50%)
- `binary_sensor.rain_in_forecast` - Any rain in next 2 periods (>30%)

## Prerequisites

### NWS Integration Already Configured

You already have NWS configured in your Home Assistant:
- ✅ Integration enabled in `/etc/nixos/modules/services/home-assistant.nix` (line 327)
- ✅ Weather entity: `weather.kmhr` (Mather Airport/Sacramento)

To verify:
1. Access Home Assistant: **https://hass.vulcan.lan**
2. Go to **Developer Tools → States**
3. Search for `weather.kmhr`
4. Should see weather entity with current conditions

## Installation

### Step 1: Copy Template Sensor File

```bash
# Copy sensor configuration to Home Assistant directory
sudo cp /etc/nixos/config/home-assistant/nws-rain-sensors.yaml /var/lib/hass/
sudo chown hass:hass /var/lib/hass/nws-rain-sensors.yaml
```

### Step 2: Add to configuration.yaml

**Option A: Include in Existing Template Section**

If you already have a `template:` section in `/var/lib/hass/configuration.yaml`:

```bash
sudo -u hass nano /var/lib/hass/configuration.yaml
```

Find the existing `template:` section and add:
```yaml
template: !include nws-rain-sensors.yaml
```

**Option B: Add New Template Section**

If no `template:` section exists:

```bash
sudo -u hass nano /var/lib/hass/configuration.yaml
```

Add anywhere in the file:
```yaml
# NWS Rain Detection Sensors
template: !include nws-rain-sensors.yaml
```

**Option C: Merge with Existing Template File**

If you already have template sensors in a separate file (e.g., from B-Hyve setup):

```bash
# View existing template file
sudo cat /var/lib/hass/bhyve-rain-delay-sensors.yaml

# Manually merge the two files, or keep them separate with multiple includes:
# template: !include_dir_merge_list templates/
```

### Step 3: Verify Configuration

```bash
# Check Home Assistant configuration for errors
# Via UI: Developer Tools → YAML → Check Configuration
# Or via command line (if hass CLI is available):
# sudo -u hass hass --script check_config -c /var/lib/hass
```

### Step 4: Reload Template Entities

**Option A: Via UI (No Restart Required)**
1. Go to **Developer Tools → YAML**
2. Click **Template Entities** section
3. Click **Reload Template Entities**

**Option B: Restart Home Assistant**
```bash
sudo systemctl restart home-assistant
```

### Step 5: Verify Sensors Created

1. Go to **Developer Tools → States**
2. Search for `nws_`
3. Should see all new sensors with current values
4. Check binary sensors: Search for `rain_`

## Usage Examples

### Simple Notification When It Rains

```yaml
automation:
  - alias: "Rain Alert"
    trigger:
      - platform: state
        entity_id: binary_sensor.rain_detected
        to: "on"
    action:
      - service: notify.notify
        data:
          message: "It's raining!"
```

### Morning Rain Forecast

```yaml
automation:
  - alias: "Morning Weather Report"
    trigger:
      - platform: time
        at: "07:00:00"
    action:
      - service: notify.notify
        data:
          message: >
            Good morning! Today's forecast: {{ states('sensor.nws_current_forecast') }}
            Rain chance: {{ states('sensor.nws_current_rain_chance') }}%
```

### Close Windows When Rain Detected

```yaml
automation:
  - alias: "Close Windows When Raining"
    trigger:
      - platform: state
        entity_id: binary_sensor.rain_detected
        to: "on"
    action:
      - service: cover.close_cover
        target:
          entity_id: cover.bedroom_window
```

### Cancel Outdoor Activity If Rain Expected

```yaml
automation:
  - alias: "Cancel BBQ If Rain Expected"
    trigger:
      - platform: time
        at: "14:00:00"  # 2 PM check for evening BBQ
    condition:
      - condition: state
        entity_id: binary_sensor.rain_expected_soon
        state: "on"
    action:
      - service: notify.notify
        data:
          message: "Rain expected this evening. Consider rescheduling outdoor plans."
```

## Complete Automation Examples

Full automation examples are available:
```bash
cat /etc/nixos/config/home-assistant/nws-rain-automations.yaml
```

These include:
1. Notification when rain starts
2. Morning notification if rain expected
3. Close outdoor covers when raining
4. Turn off outdoor devices in rain
5. Evening reminder to bring in items
6. Thermostat adjustment during rain
7. Disable/enable outdoor automations based on forecast
8. Voice announcements when leaving in rain
9. Dashboard notifications
10. Rain event logging
11. Lighting adjustments for dark rainy days
12. Window sensor integration alerts

### Adding Automations

**Via UI (Recommended):**
1. Go to **Settings → Automations & Scenes → Create Automation**
2. Click **⋮ → Edit in YAML**
3. Copy desired automation from `/etc/nixos/config/home-assistant/nws-rain-automations.yaml`
4. Paste and customize entity IDs
5. Save

**Via YAML File:**
```bash
sudo -u hass nano /var/lib/hass/automations.yaml
# Copy desired automations from nws-rain-automations.yaml
# Reload automations: Developer Tools → YAML → Automations → Reload
```

## Dashboard Cards

### Weather Summary Card

```yaml
type: entities
title: Weather
entities:
  - entity: weather.kmhr
  - entity: sensor.nws_current_temperature
    name: Current Temperature
  - entity: sensor.nws_current_rain_chance
    name: Rain Chance
  - entity: binary_sensor.rain_detected
    name: Currently Raining
  - entity: binary_sensor.rain_expected_soon
    name: Rain Expected Soon
```

### Rain Forecast Card

```yaml
type: vertical-stack
cards:
  - type: markdown
    content: |
      ## Rain Forecast
      **Current:** {{ states('sensor.nws_current_rain_chance') }}%
      **Tomorrow:** {{ states('sensor.nws_rain_chance_tomorrow') }}%
      **Tomorrow Night:** {{ states('sensor.nws_rain_chance_tomorrow_night') }}%
  - type: entities
    entities:
      - binary_sensor.rain_in_forecast
```

### Conditional Rain Alert Card

```yaml
type: conditional
conditions:
  - entity: binary_sensor.rain_in_forecast
    state: "on"
card:
  type: markdown
  content: |
    ☔ **Rain Expected!**
    {{ states('sensor.nws_current_forecast') }}
```

## Integration with Other Systems

### Sprinkler System (B-Hyve)

Combine with B-Hyve rain delay automation:

```yaml
automation:
  - alias: "B-Hyve Rain Delay - NWS Based"
    trigger:
      - platform: time
        at: "20:00:00"
    condition:
      # Use NWS rain sensors instead of weather.get_forecasts
      - condition: numeric_state
        entity_id: sensor.nws_rain_chance_tomorrow
        above: 50
    action:
      - service: bhyve.enable_rain_delay
        target:
          entity_id: switch.front_yard_timer_rain_delay
        data:
          hours: 72
```

### Smart Lighting

Adjust indoor lighting when it gets dark due to rain:

```yaml
automation:
  - alias: "Brighten Lights When Rainy"
    trigger:
      - platform: state
        entity_id: binary_sensor.rain_detected
        to: "on"
    condition:
      - condition: sun
        after: sunrise
        before: sunset
    action:
      - service: light.turn_on
        target:
          area_id: living_room
        data:
          brightness_pct: 80
```

### Climate Control

Adjust thermostat based on rain (cooler, more humid):

```yaml
automation:
  - alias: "Adjust AC for Rain"
    trigger:
      - platform: state
        entity_id: binary_sensor.rain_detected
        to: "on"
    action:
      - service: climate.set_temperature
        target:
          entity_id: climate.nest_thermostat
        data:
          temperature: >
            {{ state_attr('climate.nest_thermostat', 'temperature') | float - 1 }}
```

## Customization

### Adjust Rain Probability Thresholds

**In Binary Sensors:**

Edit `/var/lib/hass/nws-rain-sensors.yaml`:

```yaml
# Change from 50% to 60% for "Rain Expected Soon"
- name: "Rain Expected Soon"
  state: >
    {{ states('sensor.nws_current_rain_chance') | float(0) > 60 }}  # Changed from 50
```

**In Automations:**

```yaml
condition:
  - condition: numeric_state
    entity_id: sensor.nws_current_rain_chance
    above: 60  # More conservative (was 50)
```

### Add Custom Rain Categories

Add severity-based binary sensors:

```yaml
# Light rain expected (30-50%)
- name: "Light Rain Expected"
  state: >
    {% set chance = states('sensor.nws_current_rain_chance') | float(0) %}
    {{ chance >= 30 and chance < 50 }}

# Heavy rain expected (70%+)
- name: "Heavy Rain Expected"
  state: >
    {{ states('sensor.nws_current_rain_chance') | float(0) >= 70 }}
```

### Change Update Frequency

Default is every hour. To update more frequently:

```yaml
# In nws-rain-sensors.yaml
- trigger:
    - platform: time_pattern
      minutes: "/30"  # Every 30 minutes (was hours: "/1")
```

Note: NWS data doesn't update more than hourly, so more frequent checks won't provide newer data.

## Monitoring and Debugging

### View Sensor Values

**Developer Tools → States:**
```
sensor.nws_current_rain_chance
sensor.nws_rain_chance_tomorrow
binary_sensor.rain_detected
binary_sensor.rain_in_forecast
```

### Test Template Sensors

**Developer Tools → Template:**

Test individual templates:
```jinja
{{ states('sensor.nws_current_rain_chance') }}
{{ state_attr('weather.kmhr', 'temperature') }}
{{ states('weather.kmhr') }}
```

### View Raw Weather Data

**Developer Tools → States → weather.kmhr:**

Click on entity to see all attributes:
- `temperature`
- `humidity`
- `wind_speed`
- `visibility`
- `forecast` (may be empty, use weather.get_forecasts instead)

### Check Template Sensor Logs

```bash
# View Home Assistant logs
sudo journalctl -u home-assistant -f

# Filter for template errors
sudo journalctl -u home-assistant | grep -i "template"

# Filter for NWS integration
sudo journalctl -u home-assistant | grep -i "nws"
```

### Verify weather.get_forecasts Works

**Developer Tools → Services:**

Service: `weather.get_forecasts`
Target: `weather.kmhr`
Service Data:
```yaml
type: twice_daily
```

Click **Call Service** and check the response for forecast data.

## Troubleshooting

### Sensors Showing "Unknown" or "Unavailable"

**Cause:** Template sensors haven't updated yet, or weather.kmhr is unavailable.

**Fix:**
1. Check `weather.kmhr` status: Developer Tools → States
2. Verify NWS integration is working: Settings → Integrations → NWS
3. Manually trigger template sensor update:
   ```bash
   # Reload template entities
   # Developer Tools → YAML → Template Entities → Reload
   ```
4. Wait up to 1 hour for first automatic update

### Rain Chance Showing 0 When It Should Be Higher

**Cause:** Template is looking at wrong forecast period, or using `twice_daily` mode.

**Debug:**
1. Check raw forecast data: Developer Tools → Services → weather.get_forecasts
2. Verify forecast[0] is the period you expect
3. NWS uses `twice_daily` by default (day/night periods, not hourly)

**Fix:** Adjust forecast array index in template if needed.

### Binary Sensors Not Updating

**Cause:** Dependency sensors haven't updated.

**Fix:**
1. Check `sensor.nws_current_rain_chance` has a valid value
2. Reload template entities
3. Restart Home Assistant if needed

### "is_daytime" Attribute Error

**Cause:** Using old 2020 template syntax. Modern NWS uses `is_daytime` (not `daytime`).

**Fix:** Templates in this guide already use correct `is_daytime` attribute.

### Weather Entity Not Found

**Cause:** Your NWS station entity ID is different.

**Fix:**
1. Find your actual entity: Developer Tools → States → Search "weather"
2. Replace `weather.kmhr` in `nws-rain-sensors.yaml` with your entity
3. Example: If yours is `weather.ksac_daynight`, replace all instances

### Template Syntax Errors

**Symptoms:** Sensors show "unavailable", logs show template errors.

**Fix:**
1. Check logs: `sudo journalctl -u home-assistant | grep -i template`
2. Test template in Developer Tools → Template
3. Verify YAML indentation is correct
4. Check for missing `{% endif %}` or similar

## Advanced Configuration

### Multiple Weather Stations

Track weather from multiple NWS stations:

```yaml
# Copy nws-rain-sensors.yaml
sudo cp /var/lib/hass/nws-rain-sensors.yaml /var/lib/hass/nws-rain-sensors-airport.yaml

# Edit and replace weather.kmhr with weather.ksac (or other station)
sudo -u hass nano /var/lib/hass/nws-rain-sensors-airport.yaml

# Add second include to configuration.yaml
template:
  - !include nws-rain-sensors.yaml
  - !include nws-rain-sensors-airport.yaml
```

### Historical Rain Tracking

Use the `history_stats` integration to track rain duration:

```yaml
sensor:
  - platform: history_stats
    name: "Rain Duration Today"
    entity_id: binary_sensor.rain_detected
    state: "on"
    type: time
    start: "{{ now().replace(hour=0, minute=0, second=0) }}"
    end: "{{ now() }}"
```

### Rain Prediction Accuracy Tracking

Compare forecasted rain probability with actual rain:

```yaml
automation:
  - alias: "Track Rain Forecast Accuracy"
    trigger:
      - platform: time
        at: "23:59:00"
    action:
      - service: logbook.log
        data:
          name: "Rain Forecast Accuracy"
          message: >
            Forecasted: {{ states('sensor.nws_current_rain_chance') }}%
            Actual: {{ 'Rain occurred' if is_state('binary_sensor.rain_detected', 'on') else 'No rain' }}
```

### Voice Announcements

Use Google Home or Alexa for rain alerts:

```yaml
automation:
  - alias: "Morning Weather Announcement"
    trigger:
      - platform: time
        at: "07:00:00"
    action:
      - service: tts.google_say
        target:
          entity_id: media_player.google_home
        data:
          message: >
            Good morning. Today's forecast: {{ states('sensor.nws_current_forecast') }}.
            {% if states('sensor.nws_current_rain_chance') | float > 50 %}
            There is a {{ states('sensor.nws_current_rain_chance') }} percent chance of rain today. Don't forget your umbrella!
            {% endif %}
```

## Comparison: 2020 vs 2025 Implementation

### 2020 Method (Old)

```yaml
# Direct attribute access (deprecated)
sensor:
  - platform: template
    sensors:
      nws_current_rain:
        value_template: "{{ states.weather.klzu.attributes.forecast[0].precipitation_probability }}"
```

### 2025 Method (Current)

```yaml
# Trigger-based with weather.get_forecasts service
template:
  - trigger:
      - platform: time_pattern
        hours: "/1"
    action:
      - service: weather.get_forecasts
        data:
          type: twice_daily
        target:
          entity_id: weather.kmhr
        response_variable: forecast_data
    sensor:
      - name: "NWS Current Rain Chance"
        state: >
          {% if forecast_data['weather.kmhr'].forecast | length > 0 %}
            {{ forecast_data['weather.kmhr'].forecast[0].precipitation_probability }}
          {% else %}
            0
          {% endif %}
```

**Key Differences:**
- 2025 uses trigger-based templates with service calls
- Forecast data no longer directly available as attributes
- More robust with error handling
- Requires response_variable pattern

## Best Practices

1. **Check Sensors Regularly:** Verify rain sensors are updating hourly
2. **Test Before Relying:** Test automations manually before going on vacation
3. **Backup Configuration:** Keep copies of sensor/automation YAML files
4. **Monitor Forecast Accuracy:** Track how well NWS forecasts match actual weather
5. **Adjust Thresholds:** Tune rain probability thresholds based on your local climate
6. **Use Binary Sensors:** Easier to work with in automations than numeric sensors
7. **Combine Data Sources:** Consider using multiple weather integrations for redundancy

## Related Documentation

- Main configuration: `/etc/nixos/modules/services/home-assistant.nix`
- Rain sensor templates: `/etc/nixos/config/home-assistant/nws-rain-sensors.yaml`
- Rain automations: `/etc/nixos/config/home-assistant/nws-rain-automations.yaml`
- B-Hyve rain delay: `/etc/nixos/docs/HOME_ASSISTANT_BHYVE_RAIN_DELAY.md`
- Home Assistant devices: `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md`

## External Resources

- **Original 2020 Blog Post:** https://jeffreystone.net/2020/04/07/migrating-from-the-darksky-api-to-nws-weather-api/ (Archive: https://web.archive.org/web/20200804025652/...)
- **NWS Integration Docs:** https://www.home-assistant.io/integrations/nws/
- **Weather Integration Docs:** https://www.home-assistant.io/integrations/weather
- **Template Docs:** https://www.home-assistant.io/docs/configuration/templating/
- **NWS API:** https://www.weather.gov/documentation/services-web-api

## FAQs

**Q: Why not use observed precipitation instead of forecast?**
A: NWS integration doesn't provide historical observed precipitation data. Forecast-based detection is standard and works well for automations.

**Q: Can I use hourly forecasts instead of twice-daily?**
A: Yes! Change `type: twice_daily` to `type: hourly` in the template trigger. Adjust array indexes accordingly (hourly has more forecast periods).

**Q: Will this work with other weather integrations?**
A: The concept works with any weather integration, but entity IDs and attribute names may differ. Check your integration's documentation.

**Q: How accurate are NWS forecasts?**
A: 24-hour forecasts are typically 80-90% accurate. Accuracy decreases for longer forecast periods.

**Q: Can I detect rain intensity (light vs heavy)?**
A: NWS provides probability, not intensity. Check the `condition` attribute for values like "rainy" vs "pouring".

**Q: Why use binary sensors instead of just numeric sensors?**
A: Binary sensors are easier to use in automation conditions and more semantic ("is it raining?" vs "is rain_chance > 50?").

**Q: Can I integrate with weather radar?**
A: NWS doesn't provide radar in this integration. Consider the `raincloud` or `radar` custom components for radar data.

**Q: Does this work outside the US?**
A: NWS only covers the United States. For other countries, use local weather integrations (Met.no for Europe, etc.).
