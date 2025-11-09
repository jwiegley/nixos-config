# CloudFlare Tunnels Setup

Persistent CloudFlare Tunnel connections for external service access without port forwarding.

## Overview

Two always-running CloudFlare Tunnels provide secure access to internal services:

1. **Data Tunnel**: `https://data.newartisans.com` → `http://localhost:18080`
2. **Rsync Tunnel**: `https://rsync.newartisans.com` → `http://localhost:18873`

**Benefits:**
- No port forwarding required
- Automatic HTTPS with CloudFlare certificates
- DDoS protection and WAF from CloudFlare
- Zero Trust access control (optional)
- Always running - no manual enable/disable needed

---

## Initial Setup

### Step 1: Create CloudFlare Tunnels

For each tunnel (data and rsync):

1. **Log in to CloudFlare Dashboard**: https://dash.cloudflare.com
2. **Select your domain**: `newartisans.com`
3. **Go to Zero Trust** → **Networks** → **Tunnels**
4. **Click "Create a tunnel"**
5. **Name**: `data` (or `rsync` for the second tunnel)
6. **Choose environment**: `Cloudflared`
7. **Copy the tunnel token** (format: `eyJhIjoiXXX...`)

**IMPORTANT**: Create TWO separate tunnels - one for data, one for rsync.

### Step 2: Save Tunnel Credentials

```bash
# Edit secrets file
sops /etc/nixos/secrets.yaml

# Add under cloudflared section:
cloudflared:
  data: "eyJhIjoiXXX..."    # Paste data tunnel token here
  rsync: "eyJhIjoiXXX..."   # Paste rsync tunnel token here
```

### Step 3: Configure CloudFlare DNS

In CloudFlare Dashboard → DNS → Records, add TWO CNAME records:

**Data Tunnel:**
- Type: `CNAME`
- Name: `data`
- Target: `<data-tunnel-id>.cfargotunnel.com` (from tunnel dashboard)
- Proxy status: **Proxied** (orange cloud)

**Rsync Tunnel:**
- Type: `CNAME`
- Name: `rsync`
- Target: `<rsync-tunnel-id>.cfargotunnel.com` (from tunnel dashboard)
- Proxy status: **Proxied** (orange cloud)

### Step 4: Rebuild System

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

The tunnels will start automatically and reconnect on boot.

---

## Service Management

### Check Tunnel Status

```bash
cloudflare-tunnel-status
```

Shows the running status of both tunnels.

### View Tunnel Logs

```bash
cloudflare-tunnel-logs data    # View data tunnel logs
cloudflare-tunnel-logs rsync   # View rsync tunnel logs
```

### Restart Tunnels

```bash
cloudflare-tunnel-restart data   # Restart data tunnel only
cloudflare-tunnel-restart rsync  # Restart rsync tunnel only
cloudflare-tunnel-restart all    # Restart both tunnels
```

### Detailed Status

```bash
systemctl status cloudflared-tunnel-data
systemctl status cloudflared-tunnel-rsync
```

---

## Verifying Connectivity

### Test Data Tunnel

```bash
# From any machine with internet access
curl -I https://data.newartisans.com

# Expected: HTTP response (200, 404, etc. depending on service)
```

### Test Rsync Tunnel

```bash
# From any machine with internet access
curl -I https://rsync.newartisans.com

# Expected: HTTP response from rsync service
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
ls -la /run/secrets/cloudflared-data
ls -la /run/secrets/cloudflared-rsync
```

**Check DNS configuration:**
- Verify CNAME records in CloudFlare dashboard
- Ensure "Proxied" (orange cloud) is enabled
- DNS may take up to 5 minutes to propagate

### Service Not Responding

**Check if local service is running:**
```bash
# For data tunnel (port 18080)
curl http://localhost:18080

# For rsync tunnel (port 18873)
curl http://localhost:18873
```

**Check if ports are listening:**
```bash
sudo ss -tulpn | grep 18080
sudo ss -tulpn | grep 18873
```

### Connection Timeouts

CloudFlare may timeout long-running connections. If you need longer timeouts:

1. Go to CloudFlare Dashboard → Zero Trust → Access → Tunnels
2. Select your tunnel
3. Click "Configure"
4. Adjust timeout settings under "Additional configuration"

### 502 Bad Gateway

Usually means the local service (port 18080 or 18873) is not responding:

```bash
# Check if services are running
systemctl status <your-service-name>

# Check if ports are listening
sudo netstat -tulpn | grep -E "18080|18873"
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
   - Ensure your services (port 18080, 18873) have their own authentication
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
Internet (https://data.newartisans.com)
  ↓
CloudFlare Edge (automatic HTTPS)
  ↓
CloudFlare Tunnel (encrypted connection)
  ↓
vulcan.lan (cloudflared daemon)
  ↓
localhost:18080 (data service)


Internet (https://rsync.newartisans.com)
  ↓
CloudFlare Edge (automatic HTTPS)
  ↓
CloudFlare Tunnel (encrypted connection)
  ↓
vulcan.lan (cloudflared daemon)
  ↓
localhost:18873 (rsync service)
```

**Key points:**
- CloudFlare handles SSL/TLS termination
- No inbound firewall rules needed
- Outbound connection only (cloudflared → CloudFlare)
- Services remain on localhost (not exposed to LAN)

---

## Related Services

### N8N Webhook Tunnel

Similar setup but manually controlled. See `/etc/nixos/docs/N8N_WEBHOOK_SETUP.md`

### Configuration Files

- Module: `/etc/nixos/modules/services/cloudflare-tunnels.nix`
- Secrets: `/etc/nixos/secrets.yaml` (encrypted)
- Deployed credentials: `/run/secrets/cloudflared-{data,rsync}`

---

## Maintenance

### Updating Tunnel Credentials

If you need to rotate tunnel tokens:

```bash
# Edit secrets
sops /etc/nixos/secrets.yaml

# Update the token
cloudflared:
  data: "new_token_here"

# Rebuild and restart
sudo nixos-rebuild switch --flake '.#vulcan'
```

The `restartUnits` configuration will automatically restart the tunnels.

### Removing a Tunnel

To disable a tunnel:

1. Remove from `modules/services/cloudflare-tunnels.nix`
2. Remove secrets from `secrets.yaml`
3. Remove CNAME from CloudFlare DNS
4. Delete tunnel from CloudFlare Dashboard
5. Rebuild: `sudo nixos-rebuild switch --flake '.#vulcan'`

---

## Differences from N8N Webhook Tunnel

| Feature | N8N Webhook | Data/Rsync Tunnels |
|---------|-------------|-------------------|
| Auto-start | No (manual) | Yes (automatic) |
| Nginx proxy | Yes | No (direct to localhost) |
| SSL termination | CloudFlare + Nginx | CloudFlare only |
| Management commands | n8n-webhook-* | cloudflare-tunnel-* |
| Use case | Temporary webhook access | Persistent service access |

---

## Additional Resources

- CloudFlare Tunnel Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Zero Trust Access: https://developers.cloudflare.com/cloudflare-one/applications/
- CloudFlare Analytics: https://dash.cloudflare.com → Analytics
