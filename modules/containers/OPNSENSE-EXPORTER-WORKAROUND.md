# OPNsense Exporter Gateway Collector Workaround - IMPLEMENTED

## Problem
The opnsense-exporter v0.0.11 has a bug where it expects the `monitor_disable` field from the OPNsense API to be a string, but the API returns it as a boolean. This causes the gateway collector to fail with:

```
json: cannot unmarshal bool into Go struct field .rows.monitor_disable of type string
```

- **Issue**: https://github.com/AthennaMind/opnsense-exporter/issues/70
- **PR with fix**: https://github.com/AthennaMind/opnsense-exporter/pull/58

## Current Workaround - ACTIVE AND WORKING
We've implemented a Python-based HTTP proxy that intercepts API requests and transforms type-mismatched fields before the exporter receives them.

### Components:
1. **opnsense-api-transformer.nix** - Python proxy service that transforms API responses
2. **Modified opnsense-exporter-quadlet.nix** - Points to proxy instead of direct OPNsense API

### How it works:
1. The exporter makes requests to `http://10.88.0.1:8444` (Python proxy)
2. The proxy forwards requests to `https://192.168.1.1` (actual OPNsense API)
3. For `/api/routing/settings/searchGateway` endpoint, the proxy transforms the response:
   - Converts `"monitor_disable": true` to `"monitor_disable": "true"`
   - Converts `"monitor_disable": false` to `"monitor_disable": "false"`
   - Converts `"priority": <number>` to `"priority": "<string>"`
4. The exporter receives the transformed response and can properly unmarshal it

### Fields currently being transformed:
- `monitor_disable` - boolean to string
- `priority` - number to string

## Testing the Fix

### 1. Build and switch to the new configuration:
```bash
sudo nixos-rebuild switch --flake .#vulcan
```

### 2. Check transformer service is running:
```bash
sudo systemctl status opnsense-api-transformer
# Should show: active (running)
```

### 3. Restart the exporter:
```bash
sudo systemctl restart opnsense-exporter
```

### 4. Check exporter logs for gateway collector:
```bash
sudo journalctl -u opnsense-exporter -f | grep -i gateway
```

### 5. Verify metrics are being collected:
```bash
curl -s http://127.0.0.1:9273/metrics | grep opnsense_gateway
```

## Reverting the Workaround

When a fixed version of opnsense-exporter is released (check releases at https://github.com/AthennaMind/opnsense-exporter/releases):

### 1. Remove the proxy configuration files:
```bash
rm /etc/nixos/modules/containers/opnsense-api-transformer.nix
rm /etc/nixos/modules/containers/opnsense-api-proxy.nix  # if it exists
rm /etc/nixos/modules/containers/opnsense-api-proxy-lua.nix  # if it exists
rm /etc/nixos/modules/containers/OPNSENSE-EXPORTER-WORKAROUND.md
```

### 2. Update quadlet.nix:
Remove the import line for the transformer:

```nix
imports = [
  ./litellm-quadlet.nix
  # Remove this line: ./opnsense-api-transformer.nix
  ./opnsense-exporter-quadlet.nix
  ./silly-tavern-quadlet.nix
  ./wallabag-quadlet.nix
];
```

### 3. Update opnsense-exporter-quadlet.nix:
```nix
# Change these environment variables back:
OPNSENSE_EXPORTER_OPS_PROTOCOL = "https";  # Was "http"
OPNSENSE_EXPORTER_OPS_API = "192.168.1.1";  # Was "10.88.0.1:8444"
OPNSENSE_EXPORTER_OPS_INSECURE = "false";  # Was "true"

# Re-enable CA certificate volume mounts:
volumes = [
  "/var/lib/opnsense-exporter-ca.crt:/usr/local/share/ca-certificates/opnsense-ca.crt:ro"
  "/var/lib/opnsense-exporter-ca.crt:/etc/ssl/certs/ca-certificates.crt:ro"
];

# Re-enable SSL_CERT_FILE:
SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";

# Remove opnsense-api-transformer.service from dependencies:
After = [ "sops-nix.service" "network-online.target" "ensure-podman-network.service" ];
Wants = [ "sops-nix.service" "network-online.target" "ensure-podman-network.service" ];
```

### 4. Rebuild and switch:
```bash
sudo nixos-rebuild switch --flake .#vulcan
```

## Alternative Solutions (Not Implemented)

### Option 1: Build from source with PR fix
Build the exporter from source with PR #58 applied. More complex but fixes the root cause.

### Option 2: Fork and build container
Fork the repository, apply the fix, and build a custom container image.

### Option 3: Wait for upstream fix
Simply wait for the maintainers to merge the fix and release a new version.

## Current Status
- Workaround is **ACTIVE**
- Implemented: 2025-01-03
- Last tested: 2025-01-03
- Upstream issue: Open
- Upstream PR: Closed (not merged)