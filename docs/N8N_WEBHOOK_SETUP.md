# N8N Webhook Proxy Setup

Manual, secure reverse proxy for n8n webhooks using Nginx + Cloudflare Tunnel.

## Architecture

```
Internet (https://n8n.newartisans.com)
  ↓
Cloudflare Tunnel (automatic HTTPS)
  ↓
Nginx (localhost:8443) ← manually started
  ↓
Internal Nginx (n8n.vulcan.lan)
  ↓
n8n service (localhost:5678)
```

**Benefits:**
- Uses nginx (consistent with your existing stack)
- No port conflicts with existing nginx services
- Manual control (only runs when you enable it)
- Standard HTTPS port 443 (no :8443 in URLs)
- Automatic SSL via Cloudflare
- No firewall changes needed
- Completely isolated from secure-nginx container

---

## Initial Setup

### Step 1: Create Cloudflare Tunnel

1. **Log in to Cloudflare Dashboard**: https://dash.cloudflare.com
2. **Select your domain**: `newartisans.com`
3. **Go to Zero Trust** → **Networks** → **Tunnels**
4. **Click "Create a tunnel"**
5. **Name**: `n8n-webhook`
6. **Choose environment**: `Cloudflared`
7. **Copy the tunnel token** (looks like: `eyJhIjoiXXX...`)

### Step 2: Save Tunnel Credentials

```bash
# Edit secrets
sops /etc/nixos/secrets.yaml

# Add under cloudflared section:
cloudflared:
  n8n-tunnel-token: "eyJhIjoiXXX..."  # Paste your token here
```

### Step 3: Configure SOPS Secret in NixOS

Add to your secrets configuration (usually in `configuration.nix` or secrets module):

```nix
sops.secrets."cloudflared-n8n" = {
  mode = "0400";
  owner = "cloudflared";
  restartUnits = [ "cloudflared-tunnel-n8n-webhook.service" ];
};
```

### Step 4: Import Module

Add to `/etc/nixos/configuration.nix`:

```nix
imports = [
  ./modules/services/nginx-n8n-webhook.nix
];
```

### Step 5: Rebuild System

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

### Step 6: Configure Cloudflare DNS

In Cloudflare Dashboard:
1. **Go to DNS** → **Records**
2. **Add record**:
   - Type: `CNAME`
   - Name: `n8n`
   - Target: `<tunnel-id>.cfargotunnel.com` (shown in tunnel dashboard)
   - Proxy status: **Proxied** (orange cloud)

---

## Usage

### Enable Webhook Proxy

```bash
n8n-webhook-enable
```

This starts:
1. Nginx reverse proxy (localhost:8443)
2. Cloudflare Tunnel (connects to Cloudflare edge)

Your n8n webhooks are now accessible at: **https://n8n.newartisans.com**

### Disable Webhook Proxy

```bash
n8n-webhook-disable
```

This stops both services. Your n8n instance is no longer exposed to the internet.

### Check Status

```bash
n8n-webhook-status
```

Shows the status of nginx and Cloudflare Tunnel services, plus recent access logs.

### View Detailed Logs

```bash
n8n-webhook-logs
```

Shows last 50 lines from both nginx and Cloudflare Tunnel logs.

### Test Connectivity

```bash
n8n-webhook-test
```

Tests both local (localhost:8443) and public (n8n.newartisans.com) endpoints.

---

## Updating n8n Webhook URL

In n8n workflow settings, update the webhook URL environment variable:

```bash
# Check current webhook URL
systemctl cat n8n | grep WEBHOOK_URL

# If it's still using the internal URL, update it:
sudo systemctl edit n8n

# Add:
[Service]
Environment="WEBHOOK_URL=https://n8n.newartisans.com/"
```

Then restart n8n:
```bash
sudo systemctl restart n8n
```

---

## Configuration Details

### Nginx Configuration

Located at: `/etc/nginx/nginx-n8n-webhook.conf`

Key features:
- **Listen address**: `127.0.0.1:8443` (localhost only)
- **SSL/TLS**: Uses your existing n8n.vulcan.lan certificate
- **Proxy target**: `https://n8n.vulcan.lan`
- **WebSocket support**: Enabled for n8n UI
- **Long timeouts**: 300s for webhook responses
- **Security headers**: HSTS, X-Frame-Options, etc.
- **Health check**: `/health` endpoint

### Log Locations

- **Access logs**: `/var/log/nginx-n8n-webhook/access.log`
- **Error logs**: `/var/log/nginx-n8n-webhook/error.log`
- **Systemd logs**: `journalctl -u nginx-n8n-webhook`

### Runtime Files

- **PID file**: `/run/nginx-n8n-webhook/nginx.pid`
- **Socket files**: `/run/nginx-n8n-webhook/`

---

## Security Notes

1. **Manual control**: Services only run when you explicitly enable them
2. **No port conflicts**: Nginx binds to localhost:8443 only (separate from main nginx)
3. **Cloudflare protection**: DDoS protection and WAF included
4. **Internal encryption**: Nginx → nginx uses HTTPS with your Step-CA cert
5. **Audit logging**: All webhook access logged to `/var/log/nginx-n8n-webhook/access.log`
6. **Systemd hardening**: RestrictNamespaces, ProtectKernelModules, MemoryDenyWriteExecute, etc.
7. **Minimal privileges**: Runs as nginx user with read-only filesystem

---

## Troubleshooting

### Check nginx logs
```bash
sudo journalctl -u nginx-n8n-webhook -f
```

Or directly:
```bash
sudo tail -f /var/log/nginx-n8n-webhook/error.log
```

### Check Cloudflare Tunnel logs
```bash
sudo journalctl -u cloudflared-tunnel-n8n-webhook -f
```

### Test local nginx endpoint
```bash
curl -k https://localhost:8443/health
# Should return: OK
```

### Test public endpoint
```bash
curl -I https://n8n.newartisans.com/health
# Should return: HTTP/2 200
```

### Verify nginx configuration
```bash
sudo nginx -t -c /etc/nginx/nginx-n8n-webhook.conf
```

### Common Issues

**Issue**: "Address already in use" on port 8443
```bash
# Check what's using the port
sudo lsof -i :8443
# Or
sudo ss -tulpn | grep 8443
```

**Issue**: Cloudflare Tunnel won't connect
```bash
# Verify credentials file exists
ls -la /run/secrets/cloudflared-n8n

# Check tunnel status in Cloudflare dashboard
# Verify DNS CNAME is correct
```

**Issue**: 502 Bad Gateway
```bash
# Check if internal nginx is running
systemctl status nginx

# Check if n8n is running
systemctl status n8n

# Test internal endpoint directly
curl -k https://n8n.vulcan.lan
```

---

## Alternative: Without Cloudflare Tunnel

If you prefer not to use Cloudflare Tunnel, see the alternative approaches below.

### Option A: Tailscale Funnel

If you use Tailscale (already configured on your system):

```bash
# Enable Tailscale Funnel for n8n
sudo tailscale funnel 5678
```

Access via: `https://<machine-name>.tail-scale.ts.net`

Limitation: Cannot use custom domain (n8n.newartisans.com)

### Option B: SSH Reverse Tunnel

Manually create SSH tunnel to a VPS:

```bash
# On vulcan
ssh -R 8443:localhost:8443 user@your-vps.com

# On VPS, nginx config:
server {
    listen 443 ssl;
    server_name n8n.newartisans.com;
    location / {
        proxy_pass https://localhost:8443;
    }
}
```

Requires maintaining a VPS.

### Option C: HAProxy SNI Routing

Add HAProxy as front-proxy that routes by hostname:
- home.newartisans.com → secure-nginx
- n8n.newartisans.com → nginx-n8n-webhook

More complex configuration. Requires:
- HAProxy binds to 0.0.0.0:443
- Router forwards external 443 → HAProxy
- HAProxy inspects SNI (hostname) and routes accordingly

See `/etc/nixos/docs/HAPROXY_SNI_ROUTING.md` if you want this approach.

---

## Workflow Integration

When setting up n8n workflows with webhook triggers:

1. **Before testing**: `n8n-webhook-enable`
2. **Test webhook**: Click email links, test API callbacks
3. **After testing**: `n8n-webhook-disable`
4. **For production workflows**: Keep enabled during workflow execution windows

Example for Monday meeting automation:
```bash
# Monday 4:45 PM (before workflow starts at 5:00 PM)
n8n-webhook-enable

# Tuesday 9:00 PM (after WhatsApp reminder sent at 8:00 PM)
n8n-webhook-disable
```

### Automating Enable/Disable

If you want automatic enable/disable on a schedule:

```nix
# Add to your configuration
systemd.timers.n8n-webhook-enable = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "Mon 16:45";  # Monday 4:45 PM
    Persistent = true;
  };
};

systemd.services.n8n-webhook-enable = {
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.bash}/bin/bash -c 'systemctl start nginx-n8n-webhook && systemctl start cloudflared-tunnel-n8n-webhook'";
  };
};

systemd.timers.n8n-webhook-disable = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "Tue 21:00";  # Tuesday 9:00 PM
    Persistent = true;
  };
};

systemd.services.n8n-webhook-disable = {
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.bash}/bin/bash -c 'systemctl stop cloudflared-tunnel-n8n-webhook && systemctl stop nginx-n8n-webhook'";
  };
};
```

Then rebuild:
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```
