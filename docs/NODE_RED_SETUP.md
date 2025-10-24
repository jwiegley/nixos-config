# Node-RED Setup Guide

This guide covers the setup and configuration of Node-RED with Home Assistant integration on NixOS vulcan.

## Overview

Node-RED has been configured as a NixOS service with the following features:
- Service running on port 1880 with npm/gcc support for palette management
- Nginx reverse proxy at https://nodered.vulcan.lan
- SOPS-encrypted Home Assistant access token
- SSL certificate via Step-CA (automatic renewal)
- Integration with Home Assistant via WebSocket API

## Initial Setup

The following configuration has been completed:
- ✅ Created `/etc/nixos/modules/services/node-red.nix`
- ✅ Imported module in `/etc/nixos/hosts/vulcan/default.nix`
- ✅ Added `nodered.vulcan.lan` to nginx certificate renewal script
- ✅ Added `hass.vulcan.lan` to nginx certificate renewal script (was missing)

## Manual Steps Required

### 1. Generate Home Assistant Long-Lived Access Token

1. Open Home Assistant: https://hass.vulcan.lan
2. Navigate to: **Settings > Profile > Long-Lived Access Tokens**
3. Click **"Create Token"**
4. Name: `Node-RED Integration`
5. Copy the generated token (you won't be able to see it again)

### 2. Add SOPS Secret for Home Assistant Token

```bash
# Edit the encrypted secrets file
sops /etc/nixos/secrets.yaml

# Add the following under the home-assistant section:
home-assistant:
  node-red-token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpX..." # Paste your token here
  # ... other home-assistant secrets ...

# Save and exit (Ctrl+O, Enter, Ctrl+X)
```

### 3. Build and Deploy NixOS Configuration

```bash
# Build and switch to new configuration
sudo nixos-rebuild switch --flake '.#vulcan'

# Verify Node-RED service started
sudo systemctl status node-red

# Check logs if needed
sudo journalctl -u node-red -f
```

### 4. Generate SSL Certificate for Node-RED

```bash
# Generate certificate using Step-CA
cd /etc/nixos/certs
sudo ./create-web-certificate.sh nodered.vulcan.lan

# Verify certificate was created
ls -la /var/lib/nginx-certs/nodered.vulcan.lan.*

# Reload nginx to use new certificate
sudo systemctl reload nginx
```

### 5. Access Node-RED Web Interface

Open your browser and navigate to:
```
https://nodered.vulcan.lan
```

The Node-RED editor should now be accessible.

### 6. Install Home Assistant WebSocket Nodes

In the Node-RED interface:

1. Click the **hamburger menu** (☰) in the top-right
2. Select **"Manage palette"**
3. Go to the **"Install"** tab
4. Search for: `node-red-contrib-home-assistant-websocket`
5. Click **"Install"** next to the package
6. Confirm the installation

Wait for the installation to complete (this may take a few minutes).

### 7. Configure Home Assistant Connection

1. In Node-RED, drag a **"server: home assistant"** node from the palette
2. Double-click to configure
3. Click the pencil icon next to "Server" to add a new server
4. Configure:
   - **Name**: `Home Assistant`
   - **Base URL**: `https://hass.vulcan.lan`
   - **Access Token**:
     - Read from SOPS secret file:
       ```bash
       sudo cat /run/secrets/home-assistant/node-red-token
       ```
     - Or use an inject node to read from `process.env.HA_TOKEN_FILE`
5. Click **"Add"** then **"Done"**
6. Click **"Deploy"** to save

### 8. Test the Integration

Create a simple test flow:

1. Drag an **"inject"** node onto the canvas
2. Drag an **"events: state"** node (Home Assistant category)
3. Configure the events node:
   - **Server**: Select your Home Assistant server
   - **Entity ID**: Choose any entity (e.g., a light or sensor)
4. Drag a **"debug"** node
5. Connect: inject → events: state → debug
6. Click **"Deploy"**
7. Click the inject node's button
8. Check the debug panel - you should see Home Assistant entities

## Service Management

```bash
# Check service status
sudo systemctl status node-red

# View logs
sudo journalctl -u node-red -f

# Restart service
sudo systemctl restart node-red

# Stop service
sudo systemctl stop node-red

# Start service
sudo systemctl start node-red
```

## SSL Certificate Renewal

SSL certificates are automatically renewed monthly via systemd timer:

```bash
# Check next renewal time
sudo systemctl list-timers nginx-cert-renewal

# Manual renewal
sudo systemctl start nginx-cert-renewal

# Check renewal logs
sudo journalctl -u nginx-cert-renewal
```

## Accessing the Home Assistant Token

The Home Assistant token is stored in SOPS and deployed to:
```
/run/secrets/home-assistant/node-red-token
```

The Node-RED service has access via the `HA_TOKEN_FILE` environment variable.

To read the token in a Node-RED flow (if needed):
```javascript
// In a function node
const fs = require('fs');
const tokenPath = process.env.HA_TOKEN_FILE;
const token = fs.readFileSync(tokenPath, 'utf8').trim();
msg.payload = token;
return msg;
```

However, for most use cases, you should configure the Home Assistant WebSocket nodes directly in the UI using the token value.

## Firewall Configuration

Node-RED is accessible:
- **Direct HTTP**: http://vulcan.lan:1880 (local network only via end0)
- **HTTPS Proxy**: https://nodered.vulcan.lan (via nginx)

## Troubleshooting

### Service Won't Start

```bash
# Check for errors
sudo journalctl -u node-red -n 50

# Verify SOPS secret exists
ls -la /run/secrets/home-assistant/node-red-token

# Check file ownership
stat /run/secrets/home-assistant/node-red-token
# Should be: node-red:node-red with mode 0400
```

### Can't Access Web Interface

```bash
# Verify nginx is running
sudo systemctl status nginx

# Check nginx configuration
sudo nginx -t

# Verify certificate exists
ls -la /var/lib/nginx-certs/nodered.vulcan.lan.*

# Check firewall
sudo iptables -L -n | grep 1880
```

### Home Assistant Connection Issues

1. Verify token is valid in Home Assistant
2. Check Home Assistant is accessible from Node-RED:
   ```bash
   curl -H "Authorization: Bearer $(sudo cat /run/secrets/home-assistant/node-red-token)" \
     https://hass.vulcan.lan/api/ | jq
   ```
3. Check Step-CA root certificate is trusted:
   ```bash
   curl --verbose https://hass.vulcan.lan 2>&1 | grep -i certificate
   ```

## Module Configuration

The Node-RED module is located at:
```
/etc/nixos/modules/services/node-red.nix
```

Key configuration options:
```nix
services.node-red = {
  enable = true;
  withNpmAndGcc = true;  # Enable palette manager
  port = 1880;           # Default port
};
```

## Palette Management

With `withNpmAndGcc = true`, you can install additional Node-RED packages via the Palette Manager UI:

Common useful palettes for Home Assistant:
- `node-red-contrib-home-assistant-websocket` (required)
- `node-red-contrib-stoptimer`
- `node-red-contrib-moment`
- `node-red-contrib-bigtimer`

## Data Storage

Node-RED user data (flows, credentials, libraries) is stored in:
```
/var/lib/node-red/
```

Owned by the `node-red` user and group.

## Security Considerations

1. **Token Security**: The Home Assistant token is encrypted with SOPS and only readable by the `node-red` user
2. **SSL/TLS**: All communication uses SSL certificates from Step-CA
3. **Network Access**: Direct access limited to local network interface (end0)
4. **User Isolation**: Node-RED runs as dedicated `node-red` user

## Integration Examples

### Example 1: Turn on lights at sunset

1. Add **"inject"** node with schedule (sunset)
2. Add **"call service"** node (Home Assistant)
3. Configure service: `light.turn_on`
4. Set entity ID: `light.living_room`
5. Connect and deploy

### Example 2: Monitor sensor and send notification

1. Add **"events: state"** node for a sensor
2. Add **"switch"** node to check conditions
3. Add **"call service"** node: `notify.mobile_app_*`
4. Configure notification message
5. Connect and deploy

### Example 3: Complex automation with multiple triggers

1. Use multiple **"events: state"** nodes
2. Combine with **"join"** or **"gate"** nodes
3. Add logic with **"function"** nodes
4. Call multiple Home Assistant services
5. Add **"delay"** nodes for timing control

## Additional Resources

- [Node-RED Official Documentation](https://nodered.org/docs/)
- [Home Assistant WebSocket Nodes Documentation](https://zachowj.github.io/node-red-contrib-home-assistant-websocket/)
- [Node-RED Cookbook](https://cookbook.nodered.org/)
- [Home Assistant Node-RED Integration Guide](https://www.home-assistant.io/integrations/node_red/)

## Backup and Restore

### Backup Node-RED Flows

```bash
# Manual backup
sudo cp -r /var/lib/node-red /tank/Backups/node-red-$(date +%Y%m%d)

# Backup specific flows
sudo -u node-red cat /var/lib/node-red/flows.json > ~/node-red-flows-backup.json
```

### Restore Node-RED Flows

```bash
# Restore from backup
sudo systemctl stop node-red
sudo cp ~/node-red-flows-backup.json /var/lib/node-red/flows.json
sudo chown node-red:node-red /var/lib/node-red/flows.json
sudo systemctl start node-red
```

## Updates and Maintenance

Node-RED version is managed by nixpkgs. To update:

```bash
# Update flake inputs
nix flake update

# Rebuild system
sudo nixos-rebuild switch --flake '.#vulcan'
```

## Support

For issues or questions:
- Check logs: `sudo journalctl -u node-red -f`
- Verify SOPS secrets: `ls -la /run/secrets/home-assistant/`
- Review module configuration: `/etc/nixos/modules/services/node-red.nix`
- Check Home Assistant integration: Settings > Devices & Services
