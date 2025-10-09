# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a NixOS configuration for the host "vulcan" - an x86_64 Linux system running on Apple T2 hardware. This configuration uses Nix flakes with nixos-hardware and nixos-logwatch modules.

## Commands

### System Management
```bash
# Build and switch to new configuration
sudo nixos-rebuild switch --flake .#vulcan

# Just build without switching
sudo nixos-rebuild build --flake .#vulcan

# Test configuration in a VM
sudo nixos-rebuild build-vm --flake .#vulcan

# Update flake inputs
nix flake update

# Format Nix files (using nixfmt-rfc-style)
nix fmt
```

### Maintenance Commands
```bash
# Check Nix store integrity
nix-store --verify --check-contents

# Garbage collect old generations
sudo nix-collect-garbage -d

# Delete generations older than 30 days
sudo nix-collect-garbage --delete-older-than 30d

# Optimize Nix store
nix-store --optimise
```

### Certificate Authority Management
```bash
# Check step-ca service status
sudo systemctl status step-ca
sudo journalctl -u step-ca -f  # Follow logs

# Generate a new certificate
step ca certificate "service.vulcan.local" service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt

# Renew a certificate
step ca renew service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt

# List issued certificates
step ca certificate list \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca/certs/root_ca.crt

# Export root CA certificate for client installation
sudo cp /var/lib/step-ca/certs/root_ca.crt ~/vulcan-ca.crt
```

### Dovecot Full-Text Search (FTS) Management
```bash
# Index all mailboxes for a user (initial setup)
doveadm index -u johnw '*'
doveadm index -u assembly '*'

# Index a specific mailbox
doveadm index -u johnw INBOX

# Optimize FTS indexes (reduce index size, improve performance)
doveadm fts optimize -u johnw
doveadm fts optimize -u assembly

# Rescan mailbox and rebuild FTS index (if index is corrupted)
doveadm fts rescan -u johnw
doveadm index -u johnw '*'

# Check Dovecot FTS configuration
doveconf plugin | grep fts

# Monitor FTS indexing activity in logs
sudo journalctl -u dovecot2 -f | grep -i fts

# Search from command line (test FTS functionality)
doveadm search -u johnw body "search term"

# Get mailbox statistics including FTS index size
doveadm mailbox status -u johnw all '*'
```

### Samba File Sharing Management
```bash
# Check Samba service status
sudo systemctl status smbd nmbd samba-wsdd
sudo journalctl -u smbd -f  # Follow Samba logs

# Manage Samba users
sudo smbpasswd -a johnw     # Add user to Samba
sudo smbpasswd -e johnw     # Enable Samba user
sudo smbpasswd -d johnw     # Disable Samba user
sudo pdbedit -L             # List all Samba users
sudo pdbedit -Lv johnw      # Detailed info for user

# Test Samba configuration
sudo testparm               # Validate smb.conf
sudo testparm -s            # Show full configuration

# List shares and test connections
smbclient -L //vulcan.lan -U johnw               # List all shares
smbclient //vulcan.lan/johnw-documents -U johnw  # Connect to share
smbclient -N -L //vulcan.lan                     # Anonymous list (should fail)

# Check active Samba connections
sudo smbstatus              # Show all connections
sudo smbstatus -b           # Brief output
sudo smbstatus -S           # Show shares only
sudo smbstatus -p           # Show processes only

# Monitor Samba activity
sudo journalctl -u smbd -u nmbd -f
sudo tail -f /var/log/samba/log.*

# Set proper ZFS permissions for shares
sudo chown -R johnw:johnw /tank/Documents /tank/Downloads /tank/Home
sudo chown -R :users /tank/Media /tank/Music /tank/Photos /tank/Pictures /tank/Video
sudo chmod -R 0775 /tank/Media /tank/Music /tank/Photos /tank/Pictures /tank/Video
```

### Connecting to Samba Shares

**From Windows:**
```cmd
# Map network drive
net use Z: \\vulcan.lan\johnw-documents /user:johnw

# Or use File Explorer: \\vulcan.lan\share-name
```

**From macOS:**
```bash
# Finder: Cmd+K, then enter: smb://vulcan.lan/johnw-documents

# Command line mount
mkdir -p ~/mnt/documents
mount_smbfs //johnw@vulcan.lan/johnw-documents ~/mnt/documents
```

**From Linux:**
```bash
# Install cifs-utils first
sudo apt install cifs-utils  # Debian/Ubuntu
sudo dnf install cifs-utils  # Fedora

# Mount share
sudo mkdir -p /mnt/samba/documents
sudo mount -t cifs //vulcan.lan/johnw-documents /mnt/samba/documents -o username=johnw

# Add to /etc/fstab for persistent mount
//vulcan.lan/johnw-documents /mnt/samba/documents cifs credentials=/home/user/.smbcredentials,uid=1000,gid=1000 0 0
```

### Home Assistant IoT Management
```bash
# Check Home Assistant service status
sudo systemctl status home-assistant
sudo journalctl -u home-assistant -f  # Follow logs

# Restart Home Assistant
sudo systemctl restart home-assistant

# View Home Assistant configuration
cat /var/lib/hass/configuration.yaml

# Check Home Assistant database
sudo -u hass psql -d hass -c "SELECT COUNT(*) FROM states;"

# Backup Home Assistant manually
sudo restic-home-assistant backup

# Check recent backups
sudo restic-home-assistant snapshots | head -10

# Restore Home Assistant from backup (if needed)
# First, stop the service
sudo systemctl stop home-assistant
# Restore from latest snapshot
sudo restic-home-assistant restore latest --target /tmp/hass-restore
# Copy files back
sudo rsync -av /tmp/hass-restore/var/lib/hass/ /var/lib/hass/
# Fix permissions
sudo chown -R hass:hass /var/lib/hass
# Restart service
sudo systemctl start home-assistant
```

### Home Assistant Web Access
```bash
# Local access (HTTPS via nginx reverse proxy)
# URL: https://hass.vulcan.lan

# The service runs on localhost:8123 but is accessed via nginx on port 443
# Nginx handles SSL/TLS termination with step-ca certificates

# Test direct access (for debugging)
curl http://localhost:8123/api/

# Check nginx configuration for Home Assistant
sudo nginx -t
sudo systemctl reload nginx
```

### Home Assistant Initial Setup
```bash
# 1. After first NixOS rebuild, access Home Assistant at https://hass.vulcan.lan
# 2. Complete the onboarding wizard (create admin account)
# 3. Add Yale Home integration:
#    - Go to Settings > Devices & Services
#    - Click "Add Integration"
#    - Search for "Yale Home" or "August"
#    - Authenticate with your Yale/August account credentials
# 4. Your 3 August 4th gen WiFi locks should be automatically discovered
# 5. Configure lock entities and add to dashboards

# Yale/August credentials are stored in SOPS secrets:
# - home-assistant/yale-username
# - home-assistant/yale-password

# To update credentials, edit secrets.yaml with SOPS:
# sops /etc/nixos/secrets.yaml
# Then rebuild and restart Home Assistant
```

### Home Assistant Troubleshooting
```bash
# Check if Home Assistant is responding
curl -f http://localhost:8123/api/ || echo "Home Assistant not responding"

# View detailed logs with debug level
sudo journalctl -u home-assistant --since "1 hour ago"

# Check PostgreSQL connection
sudo -u hass psql -d hass -c "\dt"

# Verify Yale integration status
sudo journalctl -u home-assistant | grep -i yale

# Check nginx proxy status
sudo systemctl status nginx
sudo nginx -t

# Verify step-ca certificate
openssl s_client -connect hass.vulcan.lan:443 -servername hass.vulcan.lan < /dev/null 2>&1 | grep -A 5 "Certificate chain"

# Check Home Assistant configuration validity
# (requires hass CLI installed in Home Assistant environment)
# sudo -u hass hass --script check_config -c /var/lib/hass
```

### OPNsense Firewall Integration
```bash
# IMPORTANT: The built-in Home Assistant OPNsense integration has issues with
# newer OPNsense versions (25.7+) that changed API endpoints from camelCase to snake_case.
# Use the HACS custom component "travisghansen/hass-opnsense" instead.

# Install HACS (if not already installed):
# 1. Access Home Assistant terminal or SSH
# 2. Download HACS:
wget -O - https://get.hacs.xyz | bash -
# 3. Restart Home Assistant:
sudo systemctl restart home-assistant
# 4. Add HACS integration via UI:
#    Settings > Devices & Services > Add Integration > HACS
#    Authenticate with GitHub

# Install OPNsense Custom Component via HACS:
# 1. In Home Assistant, go to HACS
# 2. Click "+ Explore & Download Repositories"
# 3. Search for "OPNsense"
# 4. Select "OPNsense integration for Home Assistant" by travisghansen
# 5. Click "Download"
# 6. Restart Home Assistant
# 7. Go to Settings > Devices & Services > Add Integration
# 8. Search for "OPNsense" and add it via the UI
# 9. Enter your OPNsense URL, API key, and API secret

# OPNsense API credentials (stored in /var/lib/hass/secrets.yaml):
# opnsense_url: "https://your-opnsense-ip"
# opnsense_api_key: "your_api_key"
# opnsense_api_secret: "your_api_secret"

# Generate OPNsense API credentials:
# 1. Log into OPNsense web interface
# 2. Go to System > Access > Users
# 3. Edit your user
# 4. Scroll to "API keys" section
# 5. Click "+" to create new API key
# 6. Important: Assign "All Pages" privilege to the API user for full functionality
# 7. Save the API key and secret (shown only once)

# Test OPNsense API connectivity:
curl -k -u "API_KEY:API_SECRET" https://192.168.1.1/api/diagnostics/interface/get_arp

# Verify OPNsense integration status in Home Assistant:
sudo journalctl -u home-assistant | grep -i opnsense

# View OPNsense entities in Home Assistant:
# Access: https://hass.vulcan.lan
# Go to Settings > Devices & Services > OPNsense
```

### Google Nest Integration
```bash
# The Google Nest integration uses the Smart Device Management (SDM) API
# which requires a one-time $5 fee to Google for API access.

# Prerequisites:
# 1. Google Account with Nest devices
# 2. $5 USD payment to Google for Device Access
# 3. Google Cloud Project with OAuth credentials

# Step 1: Create Device Access Project
# Visit: https://console.nest.google.com/device-access/
# - Pay the $5 one-time fee
# - Create a new project
# - Note your Project ID

# Step 2: Create Google Cloud OAuth Credentials
# Visit: https://console.cloud.google.com/
# 1. Create a new project (or use existing)
# 2. Enable the Smart Device Management API
# 3. Configure OAuth Consent Screen:
#    - User Type: External
#    - App name: Home Assistant
#    - User support email: your email
#    - Developer contact: your email
#    - IMPORTANT: Publish the app (set to "In Production")
#      Do NOT leave in "Testing" mode or tokens expire after 7 days
# 4. Create OAuth 2.0 Client ID:
#    - Application type: Web application
#    - Name: Home Assistant
#    - Authorized redirect URIs: https://my.home-assistant.io/redirect/oauth
#    - Note your Client ID and Client Secret

# Step 3: Configure in Home Assistant
# 1. Access Home Assistant: https://hass.vulcan.lan
# 2. Go to Settings > Devices & Services
# 3. Click "+ Add Integration"
# 4. Search for "Nest"
# 5. Enter your OAuth Client ID and Client Secret
# 6. Enter your Project ID from Device Access Console
# 7. Follow the OAuth flow to authorize Home Assistant
# 8. Select which devices to allow access to

# Managing Nest Devices:
# - Add/remove devices: https://nestservices.google.com/partnerconnections
# - After changing devices, reload the Nest integration in Home Assistant
# - Settings > Devices & Services > Nest > ⋮ > Reload

# Troubleshooting:
# Check Home Assistant logs for Nest errors:
sudo journalctl -u home-assistant | grep -i nest

# Verify grpcio package is installed:
sudo journalctl -u home-assistant --since "5 minutes ago" | grep grpc

# Common issues:
# - "Token expired after 7 days": OAuth consent screen is in Testing mode, publish to Production
# - "No module named 'grpc'": grpcio package missing (already configured in this setup)
# - "Invalid credentials": Check Client ID and Secret are correct
# - "Project ID invalid": Verify Project ID from Device Access Console

# Supported Devices:
# - Nest Thermostats (all generations)
# - Nest Temperature Sensors
# - Nest Cameras (some models)
# - Nest Doorbells (some models)
# Note: Smoke/CO alarms and security systems are NOT supported by SDM API

# Integration provides:
# - Temperature control
# - HVAC mode (heat, cool, heat-cool, off)
# - Fan control
# - Eco mode
# - Temperature sensor data
# - Camera streams (if supported)
# - Doorbell events (if supported)
```

### BMW ConnectedDrive Integration
```bash
# The BMW ConnectedDrive integration is a built-in integration that connects
# your BMW vehicles to Home Assistant for remote monitoring and control.

# Prerequisites:
# 1. BMW vehicle with ConnectedDrive services active
# 2. BMW ConnectedDrive account with registered vehicle
# 3. Account credentials (username and password)

# Configuration:
# The integration is configured via the Home Assistant UI after adding credentials to SOPS.

# Step 1: Add Credentials to SOPS
# Edit the encrypted secrets file:
sops /etc/nixos/secrets.yaml

# Add these entries under the home-assistant section:
# home-assistant:
#   bmw-username: "your_bmw_email@example.com"
#   bmw-password: "your_bmw_password"

# Step 2: Rebuild NixOS configuration
sudo nixos-rebuild switch --flake .#vulcan

# Step 3: Add Integration in Home Assistant
# 1. Access Home Assistant: https://hass.vulcan.lan
# 2. Go to Settings > Devices & Services
# 3. Click "+ Add Integration"
# 4. Search for "BMW Connected Drive"
# 5. Follow the authentication flow
# 6. Your BMW vehicle(s) should be automatically discovered

# Note: BMW requires periodic re-authentication which may include captcha solving
# This is a security measure enforced by BMW's backend

# Available Features:
# - Vehicle location tracking
# - Lock/unlock doors remotely
# - Climate control (pre-conditioning)
# - Charging status (for electric/hybrid vehicles)
# - Battery level and range
# - Fuel level and range (for combustion engines)
# - Service status and vehicle health
# - Remote horn and lights
# - Send destinations to navigation

# Troubleshooting:
# Check Home Assistant logs for BMW errors:
sudo journalctl -u home-assistant | grep -i bmw

# Common issues:
# - "Authentication failed": Check username and password in secrets.yaml
# - "Captcha required": Complete captcha in the Home Assistant UI flow
# - "Region not supported": BMW ConnectedDrive availability varies by region
# - "Token expired": Re-authenticate via Settings > Devices & Services > BMW

# Verify integration status:
# Access: https://hass.vulcan.lan
# Go to Settings > Devices & Services > BMW Connected Drive
```

### IoT Device Integrations

Home Assistant is configured with support for 19 different IoT device types (plus OPNsense via HACS). See `/etc/nixos/docs/HOME_ASSISTANT_DEVICES.md` for complete setup instructions.

```bash
# View the device integration guide
cat /etc/nixos/docs/HOME_ASSISTANT_DEVICES.md

# Or view specific sections
cat /etc/nixos/docs/HOME_ASSISTANT_DEVICES.md | grep -A 20 "ASUS WiFi"
```

**Built-in Integrations** (configured via NixOS):
- ASUS WiFi routers (asuswrt)
- Enphase Solar Inverter (enphase_envoy)
- Tesla Wall Connector (tesla)
- Flume water meter (flume)
- Google Nest thermostats (nest)
- Ring doorbell & chimes (ring)
- MyQ garage door opener (myq)
- Pentair IntelliCenter & IntelliFlo (screenlogic)
- Miele dishwasher (miele)
- LG ThinQ smart appliances (lg_thinq)
- Google Home Hub (cast)
- Withings digital scale (withings)
- BMW ConnectedDrive (bmw_connected_drive)
- LG webOS Smart TV (webostv)

**Custom Integrations** (require HACS):
- OPNsense firewall (travisghansen/hass-opnsense)
- B-Hyve sprinkler control (sebr/bhyve-home-assistant)
- Dreame robot vacuum (Tasshack/dreame-vacuum)
- Hubspace porch light (jdeath/Hubspace-Homeassistant)
- Traeger Ironwood grill (nocturnal11/homeassistant-traeger)

**Installing HACS** (Home Assistant Community Store):
```bash
# Access Home Assistant terminal or SSH
# Install HACS
wget -O - https://get.hacs.xyz | bash -

# Then restart Home Assistant
sudo systemctl restart home-assistant

# After restart, add HACS integration via UI:
# Settings > Devices & Services > Add Integration > HACS
# Authenticate with GitHub
```

**Adding Device Credentials to SOPS**:
```bash
# Edit encrypted secrets file
sops /etc/nixos/secrets.yaml

# Add credentials for each device (see HOME_ASSISTANT_DEVICES.md for full list)
# Example entries:
# home-assistant:
#   asus-router-password: "router_password"
#   opnsense-url: "https://192.168.1.1"
#   opnsense-api-key: "your_api_key"
#   opnsense-api-secret: "your_api_secret"
#   enphase-username: "enlighten_email"
#   ring-username: "ring_email"
# etc.

# After saving, rebuild NixOS
sudo nixos-rebuild switch --flake '.#vulcan'
```

**Energy Dashboard Setup**:
```bash
# The following devices integrate with the Energy Dashboard:
# - Enphase Envoy (solar production)
# - Tesla Wall Connector (EV charging)
# - Flume (water consumption - custom sensor)

# Configure via Home Assistant UI:
# Settings > Dashboards > Energy
```

### Extended OpenAI Conversation Integration
```bash
# Extended OpenAI Conversation provides LLM-powered conversation and automation
# with support for OpenAI API and local models (Ollama, LocalAI, etc.)
# See /etc/nixos/docs/EXTENDED_OPENAI_CONVERSATION.md for complete guide

# Quick Start:
# 1. Install via HACS: Settings > HACS > Integrations > Search "Extended OpenAI Conversation"
# 2. Add API key to secrets (if using OpenAI):
sops /etc/nixos/secrets.yaml
# Add: home-assistant/openai-api-key: "sk-your-key-here"

# 3. Rebuild NixOS to apply secret:
sudo nixos-rebuild switch --flake .#vulcan

# 4. Configure integration: Settings > Devices & Services > Add Integration > Extended OpenAI Conversation

# For local Ollama server:
# - Base URL: http://localhost:11434/v1
# - API Key: ollama (can be any value)
# - Model: llama3.2 (or your installed model)

# Check available Ollama models:
ollama list

# Pull a new model:
ollama pull llama3.2

# Test OpenAI integration:
sudo journalctl -u home-assistant | grep -i "extended_openai"

# View detailed documentation:
cat /etc/nixos/docs/EXTENDED_OPENAI_CONVERSATION.md
```

### Managing August Locks
```bash
# August locks are managed entirely through the Home Assistant web UI
# Access: https://hass.vulcan.lan

# Common operations:
# - Lock/Unlock: Use the lock entity controls in the UI
# - Check battery: View battery sensor for each lock
# - Activity log: Check lock history in the UI
# - Automations: Create automations for lock events

# The locks communicate with the August cloud service
# They require internet connectivity to function
# No local Bluetooth connection is used with 4th gen WiFi models
```

### LG webOS Smart TV Integration
```bash
# The LG webOS Smart TV integration provides local control of LG Smart TVs
# running webOS 2.0 or later (2015+ models).

# Prerequisites:
# 1. LG Smart TV with webOS 2.0+ on your network
# 2. TV powered on for initial pairing
# 3. Network discovery (SSDP) enabled

# Setup:
# 1. Ensure TV is powered on and connected to network
# 2. Access Home Assistant: https://hass.vulcan.lan
# 3. Go to Settings > Devices & Services
# 4. TV should auto-discover (look for "LG webOS Smart TV")
# 5. If not discovered, manually add:
#    - Click "+ Add Integration"
#    - Search for "LG webOS Smart TV"
#    - Enter TV IP address (find in TV Settings > Network)
# 6. Accept pairing request on TV screen
# 7. TV entity will appear as media_player.lg_webos_smart_tv

# Wake on LAN Setup (optional):
# To power on TV remotely:
# 1. Connect TV via Ethernet (WiFi WoL is unreliable)
# 2. On TV: Settings > General > Mobile TV On > Turn On Via WiFi/Ethernet
# 3. Enable "LG Connect Apps"
# 4. TV must support WoL (most 2015+ models do)

# Features:
# - Power on/off control (with WoL)
# - Volume control and mute
# - Media playback (play/pause/stop)
# - Input source switching (HDMI1, HDMI2, etc.)
# - Channel control
# - App launching (Netflix, YouTube, etc.)
# - Display notifications on TV screen
# - Screenshot capability
# - Media information display

# Check webOS integration status:
sudo journalctl -u home-assistant | grep -i webos

# View TV entities in Home Assistant:
# Access: https://hass.vulcan.lan
# Go to Settings > Devices & Services > LG webOS Smart TV

# Example automations:
# Launch Netflix on TV
# service: webostv.button
# target:
#   entity_id: media_player.lg_webos_smart_tv
# data:
#   button: NETFLIX

# Display notification on TV
# service: notify.lg_webos_tv
# data:
#   message: "Dinner is ready!"

# Turn on TV at 7 AM
# automation:
#   trigger:
#     platform: time
#     at: "07:00:00"
#   action:
#     service: media_player.turn_on
#     target:
#       entity_id: media_player.lg_webos_smart_tv

# Troubleshooting:
# TV not discovered:
# - Check TV and Home Assistant are on same network/VLAN
# - Ensure multicast/SSDP is not blocked by firewall
# - Verify TV is powered on (not in standby)

# Pairing fails:
# - TV must be on and not in screen saver mode
# - Try manually adding with TV IP address
# - Check TV firewall settings (if any)

# Wake-on-LAN not working:
# - Use Ethernet connection instead of WiFi
# - Enable "LG Connect Apps" in TV settings
# - Verify TV supports WoL (check TV manual)

# Commands not responding:
# - Verify TV is powered on
# - Check network connectivity
# - Re-pair integration via UI

# Supported TV Models:
# - LG Smart TVs with webOS 2.0+ (2015 and newer)
# - webOS 3.0, 4.0, 5.0, 6.0, 22, 23 verified compatible
# - Most LG OLED and NanoCell series
```

### LG ThinQ Smart Appliances Integration
```bash
# LG ThinQ supports a wide range of LG smart appliances using the official
# LG ThinQ Connect API (requires Personal Access Token).

# Prerequisites:
# 1. LG ThinQ account with registered devices
# 2. Personal Access Token (PAT) from https://connect-pat.lgthinq.com/
# 3. Token added to SOPS secrets as lg-thinq-token

# Generate Personal Access Token (PAT):
# 1. Visit: https://connect-pat.lgthinq.com/
# 2. Login with your LG ThinQ account
# 3. Click "ADD NEW TOKEN"
# 4. Enter a token name (e.g., "Home Assistant")
# 5. Select ALL authorized scopes:
#    - Permission to view all devices
#    - Permission to view all device statuses
#    - All device control rights
#    - All device event subscription rights
#    - All device push notification permissions
#    - Permission to inquiry device energy consumption
# 6. Click "CREATE TOKEN" and copy the token value

# Add token to secrets:
sops /etc/nixos/secrets.yaml
# Add under home-assistant section:
# lg-thinq-token: "your_personal_access_token_here"

# Rebuild NixOS after adding token:
sudo nixos-rebuild switch --flake '.#vulcan'

# Add Integration in Home Assistant:
# 1. Access: https://hass.vulcan.lan
# 2. Go to Settings > Devices & Services > Add Integration
# 3. Search for "LG ThinQ"
# 4. Enter your PAT token value
# 5. Select your region/country
# 6. Choose devices to integrate

# Check LG ThinQ integration status:
sudo journalctl -u home-assistant | grep -i "lg_thinq"

# View LG ThinQ entities:
# Access: https://hass.vulcan.lan
# Go to Settings > Devices & Services > LG ThinQ

# Supported Device Categories:
# - Laundry: Washers, dryers, stylers, washtowers
# - Kitchen: Refrigerators, dishwashers, ovens, microwaves
# - Climate: Air conditioners, air purifiers, dehumidifiers
# - Cleaning: Robot vacuums, stick vacuums
# - Other: Water heaters, wine cellars, system boilers

# Energy consumption tracking:
# LG ThinQ provides energy sensors for supported devices:
# - Energy yesterday (Wh)
# - Energy this month (Wh)
# - Energy last month (Wh)
# These integrate with Home Assistant's Energy Dashboard

# Common Troubleshooting:
# "Token not valid" error:
# - Verify token at https://connect-pat.lgthinq.com/
# - Check that all required scopes were selected during token creation
# - Generate a new token if expired or corrupted

# "Country not supported" error:
# - Check which countries are authorized in your PAT
# - Select the correct region when adding the integration

# "API calls exceeded" error:
# - LG limits API rate per token
# - Wait some time before retrying
# - Avoid reloading integration repeatedly

# Device not appearing:
# - Ensure device is registered in LG ThinQ mobile app first
# - Check that device is online and connected to WiFi
# - Reload the integration via UI: Settings > Devices & Services > LG ThinQ > Reload

# Automation examples:
# Create automations for device events like:
# - Washer/dryer cycle completion notifications
# - Refrigerator door left open alerts
# - Dishwasher cycle complete announcements
# - Air purifier filter replacement reminders
# See HOME_ASSISTANT_DEVICES.md for YAML automation examples
```

## Architecture

### Core Structure
- **flake.nix**: Main flake defining the NixOS configuration for vulcan host
- **configuration.nix**: Primary system configuration including:
  - Boot configuration (systemd-boot, LUKS encryption)
  - Network setup (NetworkManager, Tailscale, Nebula)
  - Service configurations (PostgreSQL, Restic backups, Docker)
  - User and package management
- **hardware-configuration.nix**: Hardware-specific configuration (generated by nixos-generate-config)

### Key Services Configured
1. **Restic Backups**: Automated backup system with multiple filesets to Backblaze B2
2. **PostgreSQL**: Database server with custom configuration
3. **Docker**: Container runtime with rootless support
4. **Tailscale & Nebula**: VPN networking
5. **Logwatch**: System log monitoring and reporting
6. **Step-CA**: Private certificate authority for TLS and SSH certificates
7. **Dovecot**: IMAP mail server with full-text search (FTS) via Xapian backend
8. **Samba**: SMB/CIFS file sharing for ZFS tank datasets with SMB3.1.1 encryption
9. **Home Assistant**: IoT home automation platform with 17 integrated device types including August locks, BMW vehicles, Enphase solar, Tesla charger, Ring doorbell, Nest thermostats, pool controls, and more

### Important Configuration Details
- **State Version**: 25.05 (DO NOT change unless migrating)
- **Boot**: Uses systemd-boot with LUKS encryption on root partition
- **Networking**: Static hostname "vulcan", uses NetworkManager
- **Time Zone**: America/Los_Angeles
- **Users**: Primary user "johnw" with sudo access via wheel group

### Custom Functions
- **restic-operations**: Shell script for managing Restic backup operations (check, prune, repair, snapshots)
- Supports operations on multiple backup filesets defined in services.restic.backups

## Development Notes

- System runs on Apple T2 hardware (uses nixos-hardware.nixosModules.apple-t2)
- PostgreSQL configured with custom settings for production use
- Restic backups configured with multiple filesets backing up to rsync.net
- Extensive package list including development tools, system utilities, and user applications
- Uses unstable nixpkgs channel for latest packages