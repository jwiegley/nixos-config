# CloudFlare Tunnels Setup

Persistent CloudFlare Tunnel connections for external service access without port forwarding.

> **Status (2026-07-27):** There is now exactly **one** tunnel, named `data`
> (unit `cloudflared-tunnel-data.service`), and it fronts **four** hostnames.
> The second "rsync" tunnel described by earlier revisions of this document was
> removed on 2025-11-17 in commit `44ab9e6` ("cloudflare-tunnels: Remove rsync
> tunnel configuration"): `rsync.newartisans.com`, the
> `cloudflared-tunnel-rsync.service` unit and the `cloudflared/rsync` SOPS
> secret no longer exist, and nothing listens on port 18873. The
> `cloudflare-tunnel-*` helper commands accept only `data` (and `all` for
> restart). Everything below has been updated to the single-tunnel reality.

## Overview

One always-running CloudFlare Tunnel (`data`) provides secure access to internal
services. Its ingress map (`modules/services/cloudflare-tunnels.nix:45-50`) is:

1. `https://data.newartisans.com` → `http://localhost:18080` (static-nginx container)
2. `https://gitea.newartisans.com` → `http://localhost:3005` (Gitea)
3. `https://s.newartisans.com` → `http://localhost:8580` (Shlink)
4. `https://calendar.newartisans.com` → `http://localhost:8090` (Sacramento Cluster .ics)

Anything not matching one of those hostnames gets the tunnel default,
`http_status:404`.

**Benefits:**
- No port forwarding required
- Automatic HTTPS with CloudFlare certificates
- DDoS protection and WAF from CloudFlare
- Zero Trust access control (optional)
- Always running - no manual enable/disable needed

---

## Initial Setup

### Step 1: Create the CloudFlare Tunnel

1. **Log in to CloudFlare Dashboard**: https://dash.cloudflare.com
2. **Select your domain**: `newartisans.com`
3. **Go to Zero Trust** → **Networks** → **Tunnels**
4. **Click "Create a tunnel"**
5. **Name**: `data`
6. **Choose environment**: `Cloudflared`
7. **Copy the tunnel token** (format: `eyJhIjoiXXX...`)

**IMPORTANT**: One tunnel serves all four hostnames — do not create a second
tunnel per hostname. Additional hostnames are added to the `ingress` attrset in
`modules/services/cloudflare-tunnels.nix`, not by creating new tunnels.

### Step 2: Save Tunnel Credentials

Secrets live in the separate `secrets` git repo consumed as a flake input, not
at the repo root (`/etc/nixos/secrets.yaml` does not exist):

```bash
# Edit secrets file
cd /etc/nixos
sops secrets/secrets.yaml

# Add under cloudflared section:
cloudflared:
  data: "eyJhIjoiXXX..."    # Paste data tunnel token here
```

### Step 3: Configure CloudFlare DNS

In CloudFlare Dashboard → DNS → Records, add one CNAME record per hostname the
tunnel fronts (`data`, `gitea`, `s`, `calendar`). For each:

- Type: `CNAME`
- Name: `data` (then `gitea`, `s`, `calendar`)
- Target: `<data-tunnel-id>.cfargotunnel.com` (from tunnel dashboard)
- Proxy status: **Proxied** (orange cloud)

### Step 4: Rebuild System

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

The tunnel will start automatically and reconnect on boot. Its unit sets
`StartLimitIntervalSec=0` and `RestartSec=10`, so it retries forever rather than
giving up if DNS is still warming up at boot.

---

## Service Management

### Check Tunnel Status

```bash
cloudflare-tunnel-status
```

Shows the running status of the tunnel.

### View Tunnel Logs

```bash
cloudflare-tunnel-logs data    # View data tunnel logs
```

`data` is the only accepted argument; anything else prints a usage message.

### Restart Tunnels

```bash
cloudflare-tunnel-restart data   # Restart the data tunnel
cloudflare-tunnel-restart all    # Same thing (only one tunnel exists)
```

### Detailed Status

```bash
systemctl status cloudflared-tunnel-data
```

### Metrics

The unit sets `TUNNEL_METRICS=127.0.0.1:9301`, so cloudflared's Prometheus
endpoint (including `cloudflared_tunnel_ha_connections`) is scraped locally as
`job=cloudflared`:

```bash
curl -s http://127.0.0.1:9301/metrics | grep cloudflared_tunnel_ha_connections
```

---

## Verifying Connectivity

### Test Data Tunnel

```bash
# From any machine with internet access
curl -I https://data.newartisans.com

# Expected: HTTP response (200, 404, etc. depending on service)
```

### Test the Other Hostnames

```bash
# From any machine with internet access
curl -I https://gitea.newartisans.com
curl -I https://s.newartisans.com
curl -I https://calendar.newartisans.com

# Expected: HTTP response from Gitea / Shlink / the calendar publisher.
# A hostname not in the ingress map returns 404 (the tunnel default).
```

---

## Troubleshooting

### Tunnel Not Connecting

**Check tunnel status:**
```bash
cloudflare-tunnel-status
```

**Check logs for errors:**
```bash
cloudflare-tunnel-logs data
```

**Verify credentials file exists:**
```bash
ls -la /run/secrets/cloudflared/data
```

**Check DNS configuration:**
- Verify CNAME records in CloudFlare dashboard
- Ensure "Proxied" (orange cloud) is enabled
- DNS may take up to 5 minutes to propagate

### Service Not Responding

**Check if the local service behind the failing hostname is running:**
```bash
curl http://localhost:18080   # data.newartisans.com     (static-nginx container)
curl http://localhost:3005    # gitea.newartisans.com    (Gitea)
curl http://localhost:8580    # s.newartisans.com        (Shlink API)
curl http://localhost:8090    # calendar.newartisans.com (calendar publisher)
```

**Check if ports are listening:**
```bash
sudo ss -tulpn | grep -E '18080|3005|8580|8090'
```

### Connection Timeouts

CloudFlare may timeout long-running connections. If you need longer timeouts:

1. Go to CloudFlare Dashboard → Zero Trust → Access → Tunnels
2. Select your tunnel
3. Click "Configure"
4. Adjust timeout settings under "Additional configuration"

### 502 Bad Gateway

Usually means the local service behind that hostname (18080, 3005, 8580 or
8090) is not responding:

```bash
# Check if services are running
systemctl status <your-service-name>

# Check if ports are listening
sudo ss -tulpn | grep -E "18080|3005|8580|8090"
```

---

## Security Considerations

### Access Control

By default, tunnels are publicly accessible. To restrict access:

1. **CloudFlare Access** (Zero Trust):
   - Go to CloudFlare Dashboard → Zero Trust → Access → Applications
   - Create access policies for your tunnels
   - Configure authentication (email, Google, etc.)

2. **Application-level authentication**:
   - Ensure the services behind the tunnel (18080, 3005, 8580, 8090) have their
     own authentication
   - Do not rely solely on CloudFlare Tunnel obscurity

### Monitoring

Monitor tunnel access in CloudFlare Analytics:
- CloudFlare Dashboard → Zero Trust → Logs → Access
- Review connection attempts and usage patterns

### Rate Limiting

Configure rate limiting in CloudFlare:
- CloudFlare Dashboard → Security → WAF
- Create rate limiting rules for your tunnel domains

---

## Architecture

```
Internet (data. / gitea. / s. / calendar.newartisans.com)
  ↓
CloudFlare Edge (automatic HTTPS)
  ↓
CloudFlare Tunnel "data" (single encrypted connection)
  ↓
vulcan.lan (cloudflared-tunnel-data.service)
  ↓
localhost:18080  (data     → static-nginx container)
localhost:3005   (gitea    → Gitea)
localhost:8580   (s        → Shlink API)
localhost:8090   (calendar → calendar publisher, plain HTTP by design)
```

**Key points:**
- CloudFlare handles SSL/TLS termination
- No inbound firewall rules needed
- Outbound connection only (cloudflared → CloudFlare)
- Services remain on localhost (not exposed to LAN)

---

## Related Services

### N8N Webhook Tunnel (removed)

n8n and its manually controlled webhook tunnel were removed from this repository
on 2026-03-14 (commit `f40e2ac`), together with `docs/N8N_WEBHOOK_SETUP.md`.
There is no `n8n-webhook-*` command, `cloudflared-tunnel-n8n-webhook.service`
unit, or `n8n.newartisans.com` hostname any more. The historical procedure is
kept for background in [CLOUDFLARE_MIGRATION.md](CLOUDFLARE_MIGRATION.md).

### Configuration Files

- Module: `/etc/nixos/modules/services/cloudflare-tunnels.nix`
- Secrets: `/etc/nixos/secrets/secrets.yaml` (encrypted; separate git repo
  consumed as the `secrets` flake input — there is no `/etc/nixos/secrets.yaml`)
- Deployed credentials: `/run/secrets/cloudflared/data`

---

## Maintenance

### Updating Tunnel Credentials

If you need to rotate tunnel tokens:

```bash
# Edit secrets
cd /etc/nixos
sops secrets/secrets.yaml

# Update the token
cloudflared:
  data: "new_token_here"

# Commit the change in the secrets repo, then re-lock the flake input:
git -C secrets commit -am "cloudflared: rotate data tunnel token"
nix flake update secrets

# Rebuild and restart
sudo nixos-rebuild switch --flake '.#vulcan'
```

The secret's `restartUnits = [ "cloudflared-tunnel-data.service" ]` will
automatically restart the tunnel.

### Removing a Tunnel

To disable a tunnel:

1. Remove from `modules/services/cloudflare-tunnels.nix`
2. Remove the secret from `secrets/secrets.yaml` (and re-lock the `secrets` input)
3. Remove CNAME from CloudFlare DNS
4. Delete tunnel from CloudFlare Dashboard
5. Rebuild: `sudo nixos-rebuild switch --flake '.#vulcan'`

---

## Additional Resources

- CloudFlare Tunnel Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Zero Trust Access: https://developers.cloudflare.com/cloudflare-one/applications/
- CloudFlare Analytics: https://dash.cloudflare.com → Analytics
