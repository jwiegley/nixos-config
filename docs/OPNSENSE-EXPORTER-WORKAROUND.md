# OPNsense Exporter Workarounds - IMPLEMENTED

> **Version note (2026-07-27):** the two bugs below were first hit on
> opnsense-exporter **v0.0.11**. The deployed container is pinned to the moving
> tag `ghcr.io/athennamind/opnsense-exporter:latest`, which currently resolves
> to image version **0.0.16** (built 2026-05-27). Upstream issue #70 is still
> open and PR #58 is still closed-unmerged, so the workaround has not been
> retired; it has simply not been re-tested against 0.0.16 without the proxy.

## Problems

### 1. Gateway Collector Issue
The opnsense-exporter v0.0.11 has a bug where it expects the `monitor_disable` field from the OPNsense API to be a string, but the API returns it as a boolean. This causes the gateway collector to fail with:

```
json: cannot unmarshal bool into Go struct field .rows.monitor_disable of type string
```

- **Issue**: https://github.com/AthennaMind/opnsense-exporter/issues/70
- **PR with fix**: https://github.com/AthennaMind/opnsense-exporter/pull/58

### 2. Firmware Collector Issue
The opnsense-exporter v0.0.11 fails to parse firmware status when the OPNsense API hasn't performed an update check yet. The API returns `product_check: null`, but the exporter expects `product.product_check.upgrade_needs_reboot` to be present. This causes warnings:

```
firmware: failed to parse UpgradeNeedsReboot
opnsense-client api call error: endpoint: api/core/firmware/status; failed status code: 0;
msg: error parsing '' to int: strconv.Atoi: parsing "": invalid syntax
```

## Current Workaround - ACTIVE AND WORKING
We've implemented a Python-based HTTP proxy that intercepts API requests and transforms type-mismatched fields before the exporter receives them.

### Components:
1. **opnsense-api-transformer.nix** - Python proxy service that transforms API responses
2. **Modified opnsense-exporter-quadlet.nix** - Points to proxy instead of direct OPNsense API

### How it works:
1. The exporter makes requests to `http://10.88.0.1:8444` (Python proxy)
2. The proxy forwards requests to `https://192.168.1.1` (actual OPNsense API)
3. For `/api/routing/settings/searchGateway` endpoint, the proxy transforms:
   - Converts `"monitor_disable": true/false` to `"monitor_disable": "true"/"false"`
   - Converts `"priority": <number>` to `"priority": "<string>"`
4. For `/api/core/firmware/status` endpoint, the proxy transforms:
   - Adds `"needs_reboot": "0"` if missing or empty
   - Creates `product.product_check` object if null or missing
   - Adds `product.product_check.upgrade_needs_reboot": "0"` if missing or empty
5. The exporter receives the transformed response and can properly unmarshal it

### Transformations applied:

#### Gateway endpoint (`/api/routing/settings/searchGateway`):
- `monitor_disable` - boolean to string
- `priority` - number to string

#### Firmware endpoint (`/api/core/firmware/status`):
- `needs_reboot` - add with value "0" if missing
- `product.product_check` - create object if null
- `product.product_check.upgrade_needs_reboot` - add with value "0" if missing

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
The exporter is a **rootless Home Manager quadlet** owned by the
`opnsense-exporter` user, so it is a *user* unit — there is no system unit of
that name:
```bash
sudo systemctl --machine=opnsense-exporter@.host --user restart opnsense-exporter.service
```

### 4. Check exporter logs for gateway collector:
```bash
sudo journalctl _SYSTEMD_USER_UNIT=opnsense-exporter.service -f | grep -i gateway
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
rm /etc/nixos/docs/OPNSENSE-EXPORTER-WORKAROUND.md           # this file (moved
                                                             # out of
                                                             # modules/containers/
                                                             # on 2025-10-21)
```

### 2. Update quadlet.nix:
Remove the import line for the transformer:

```nix
imports = [
  ./litellm-quadlet.nix
  # Remove this line: ./opnsense-api-transformer.nix
  ./opnsense-exporter-quadlet.nix
  ./wallabag-quadlet.nix
];
```

### 3. Update modules/users/home-manager/opnsense-exporter.nix:
The container definition moved to Home Manager; `modules/containers/opnsense-exporter-quadlet.nix`
now holds only the SOPS secret and the firewall openings, so these changes go in
the Home Manager module (inside `virtualisation.quadlet.containers.opnsense-exporter`):

```nix
# Change these environment variables back (containerConfig.environments):
OPNSENSE_EXPORTER_OPS_PROTOCOL = "https";  # Was "http"
OPNSENSE_EXPORTER_OPS_API = "192.168.1.1";  # Was "10.88.0.1:8444"
OPNSENSE_EXPORTER_OPS_INSECURE = "false";  # Was "true"

# Re-ADD the CA certificate volume mounts. These were dropped entirely during
# the Home Manager migration — there is nothing commented out to re-enable, so
# they must be written fresh as containerConfig.volumes:
volumes = [
  "/var/lib/opnsense-exporter-ca.crt:/usr/local/share/ca-certificates/opnsense-ca.crt:ro"
  "/var/lib/opnsense-exporter-ca.crt:/etc/ssl/certs/ca-certificates.crt:ro"
];

# Re-add SSL_CERT_FILE:
SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";

# Remove opnsense-api-transformer.service from unitConfig, leaving:
After = [ "sops-nix.service" ];
Wants = [ "sops-nix.service" ];
```

(The `sops-nix.service` ordering is itself a no-op on this host — sops-nix
installs secrets from an activation script and no such unit exists — but it is
left in place here to describe the file as written.)

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
- Gateway collector fix implemented: 2025-10-03 (commit 7db36d1)
- Firmware collector fix implemented: 2025-11-12 (commit c2d3e17)
- Last verified: 2026-07-27 — `opnsense-api-transformer.service` active, and
  `curl -s http://127.0.0.1:9273/metrics | grep opnsense_gateway` returns series
- Gateway upstream issue: Open (#70, still open as of 2026-07-27)
- Gateway upstream PR: Closed (not merged, #58)
- Firmware issue: Not yet reported upstream
