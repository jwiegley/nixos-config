# Home Assistant Vacation Mode Setup

## Overview

This guide explains how to set up "Vacation Mode" automations in Home Assistant that simulate your presence while traveling. Lights will turn on and off at random times only when everyone is away from home.

## What It Does

- **Triggers:** Every day at 5 PM
- **Random Start:** Lights turn on between 5 PM and 8 PM (random 0-3 hour delay)
- **Random Duration:** Lights stay on for 1-2 hours (random 60-120 minutes)
- **Condition:** Only runs when `binary_sensor.everyone_away` is `on`
- **Safety:** Automatically turns off lights if someone arrives home unexpectedly

## Prerequisites

1. Home Assistant running (configured in this NixOS system)
2. TP-Link Smart Home integration configured with at least one device
3. Know the entity ID of the light/switch you want to control

## Finding Your Device Entity ID

Before adding the automation, you need to find your device's entity ID:

1. Access Home Assistant: **https://hass.vulcan.lan**
2. Go to **Settings → Devices & Services → TP-Link Smart Home**
3. Click on your device
4. Look for the entity ID (e.g., `switch.living_room_lamp` or `light.porch_light`)
5. Copy this entity ID - you'll need it in step 3 below

## Installation Methods

### Method 1: Via Home Assistant UI (Recommended for Beginners)

1. Access Home Assistant: **https://hass.vulcan.lan**

2. Go to **Settings → Automations & Scenes**

3. Click **+ Create Automation** → **Create new automation**

4. Click the **⋮** menu (top right) → **Edit in YAML**

5. Delete the default content and paste the automation from:
   ```
   /etc/nixos/config/home-assistant/vacation-mode-automation.yaml
   ```

6. **IMPORTANT:** Replace `switch.living_room_lamp` with your actual device entity ID (found above)

7. Click **Save** and give it a name: "Vacation Mode - Random Evening Lights"

8. Repeat steps 3-7 for the second automation ("Vacation Mode - Disable on Arrival")

9. Test the automation (see Testing section below)

### Method 2: Direct YAML File Edit (Advanced)

1. SSH into vulcan or access the console

2. View your device entity ID:
   ```bash
   # Access Home Assistant
   # Then find your devices in Settings → Devices & Services
   ```

3. Edit the Home Assistant automations file:
   ```bash
   sudo -u hass nano /var/lib/hass/automations.yaml
   ```

4. Copy the contents from:
   ```bash
   cat /etc/nixos/config/home-assistant/vacation-mode-automation.yaml
   ```

5. Paste into `/var/lib/hass/automations.yaml`

6. **IMPORTANT:** Replace all instances of `switch.living_room_lamp` with your actual device entity ID

7. Save the file (Ctrl+O, Enter, Ctrl+X)

8. Reload automations in Home Assistant:
   - Go to **Developer Tools → YAML → Automations**
   - Click **Reload Automations**
   - Or restart Home Assistant:
     ```bash
     sudo systemctl restart home-assistant
     ```

## Customization Options

### Multiple Lights at Different Times

To make the simulation more realistic, create multiple automations with different:
- Trigger times (e.g., 5 PM, 7 PM, 9 PM)
- Delay ranges
- Duration ranges
- Different devices

Example: Uncomment and customize the third automation in the YAML file for a second light that comes on around 8 PM.

### Change Time Windows

Edit the `delay` values:

```yaml
# Random delay 0-3 hours = 0-10800 seconds
- delay: "{{ range(0, 10800) | random }}"

# To change to 0-2 hours (0-7200 seconds):
- delay: "{{ range(0, 7200) | random }}"

# To change to 1-4 hours (3600-14400 seconds):
- delay: "{{ range(3600, 14400) | random }}"
```

Duration examples:
```yaml
# 1-2 hours = 3600-7200 seconds (default)
- delay: "{{ range(3600, 7200) | random }}"

# 30 minutes - 1 hour = 1800-3600 seconds
- delay: "{{ range(1800, 3600) | random }}"

# 2-3 hours = 7200-10800 seconds
- delay: "{{ range(7200, 10800) | random }}"
```

### Change Trigger Time

Edit the `at:` value:
```yaml
trigger:
  - platform: time
    at: "17:00:00"  # 5 PM (24-hour format)

# Examples:
# at: "18:00:00"  # 6 PM
# at: "19:30:00"  # 7:30 PM
# at: "21:00:00"  # 9 PM
```

### Add Weekday Restrictions

To only run on weekdays (skip weekends):

```yaml
condition:
  - condition: state
    entity_id: binary_sensor.everyone_away
    state: "on"
  - condition: time
    weekday:
      - mon
      - tue
      - wed
      - thu
      - fri
```

## Optional: Vacation Mode Toggle

For easier control, create an input boolean helper:

1. Go to **Settings → Devices & Services → Helpers**
2. Click **+ Create Helper → Toggle**
3. Name: "Vacation Mode"
4. Icon: `mdi:airplane`
5. Click **Create**

Then modify each automation's conditions:

```yaml
condition:
  - condition: state
    entity_id: input_boolean.vacation_mode
    state: "on"
  - condition: state
    entity_id: binary_sensor.everyone_away
    state: "on"
```

Now you can easily enable/disable vacation mode from the UI or mobile app!

## Testing the Automation

### Test Before Traveling

**Method 1: Trigger Manually**
1. Go to **Settings → Automations & Scenes**
2. Find "Vacation Mode - Random Evening Lights"
3. Click **Run** (▶️ icon)
4. The automation will execute immediately (with the random delays)

**Method 2: Change Trigger Time**
1. Temporarily change the trigger time to 1 minute from now
2. Ensure `binary_sensor.everyone_away` is `on` (both people not home)
3. Wait for the trigger
4. Watch the automation execute
5. Change trigger time back to `17:00:00`

**Method 3: Developer Tools**
1. Go to **Developer Tools → Services**
2. Service: `automation.trigger`
3. Target: Select your vacation automation
4. Click **Call Service**

### Verify Safety Automation

1. While vacation lights are on, trigger the arrival automation:
   - Go to **Developer Tools → Services**
   - Service: `automation.trigger`
   - Target: "Vacation Mode - Disable on Arrival"
   - Click **Call Service**
2. Verify the lights turn off immediately

## Monitoring and Debugging

### View Automation History

1. Go to **Settings → Automations & Scenes**
2. Click on your vacation automation
3. Click **Traces** tab to see execution history

### View Automation Logs

```bash
# View Home Assistant logs
sudo journalctl -u home-assistant -f

# Filter for automation events
sudo journalctl -u home-assistant | grep -i vacation
```

### Check Everyone Away Status

```bash
# In Home Assistant UI:
# Go to Developer Tools → States
# Search for: binary_sensor.everyone_away
```

Or via command line:
```bash
# Check person states
curl -s -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:8123/api/states/person.john_wiegley | jq

curl -s -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:8123/api/states/person.nasim_wiegley | jq
```

## Disabling Vacation Mode

### Temporary Disable
1. Go to **Settings → Automations & Scenes**
2. Find "Vacation Mode - Random Evening Lights"
3. Toggle the switch to **OFF**

### Permanent Removal
1. Go to **Settings → Automations & Scenes**
2. Click on the automation
3. Click **⋮** menu → **Delete**

Or remove from `/var/lib/hass/automations.yaml` and reload automations.

## Advanced: Multiple Rooms

For a more realistic simulation, create separate automations for different rooms:

**Living Room:** 5-8 PM, 1-2 hours
**Kitchen:** 6-9 PM, 30-60 minutes
**Bedroom:** 9-11 PM, 30-90 minutes
**Outdoor:** Sunset-11 PM, random on/off cycles

Each automation should have:
- Different trigger times
- Different delay/duration ranges
- Different device entity IDs

## Troubleshooting

### Automation Not Running

**Check conditions:**
```bash
# Is everyone_away active?
# Go to Developer Tools → States → binary_sensor.everyone_away
# Should show "on" when both people are away
```

**Check automation is enabled:**
1. Settings → Automations & Scenes
2. Verify toggle is ON (blue)

**Check logs:**
```bash
sudo journalctl -u home-assistant | grep -i "vacation"
```

### Lights Not Turning On/Off

**Verify device entity ID:**
1. Developer Tools → States
2. Search for your device (e.g., `switch.living_room_lamp`)
3. Try manually controlling: Developer Tools → Services → `switch.turn_on`

**Check TP-Link integration:**
```bash
sudo journalctl -u home-assistant | grep -i tplink
```

### Random Delays Not Working

The template syntax `{{ range(0, 10800) | random }}` requires:
- Home Assistant 2021.1 or later (you're on latest)
- Proper YAML formatting (no extra quotes around templates)

Test the template:
1. Developer Tools → Template
2. Paste: `{{ range(0, 10800) | random }}`
3. Should output a random number

## Security Considerations

1. **Don't post schedules publicly:** Never share your vacation schedule on social media
2. **Test before leaving:** Ensure automations work correctly before traveling
3. **Backup plan:** Have a trusted neighbor who can check the house
4. **Multiple lights:** Use 2-3 different lights for more realistic simulation
5. **Randomization:** The random delays prevent obvious patterns
6. **Monitor remotely:** Check Home Assistant while away to verify operation

## Related Documentation

- Main configuration: `/etc/nixos/modules/services/home-assistant.nix`
- Automation YAML: `/etc/nixos/config/home-assistant/vacation-mode-automation.yaml`
- Home Assistant devices: `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md`
- Home Assistant backup: `/etc/nixos/docs/HOME_ASSISTANT_BACKUP_GUIDE.md`

## Support

For Home Assistant automation questions:
- Home Assistant Forums: https://community.home-assistant.io/
- Official Docs: https://www.home-assistant.io/docs/automation/
- Automation Editor: https://www.home-assistant.io/docs/automation/editor/

For NixOS configuration questions:
- See `/etc/nixos/CLAUDE.md`
