# Cloudflare DNS Migration & N8N Webhook Setup Guide

Complete guide for migrating DNS from Name.com to Cloudflare and setting up n8n webhook proxy.

---

## Overview

This guide covers:
1. Migrating DNS from Name.com to Cloudflare
2. Creating Cloudflare Tunnel for n8n webhooks
3. Configuring NixOS with tunnel credentials
4. Updating DDNS script for home.newartisans.com
5. **Optional:** Transferring domain registration to Cloudflare (close Name.com account entirely)

**Estimated time:**
- Parts 1-6 (DNS + webhook setup): 2-4 hours (mostly waiting for DNS propagation)
- Part 7 (domain transfer): 5-7 days additional (optional)

---

## Part 1: Migrate DNS to Cloudflare

### Prerequisites
- Cloudflare account (free tier is fine)
- Access to Name.com account
- Domain: `newartisans.com`

### Step 1: Add Domain to Cloudflare

1. **Go to:** https://dash.cloudflare.com
2. **Click:** "Add a site" (or "Add a domain")
3. **Enter:** `newartisans.com`
4. **Select plan:** Free
5. **Click:** "Continue"

Cloudflare will now scan your existing DNS records from Name.com.

### Step 2: Review Imported DNS Records

Cloudflare will display all DNS records it found from Name.com:

**Critical records to verify:**
- ✓ `home.newartisans.com` → A record pointing to your current IP
- ✓ MX records (email, if any)
- ✓ TXT records (SPF, DKIM, DMARC, if any)
- ✓ Any other subdomains or services

**Important:** Review carefully! Any missing records will break services.

**Action:**
- If records are missing: Add them manually
- If records look correct: Click "Continue"

### Step 3: Note Cloudflare Nameservers

Cloudflare will show you two nameservers, like:
```
ray.ns.cloudflare.com
rafe.ns.cloudflare.com
```

**Write these down** or keep this browser tab open - you'll need them in the next step.

### Step 4: Update Nameservers at Name.com

1. **Log into:** Name.com
2. **Navigate to:** My Domains → `newartisans.com`
3. **Find:** "Nameservers" or "DNS Settings"
4. **Click:** "Change Nameservers" or "Use Custom Nameservers"
5. **Remove:** All Name.com nameservers:
   - `ns1.name.com`
   - `ns2.name.com`
   - `ns3.name.com`
   - `ns4.name.com`
6. **Add:** The two Cloudflare nameservers from Step 3
7. **Save changes**

**Expected behavior:** Name.com may show a warning that you're pointing to external nameservers - this is normal.

### Step 5: Wait for DNS Propagation

**Timeline:**
- Cloudflare shows: "Nameservers not updated yet"
- Typical propagation: 1-4 hours
- Maximum propagation: 24 hours

**What to do while waiting:**
- Keep the Cloudflare tab open or bookmark it
- You'll receive an email when DNS is active
- Status will change to "Active" in Cloudflare dashboard

**Check propagation status:**
```bash
# Check nameservers (should show Cloudflare)
dig newartisans.com NS

# Or use online tools
# https://www.whatsmydns.net/#NS/newartisans.com
```

**⏸️ STOP HERE until DNS propagation is complete**

---

## Part 2: Create Cloudflare Tunnel

**Prerequisites:** DNS must be active on Cloudflare (status: "Active")

### Step 6: Navigate to Tunnels

1. **Cloudflare dashboard:** https://dash.cloudflare.com
2. **Select:** `newartisans.com` (if multiple domains)
3. **Go to:** Zero Trust → Networks → Tunnels
4. **Click:** "Create a tunnel"

### Step 7: Configure Tunnel

1. **Choose environment:** Cloudflared
2. **Tunnel name:** `n8n-webhook`
3. **Click:** "Save tunnel"

### Step 8: Get Tunnel Credentials

You'll now see the tunnel configuration page with three important values:

**Values you need:**
1. **Tunnel ID:** Long alphanumeric string (e.g., `a1b2c3d4-e5f6-7890-abcd-ef1234567890`)
2. **Tunnel Secret:** Long base64 string
3. **Account ID:** Find this separately (see below)

**To find Account ID:**

**Method A - From URL:**
Look at your browser URL:
```
https://dash.cloudflare.com/1234567890abcdef/...
                              ^^^^^^^^^^^^^^^^
                              This is your Account ID
```

**Method B - From Profile:**
1. Click profile icon (top right)
2. Click "My Profile"
3. Look for "Account ID" on the right sidebar

**Method C - From Zero Trust:**
1. Go to: Zero Trust → Settings → General
2. Find "Account ID"

**Write down all three values:**
```
Account ID: ____________________________________
Tunnel ID:  ____________________________________
Secret:     ____________________________________
```

**Alternative:** If Cloudflare offers a "Download credentials.json" button, download that file instead - it contains all three values pre-formatted.

### Step 9: Configure Public Hostname

Still on the tunnel configuration page:

1. **Click:** "Public Hostname" tab
2. **Click:** "Add a public hostname"
3. **Configure:**
   - **Subdomain:** `n8n`
   - **Domain:** `newartisans.com`
   - **Type:** HTTPS
   - **URL:** `https://localhost:8443`
4. **Click:** "Save hostname"

This creates the DNS CNAME record automatically:
```
n8n.newartisans.com → <tunnel-id>.cfargotunnel.com
```

### Step 10: Verify DNS Record

1. **Go to:** DNS → Records
2. **Verify:** You should see:
   - Type: `CNAME`
   - Name: `n8n`
   - Target: `<tunnel-id>.cfargotunnel.com`
   - Proxy status: **Proxied** (orange cloud)

**Note:** The CNAME was created automatically in Step 9, but verify it's there.

---

## Part 3: Configure NixOS

**Prerequisites:** Tunnel created, credentials obtained

### Step 11: Add Credentials to SOPS

**Build the JSON structure:**

Using the three values from Step 8, create this JSON:

```json
{
  "AccountTag": "YOUR_ACCOUNT_ID_HERE",
  "TunnelSecret": "YOUR_SECRET_HERE",
  "TunnelID": "YOUR_TUNNEL_ID_HERE"
}
```

**Example:**
```json
{
  "AccountTag": "a1b2c3d4e5f67890abcdef1234567890",
  "TunnelSecret": "aGVsbG8gdGhpcyBpcyBhIHNlY3JldA==",
  "TunnelID": "12345678-abcd-1234-efgh-567890abcdef"
}
```

**Add to SOPS:**

```bash
sops /etc/nixos/secrets.yaml
```

Add this section (paste your JSON values):
```yaml
cloudflared-n8n: |
  {
    "AccountTag": "your-account-id-from-step-8",
    "TunnelSecret": "your-secret-from-step-8",
    "TunnelID": "your-tunnel-id-from-step-8"
  }
```

**Important formatting notes:**
- The `|` character means multi-line string (keep it)
- Indent the JSON block by 2 spaces
- Keep the JSON on separate lines as shown
- Don't add extra quotes around the JSON

Save and exit (`:wq` in vim).

### Step 12: Build and Apply Configuration

```bash
# Build first to check for errors
sudo nixos-rebuild build --flake '.#vulcan'

# If successful, apply
sudo nixos-rebuild switch --flake '.#vulcan'
```

**Expected output:**
- New packages: `cloudflared`, helper scripts
- New services: `nginx-n8n-webhook`, `cloudflared-tunnel-n8n-webhook`
- Both services will be stopped (manual start only)

### Step 13: Enable Webhook Proxy

```bash
# Start the services
n8n-webhook-enable
```

**Expected output:**
```
Starting n8n webhook proxy...
✓ Nginx reverse proxy started
✓ Cloudflare Tunnel started

Webhook proxy is now active at: https://n8n.newartisans.com

To check status: n8n-webhook-status
To disable: n8n-webhook-disable
```

### Step 14: Verify Services

```bash
# Check status
n8n-webhook-status

# Should show both services as "active (running)"
```

**Expected output:**
```
=== Nginx N8N Webhook Proxy Status ===
● nginx-n8n-webhook.service - Nginx reverse proxy for n8n webhooks
     Loaded: loaded
     Active: active (running)
     ...

=== Cloudflare Tunnel Status ===
● cloudflared-tunnel-n8n-webhook.service
     Loaded: loaded
     Active: active (running)
     ...
```

### Step 15: Test Connectivity

```bash
# Run the test script
n8n-webhook-test
```

**Expected output:**
```
Testing n8n webhook proxy...

1. Testing health endpoint (local):
OK

2. Testing public endpoint (requires DNS configured):
HTTP/2 200
```

**If test fails:**
```bash
# Check nginx logs
sudo journalctl -u nginx-n8n-webhook -f

# Check cloudflare tunnel logs
sudo journalctl -u cloudflared-tunnel-n8n-webhook -f

# Test manually
curl -k https://localhost:8443/health
curl -I https://n8n.newartisans.com/health
```

### Step 16: Test N8N Access

Open in browser:
```
https://n8n.newartisans.com
```

**Expected:** You should see the n8n login/interface.

**If it doesn't work:**
- Wait a few minutes (DNS may still be propagating)
- Check Cloudflare Tunnel status in dashboard
- Check service logs (Step 15)

### Step 17: Disable Webhook Proxy (When Done Testing)

```bash
n8n-webhook-disable
```

**Expected output:**
```
Stopping n8n webhook proxy...
✓ Cloudflare Tunnel stopped
✓ Nginx reverse proxy stopped

Webhook proxy is now disabled
```

---

## Part 4: Update DDNS for home.newartisans.com

**Goal:** Replace Name.com API with Cloudflare API for DDNS updates from OPNsense.

### Step 18: Create Cloudflare API Token

1. **Cloudflare dashboard:** My Profile → API Tokens
2. **Click:** "Create Token"
3. **Use template:** "Edit zone DNS"
4. **Configure:**
   - **Permissions:** Zone / DNS / Edit
   - **Zone Resources:** Include / Specific zone / `newartisans.com`
   - **Client IP Address Filtering:** (leave empty)
   - **TTL:** (leave default or set expiration if desired)
5. **Click:** "Continue to summary"
6. **Click:** "Create Token"
7. **Copy the token** (you won't see it again!)

**Store the token securely** - you'll need it for the DDNS script.

### Step 19: Get Zone ID

**Method A - From Dashboard:**
1. Cloudflare dashboard → Select `newartisans.com`
2. Look at **Overview** tab
3. Scroll down on the right sidebar
4. Find **"Zone ID"**
5. Click to copy

**Method B - From URL:**
```
https://dash.cloudflare.com/YOUR_ACCOUNT_ID/newartisans.com/YOUR_ZONE_ID
                                                             ^^^^^^^^^^^^^
```

**Write down your Zone ID:**
```
Zone ID: ____________________________________
```

### Step 20: Get DNS Record ID

You need the Record ID for the `home.newartisans.com` A record.

**Via API:**
```bash
# Replace with your values
ZONE_ID="your-zone-id-from-step-19"
API_TOKEN="your-api-token-from-step-18"

curl -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=home.newartisans.com" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json"
```

**Look for the `"id"` field in the response:**
```json
{
  "result": [
    {
      "id": "abc123def456...",  ← This is your Record ID
      "type": "A",
      "name": "home.newartisans.com",
      "content": "YOUR_CURRENT_IP",
      ...
    }
  ]
}
```

**Write down your Record ID:**
```
Record ID: ____________________________________
```

### Step 21: Create New DDNS Script

**For OPNsense or any Linux system:**

Create a new script: `/usr/local/bin/cloudflare-ddns.sh`

```bash
#!/bin/bash

# Cloudflare credentials
CF_TOKEN="your-api-token-from-step-18"
ZONE_ID="your-zone-id-from-step-19"
RECORD_ID="your-record-id-from-step-20"

# Get current public IP
NEW_IP=$(curl -s https://api.ipify.org)

# Update Cloudflare DNS record
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"home.newartisans.com\",\"content\":\"$NEW_IP\",\"ttl\":300,\"proxied\":false}"
```

**Make it executable:**
```bash
chmod +x /usr/local/bin/cloudflare-ddns.sh
```

**Important settings:**
- `"ttl":300` = 5 minutes (fast updates)
- `"proxied":false` = Direct IP access (needed for your services)

Set `"proxied":true` if you want Cloudflare to proxy the connection (DDoS protection, but hides your real IP).

### Step 22: Update OPNsense Configuration

**Location in OPNsense:**
1. Navigate to: Services → Dynamic DNS
2. Find your existing Name.com DDNS entry
3. Either:
   - **Option A:** Edit existing entry to use custom script
   - **Option B:** Delete Name.com entry, add new custom entry

**Option A - If OPNsense has built-in Cloudflare support:**
1. Change provider to "Cloudflare"
2. Enter:
   - Zone ID (from Step 19)
   - API Token (from Step 18)
   - Hostname: `home.newartisans.com`

**Option B - Use custom script:**
1. Set provider to "Custom"
2. Point to script: `/usr/local/bin/cloudflare-ddns.sh`
3. Configure trigger (on WAN IP change)

### Step 23: Test DDNS Update

**Manual test:**
```bash
/usr/local/bin/cloudflare-ddns.sh
```

**Verify in Cloudflare:**
1. Go to: DNS → Records
2. Find: `home.newartisans.com` A record
3. Verify: IP matches your current public IP

**Check OPNsense logs:**
- Navigate to: System → Log Files → General
- Look for Dynamic DNS update messages

---

## Part 5: Update N8N Webhook URL

**Goal:** Tell n8n to use the public URL for webhooks.

### Step 24: Update N8N Environment Variable

```bash
# Check current webhook URL
systemctl cat n8n | grep WEBHOOK_URL
```

**If it shows:** `WEBHOOK_URL=https://n8n.vulcan.lan/`

**Update it:**
```bash
sudo systemctl edit n8n
```

Add this in the editor:
```ini
[Service]
Environment="WEBHOOK_URL=https://n8n.newartisans.com/"
```

Save and exit.

### Step 25: Restart N8N

```bash
sudo systemctl restart n8n
```

**Verify:**
```bash
systemctl cat n8n | grep WEBHOOK_URL
# Should show: WEBHOOK_URL=https://n8n.newartisans.com/
```

---

## Part 6: Usage & Maintenance

### Daily Usage

**Enable webhook proxy (before n8n workflows need webhooks):**
```bash
n8n-webhook-enable
```

**Disable webhook proxy (when done):**
```bash
n8n-webhook-disable
```

**Check status:**
```bash
n8n-webhook-status
```

**View logs:**
```bash
n8n-webhook-logs
```

**Test connectivity:**
```bash
n8n-webhook-test
```

### For Monday Meeting Workflow

**Schedule:**
```bash
# Monday 4:45 PM (15 minutes before workflow starts at 5:00 PM)
n8n-webhook-enable

# Tuesday 9:00 PM (after WhatsApp reminder sent at 8:00 PM)
n8n-webhook-disable
```

**Optional - Automate with systemd timers:**

See documentation: `/etc/nixos/docs/N8N_WEBHOOK_SETUP.md` (section: "Automating Enable/Disable")

### Monitoring

**Check Cloudflare Tunnel status:**
- Cloudflare dashboard → Zero Trust → Networks → Tunnels
- Should show: Status "Healthy", Last seen "X seconds ago"

**Check nginx logs:**
```bash
sudo tail -f /var/log/nginx-n8n-webhook/access.log
sudo tail -f /var/log/nginx-n8n-webhook/error.log
```

**Check webhook access:**
- Every successful webhook call is logged
- Review periodically for security

---

## Part 7: Optional - Transfer Domain Registration to Cloudflare

**Prerequisites:**
- DNS fully migrated to Cloudflare (Parts 1-6 complete)
- All services verified working with Cloudflare DNS
- Domain must be at least 60 days old at current registrar
- Domain not within 60 days of previous transfer

**Goal:** Transfer domain registration from Name.com to Cloudflare, making Cloudflare both your DNS provider AND domain registrar.

**Benefits:**
- Single provider for domain registration + DNS + Tunnel
- Cloudflare Registrar pricing (at-cost, no markup)
- Simplified billing (one invoice instead of two)
- Unified management dashboard
- Can close Name.com account entirely

**Timeline:** 5-7 days for transfer to complete

---

### Step 26: Prepare Domain for Transfer

**At Name.com - Unlock Domain:**

1. **Log into:** Name.com
2. **Go to:** My Domains → `newartisans.com`
3. **Find:** "Domain Lock" or "Transfer Lock" setting
4. **Action:** Disable/Unlock the domain
5. **Save changes**

**Important:** Domain must be unlocked to transfer. Most registrars lock domains by default to prevent unauthorized transfers.

**At Name.com - Get Authorization Code:**

1. **Still on domain page:** `newartisans.com`
2. **Find:** "Authorization Code" or "EPP Code" or "Transfer Code"
3. **Click:** "Email Auth Code" or "Get Auth Code"
4. **Check email:** Name.com will send the code to your registered email
5. **Copy the code:** It looks like: `ABC123DEF456GH`

**Important:** This code proves you own the domain. Keep it secure and don't share it publicly.

### Step 27: Verify Prerequisites at Cloudflare

**Check domain eligibility:**

1. **Cloudflare dashboard:** Select `newartisans.com`
2. **Go to:** Domain Registration → Transfer Domains
3. **Check:** Cloudflare will show if domain is eligible for transfer

**Common issues that prevent transfer:**
- ❌ Domain locked at current registrar
- ❌ Domain registered/transferred within last 60 days
- ❌ Domain status is not "ok" (clientTransferProhibited, etc.)
- ❌ WHOIS privacy enabled (may need to disable temporarily)
- ❌ Invalid contact info in WHOIS

**Verify contact information:**

1. **At Name.com:** Check that WHOIS contact email is accessible
2. **Important:** You'll receive transfer confirmation emails at this address
3. **Update if needed:** Ensure email is current and checked regularly

### Step 28: Initiate Transfer at Cloudflare

**Start the transfer:**

1. **Cloudflare dashboard:** `newartisans.com` → Domain Registration → Transfer Domains
2. **Click:** "Transfer" or "Initiate Transfer"
3. **Enter:** Authorization code from Step 26
4. **Review:** Transfer price (Cloudflare charges at-cost, typically $8-15/year for .com)
5. **Confirm:** Domain details and transfer terms
6. **Add to cart** and **proceed to checkout**

**Payment:**

- Cloudflare will charge for 1 year of registration
- This adds 1 year to your existing expiration date (you don't lose time)
- Payment methods: Credit card, PayPal

### Step 29: Approve Transfer

**You will receive TWO emails:**

**Email 1 - From Cloudflare:**
- Subject: "Confirm domain transfer to Cloudflare"
- Action: Click the confirmation link
- Timeline: Within a few minutes of initiating transfer

**Email 2 - From Name.com:**
- Subject: "Transfer request for newartisans.com"
- Action: Click "Approve Transfer" (or do nothing - it auto-approves after 5 days)
- Timeline: Within a few hours of initiating transfer

**Important:**
- Approve the Cloudflare email immediately
- For Name.com email, you have two options:
  - **Option A:** Click "Approve Transfer" (transfer completes in ~1 day)
  - **Option B:** Do nothing (transfer auto-approves after 5 days)

**To speed up the transfer:**
1. Log into Name.com
2. Go to: My Domains → `newartisans.com` → Domain Transfers
3. Find the pending transfer
4. Click: "Approve" or "Accept Transfer"

### Step 30: Wait for Transfer Completion

**Timeline:**
- **Fastest:** 1 day (if approved at Name.com immediately)
- **Typical:** 5-7 days (if auto-approval)
- **Maximum:** 7 days (ICANN rules)

**During the transfer:**
- ✅ DNS continues working (no downtime)
- ✅ All services remain operational
- ✅ Email continues working
- ✅ Cloudflare Tunnel continues working
- ✅ Nameservers stay on Cloudflare

**What's happening:**
1. Cloudflare requests transfer from Name.com
2. Name.com verifies authorization code
3. Name.com sends confirmation email (5-day countdown)
4. Either: You approve (fast), or 5 days pass (auto-approve)
5. Name.com releases domain to Cloudflare
6. Cloudflare confirms registration
7. Transfer complete

### Step 31: Verify Transfer Completion

**You'll receive an email from Cloudflare:**
- Subject: "Domain transfer completed"
- Content: Confirmation that newartisans.com is now registered at Cloudflare

**Verify in Cloudflare dashboard:**

1. **Go to:** Domain Registration → Manage Domains
2. **Check:** `newartisans.com` should appear in the list
3. **Status:** Should show as "Active"
4. **Expiration:** Should show renewed expiration date (+1 year)

**Verify WHOIS:**

```bash
whois newartisans.com
```

Look for:
```
Registrar: Cloudflare, Inc.
```

Or use online tools:
- https://lookup.icann.org/en/lookup
- https://www.whois.com/whois/newartisans.com

### Step 32: Configure Domain Settings at Cloudflare

**Auto-renew settings:**

1. **Cloudflare dashboard:** Domain Registration → Manage Domains
2. **Click:** `newartisans.com`
3. **Find:** "Auto-renew" setting
4. **Enable:** Auto-renew (recommended)
5. **Save**

This ensures your domain doesn't expire accidentally.

**WHOIS privacy:**

Cloudflare automatically provides WHOIS privacy at no extra cost.

**Verify:**
1. Check WHOIS output: Should show Cloudflare's privacy service contact info
2. Your personal info should be hidden

**DNS settings:**

No changes needed - DNS records remain as configured during migration.

**Verify:**
```bash
dig newartisans.com NS
dig home.newartisans.com A
dig n8n.newartisans.com CNAME
```

All should return correct values.

### Step 33: Close Name.com Account (Optional)

**Before closing:**

**✓ Checklist - Verify ALL of these:**
- [ ] Domain transfer complete at Cloudflare
- [ ] Domain shows in Cloudflare Manage Domains
- [ ] Auto-renew enabled at Cloudflare
- [ ] DNS records all working correctly
- [ ] Email still working (if using MX records)
- [ ] N8N webhooks still working
- [ ] home.newartisans.com still accessible
- [ ] No other domains at Name.com (check thoroughly!)
- [ ] No active services/subscriptions at Name.com
- [ ] Downloaded domain history/records for backup

**Export records from Name.com (backup):**

Before closing, save any important information:
1. Take screenshots of all DNS records
2. Export domain history (if available)
3. Save any SSL certificates (if purchased through Name.com)
4. Save billing history/receipts
5. Note renewal dates and prices for future reference

**Close Name.com account:**

1. **Log into:** Name.com
2. **Go to:** Account Settings
3. **Find:** "Close Account" or "Delete Account"
4. **Follow prompts:** Name.com may ask why you're leaving
5. **Confirm closure**

**Note:** Some registrars require contacting support to close accounts. If you don't see a self-service option, contact Name.com support.

**Cancel any subscriptions:**
- Domain privacy (if separately billed)
- Email forwarding
- Website hosting
- SSL certificates
- WHOIS privacy

**Final billing:**
- You may receive a pro-rated refund for unused prepaid services
- Check for any final invoices
- Update payment method if needed for final charges

---

## Domain Transfer Troubleshooting

### Transfer Rejected or Failed

**Symptoms:** Transfer doesn't complete, receive rejection email

**Common causes:**
- Domain is locked (Step 26)
- Wrong authorization code
- Domain transferred within last 60 days
- WHOIS contact email bounced
- Domain status prohibits transfer
- Expired payment method

**Solutions:**
1. Verify domain is unlocked at Name.com
2. Request new authorization code (codes expire)
3. Check domain registration date (must be >60 days old)
4. Verify WHOIS email is accessible
5. Check WHOIS status: `whois newartisans.com | grep Status`
6. Contact Cloudflare support if status shows transfer prohibitions

### Transfer Stuck in Pending

**Symptoms:** Transfer initiated but nothing happens for days

**Check:**
```bash
# Check current registrar
whois newartisans.com | grep Registrar

# Should still show Name.com during transfer
```

**Actions:**
1. Check email for approval requests (check spam folder)
2. Log into Name.com → Domain Transfers
3. Manually approve the transfer
4. Contact Name.com support if no pending transfer shown
5. Verify authorization code was entered correctly

### DNS Breaks During Transfer

**Symptoms:** Website/services stop working during transfer

**Cause:** This shouldn't happen if nameservers are already on Cloudflare

**Solutions:**
1. Verify nameservers in WHOIS: `dig newartisans.com NS`
2. Should still point to Cloudflare nameservers
3. Check DNS records in Cloudflare dashboard
4. If records missing, re-add them
5. Wait for DNS propagation (5-15 minutes)

### Can't Find Domain After Transfer

**Symptoms:** Transfer completes but domain doesn't appear in Cloudflare

**Check:**
1. Cloudflare dashboard → Domain Registration → Manage Domains
2. Check the correct Cloudflare account (if you have multiple)
3. Check email for transfer completion confirmation
4. Verify WHOIS shows Cloudflare as registrar

**If still not showing:**
1. Contact Cloudflare support with transfer confirmation email
2. Verify payment was processed successfully
3. Check for any error emails from Cloudflare

### Multiple Domains to Transfer

**If you have multiple domains at Name.com:**

**Recommended approach:**
1. Transfer one domain first (newartisans.com)
2. Verify it works completely
3. Then transfer remaining domains one at a time
4. Stagger transfers by a few days to avoid issues

**Bulk transfer:**
- Cloudflare supports bulk transfers
- Use "Import domains" feature
- Upload CSV with domains and auth codes
- All domains transfer simultaneously

**Important:** Ensure ALL DNS records are correct in Cloudflare before initiating bulk transfer.

---

## Cost Comparison

### Name.com Pricing (typical)
- .com domain: $12.99/year
- WHOIS privacy: $4.99/year (optional)
- **Total:** ~$17.98/year

### Cloudflare Registrar Pricing
- .com domain: $9.77/year (at-cost, no markup)
- WHOIS privacy: **Included free**
- DNS hosting: **Free**
- DDoS protection: **Free**
- Cloudflare Tunnel: **Free**
- **Total:** $9.77/year

**Annual savings:** ~$8.21/year per domain

**Plus:** Unified management, better security, included services

---

## Domain Transfer Checklist

Use this to track your domain transfer progress:

- [ ] Verified domain is >60 days old
- [ ] Unlocked domain at Name.com
- [ ] Obtained authorization code from Name.com
- [ ] Verified WHOIS contact email is accessible
- [ ] Initiated transfer at Cloudflare
- [ ] Entered authorization code correctly
- [ ] Paid for transfer/renewal at Cloudflare
- [ ] Approved transfer confirmation email from Cloudflare
- [ ] Approved (or waiting for auto-approval) at Name.com
- [ ] Received transfer completion email from Cloudflare
- [ ] Verified domain appears in Cloudflare Manage Domains
- [ ] Verified WHOIS shows Cloudflare as registrar
- [ ] Enabled auto-renew at Cloudflare
- [ ] Verified DNS records still working
- [ ] Verified all services still operational
- [ ] Exported backup records from Name.com
- [ ] Closed Name.com account (if no other domains)

---

## Troubleshooting

### DNS Not Propagating

**Symptoms:** Cloudflare shows "Pending nameserver update"

**Solutions:**
- Wait longer (up to 24 hours)
- Check Name.com: Ensure nameservers were saved correctly
- Use `dig newartisans.com NS` to check current nameservers
- Check https://www.whatsmydns.net for global propagation

### Tunnel Not Connecting

**Symptoms:** `n8n-webhook-enable` shows tunnel as inactive

**Check:**
```bash
# View tunnel logs
sudo journalctl -u cloudflared-tunnel-n8n-webhook -f

# Common issues:
# - Invalid credentials (check SOPS JSON format)
# - Firewall blocking outbound connections
# - Cloudflare account issue
```

**Solutions:**
- Verify credentials in `/run/secrets/cloudflared-n8n`
- Check credentials format (JSON must be valid)
- Test connectivity: `ping cloudflare.com`
- Check Cloudflare Zero Trust dashboard for tunnel status

### 502 Bad Gateway

**Symptoms:** `https://n8n.newartisans.com` returns 502 error

**Check:**
```bash
# Is internal nginx running?
systemctl status nginx

# Is n8n running?
systemctl status n8n

# Can nginx-n8n-webhook reach internal nginx?
curl -k https://n8n.vulcan.lan
```

**Solutions:**
- Start services: `systemctl start nginx n8n`
- Check nginx config: `nginx -t`
- Check nginx-n8n-webhook logs: `journalctl -u nginx-n8n-webhook -f`

### DDNS Not Updating

**Symptoms:** `home.newartisans.com` shows old IP after ISP change

**Check:**
```bash
# Test script manually
/usr/local/bin/cloudflare-ddns.sh

# Check OPNsense logs
# Navigate: System → Log Files → General

# Test API access
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

**Solutions:**
- Verify API token is valid (Step 18)
- Check Zone ID and Record ID are correct (Steps 19-20)
- Verify OPNsense trigger is configured
- Check script permissions: `chmod +x cloudflare-ddns.sh`

### N8N Webhooks Not Working

**Symptoms:** Workflow waits forever, webhook never triggers

**Check:**
```bash
# Is webhook proxy running?
n8n-webhook-status

# Test public endpoint
curl -I https://n8n.newartisans.com/webhook-test/<your-webhook-id>

# Check n8n logs
sudo journalctl -u n8n -f
```

**Solutions:**
- Enable webhook proxy: `n8n-webhook-enable`
- Verify WEBHOOK_URL is set: `systemctl cat n8n | grep WEBHOOK_URL`
- Check n8n workflow webhook URL matches public URL
- Test local first: `curl -k https://localhost:8443/webhook-test/...`

---

## Rollback Plan

If something goes wrong and you need to revert:

### Revert DNS to Name.com

1. **Log into Name.com**
2. **Change nameservers back to:**
   - `ns1.name.com`
   - `ns2.name.com`
   - `ns3.name.com`
   - `ns4.name.com`
3. **Wait for DNS propagation** (1-4 hours)
4. **Restore Name.com DNS records** (if any were modified)
5. **Re-enable Name.com DDNS** script on OPNsense

### Disable N8N Webhook Proxy

```bash
# Stop services
n8n-webhook-disable

# Optionally remove module from configuration
# Edit: /etc/nixos/hosts/vulcan/default.nix
# Comment out: ../../modules/services/nginx-n8n-webhook.nix
# Rebuild: sudo nixos-rebuild switch --flake '.#vulcan'
```

---

## Security Notes

### Credentials Security

**Stored securely:**
- ✅ Cloudflare tunnel credentials: Encrypted in SOPS
- ✅ Cloudflare API token: Scoped to DNS edit only
- ✅ N8N webhooks: HTTPS only, Cloudflare DDoS protection

**Best practices:**
- Rotate API tokens periodically
- Use scoped tokens (not Global API key)
- Monitor webhook access logs
- Only enable webhook proxy when needed

### Network Security

**Exposed services:**
- `n8n.newartisans.com`: Only exposed when manually enabled
- `home.newartisans.com`: Always exposed (as before)

**Protected by:**
- Cloudflare DDoS protection (orange cloud)
- Cloudflare WAF (optional, configure in dashboard)
- Nginx security headers (HSTS, XSS protection)
- Systemd service hardening (namespace restrictions, etc.)

**Not exposed:**
- Local n8n: Still only accessible via `n8n.vulcan.lan` internally
- Cloudflare Tunnel uses outbound connection (no inbound ports)

---

## Additional Resources

### Documentation

- **N8N Webhook Setup:** `/etc/nixos/docs/N8N_WEBHOOK_SETUP.md`
- **Cloudflare Tunnels:** https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/
- **Cloudflare API:** https://api.cloudflare.com/

### Helper Commands

All installed as part of the nginx-n8n-webhook module:

```bash
n8n-webhook-enable    # Start webhook proxy
n8n-webhook-disable   # Stop webhook proxy
n8n-webhook-status    # Show service status
n8n-webhook-logs      # Show recent logs
n8n-webhook-test      # Test connectivity
```

### Configuration Files

- **Nginx config:** `/etc/nginx/nginx-n8n-webhook.conf`
- **Service definition:** `/etc/nixos/modules/services/nginx-n8n-webhook.nix`
- **Cloudflare credentials:** `/run/secrets/cloudflared-n8n` (deployed from SOPS)
- **Logs:** `/var/log/nginx-n8n-webhook/`

---

## Completion Checklist

Use this to track your progress:

### DNS Migration
- [ ] Added domain to Cloudflare
- [ ] Reviewed DNS records
- [ ] Updated nameservers at Name.com
- [ ] Waited for DNS propagation (confirmed "Active")

### Cloudflare Tunnel
- [ ] Created tunnel "n8n-webhook"
- [ ] Obtained Account ID, Tunnel ID, Secret
- [ ] Configured public hostname (n8n.newartisans.com)
- [ ] Verified CNAME record created

### NixOS Configuration
- [ ] Added credentials to SOPS
- [ ] Ran `nixos-rebuild switch`
- [ ] Enabled webhook proxy
- [ ] Tested local endpoint (localhost:8443)
- [ ] Tested public endpoint (n8n.newartisans.com)
- [ ] Updated N8N WEBHOOK_URL environment variable

### DDNS Update
- [ ] Created Cloudflare API token
- [ ] Obtained Zone ID and Record ID
- [ ] Created/updated DDNS script
- [ ] Updated OPNsense configuration
- [ ] Tested DDNS update
- [ ] Verified IP in Cloudflare dashboard

### Final Verification
- [ ] Disabled webhook proxy (test manual control)
- [ ] Verified services don't auto-start on boot
- [ ] Imported Monday meeting workflow to n8n
- [ ] Tested workflow end-to-end

### Optional: Domain Transfer (Part 7)
- [ ] Unlocked domain at Name.com
- [ ] Obtained authorization code
- [ ] Initiated transfer at Cloudflare
- [ ] Approved transfer emails (Cloudflare + Name.com)
- [ ] Transfer completed (domain shows in Cloudflare)
- [ ] Enabled auto-renew at Cloudflare
- [ ] Exported/backed up Name.com records
- [ ] Closed Name.com account

**Congratulations!** Your n8n webhook proxy is now set up with Cloudflare protection and manual control.

**If you completed Part 7:** You've also fully migrated to Cloudflare as both your DNS provider and domain registrar!
