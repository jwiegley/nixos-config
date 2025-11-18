# iCloud Contact Syncing Setup for nasimw

This document provides complete instructions for adding iCloud contact synchronization for the `nasimw` user to the existing vdirsyncer configuration.

## Overview

**Current Setup (johnw):**
- Radicale server running at https://radicale.vulcan.lan (local CardDAV/CalDAV)
- vdirsyncer syncing contacts: Fastmail ↔ Radicale
- Sync interval: Every 15 minutes
- Conflict resolution: Radicale wins

**New Setup (nasimw):**
- Add second sync pair: iCloud ↔ Radicale
- Separate contact collections per user
- Independent sync schedules (same 15-minute timer)
- Conflict resolution: iCloud wins (authoritative source)

**Architecture After Changes:**
```
johnw:  Fastmail ↔ Radicale (johnw/contacts)
nasimw: iCloud   ↔ Radicale (nasimw/contacts)
```

---

## Prerequisites

### 1. Generate Apple App-Specific Password

Nasim must generate an app-specific password from their Apple ID account:

1. Go to https://appleid.apple.com
2. Sign in with Apple ID
3. Navigate to **Security** → **App-Specific Passwords**
4. Click **Generate Password** or **+** button
5. Enter a label (e.g., "vulcan-vdirsyncer")
6. Copy the generated password (format: `xxxx-xxxx-xxxx-xxxx`)

**Important Notes:**
- App-specific passwords are required when two-factor authentication is enabled
- The password can only be viewed once during generation - save it securely
- You can revoke and regenerate if needed

### 2. Information Needed

- **Apple ID Email:** `nasimw@example.com` (replace with actual email)
- **App-Specific Password:** Generated from step above
- **Radicale Username:** `nasimw` (will be created)
- **Radicale Password:** Generate a secure password for local Radicale access

---

## Step 1: Add Radicale User for nasimw

First, create a Radicale user account for nasimw.

```bash
# Generate bcrypt hash for Radicale password
# Choose a strong password when prompted
htpasswd -nB nasimw
```

This will output something like:
```
nasimw:$2y$05$abcdefghijklmnopqrstuvwxyz...
```

Add this line to the SOPS secrets file:

```bash
sops /etc/nixos/secrets.yaml
```

In the editor, locate the `radicale:` section and add nasimw's credentials to the `users-htpasswd` field:

```yaml
radicale:
  users-htpasswd: |
    johnw:$2y$05$existing_hash_here...
    nasimw:$2y$05$new_hash_here...
```

Save and exit (Ctrl+O, Enter, Ctrl+X for nano).

---

## Step 2: Add iCloud Credentials to SOPS

Add the following new secrets to `/etc/nixos/secrets.yaml`:

```bash
sops /etc/nixos/secrets.yaml
```

Add these entries under a new `vdirsyncer-nasimw:` section:

```yaml
vdirsyncer-nasimw:
  icloud-username: "nasimw@example.com"
  icloud-password: "xxxx-xxxx-xxxx-xxxx"  # App-specific password
  radicale-username: "nasimw"
  radicale-password: "password_generated_in_step1"
```

**Security Note:** These secrets are encrypted with SOPS and only readable by the vdirsyncer service user.

---

## Step 3: Update vdirsyncer Configuration

Edit `/etc/nixos/modules/services/vdirsyncer.nix` to add the nasimw/iCloud sync configuration.

### 3a. Add SOPS Secret Declarations

Add these after the existing Fastmail secrets (around line 35):

```nix
  # SOPS secrets for nasimw iCloud sync
  sops.secrets."vdirsyncer-nasimw/icloud-username" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-nasimw/icloud-password" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-nasimw/radicale-username" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };

  sops.secrets."vdirsyncer-nasimw/radicale-password" = {
    owner = "vdirsyncer";
    group = "vdirsyncer";
    mode = "0400";
    restartUnits = [ "vdirsyncer.service" ];
  };
```

### 3b. Add iCloud Sync Pair to Configuration

In the `environment.etc."vdirsyncer/config".text` section (around line 52), add the following after the existing Fastmail configuration:

```nix
  environment.etc."vdirsyncer/config".text = ''
    [general]
    status_path = "/var/lib/vdirsyncer/status/"

    # Contacts sync pair (johnw - existing)
    [pair contacts]
    a = "radicale_contacts"
    b = "fastmail_contacts"
    collections = [["personal", "contacts", "Default"]]
    metadata = ["displayname", "color"]
    conflict_resolution = "a wins"

    # Local Radicale storage (johnw - existing)
    [storage radicale_contacts]
    type = "carddav"
    url = "http://127.0.0.1:5232/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer/radicale-username".path}"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer/radicale-password".path}"]

    # Remote Fastmail storage (johnw - existing)
    [storage fastmail_contacts]
    type = "carddav"
    url = "https://carddav.fastmail.com/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer/fastmail-username".path}"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer/fastmail-password".path}"]

    # ===== NEW: nasimw iCloud Contacts Sync =====

    # Contacts sync pair (nasimw)
    [pair contacts_nasimw]
    a = "radicale_contacts_nasimw"
    b = "icloud_contacts_nasimw"
    collections = ["from b"]
    metadata = ["displayname", "color"]
    conflict_resolution = "b wins"

    # Local Radicale storage (nasimw)
    [storage radicale_contacts_nasimw]
    type = "carddav"
    url = "http://127.0.0.1:5232/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer-nasimw/radicale-username".path}"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer-nasimw/radicale-password".path}"]

    # Remote iCloud storage (nasimw)
    [storage icloud_contacts_nasimw]
    type = "carddav"
    url = "https://contacts.icloud.com/"
    username.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer-nasimw/icloud-username".path}"]
    password.fetch = ["command", "${pkgs.coreutils}/bin/cat", "${config.sops.secrets."vdirsyncer-nasimw/icloud-password".path}"]
  '';
```

**Key Configuration Details:**

- **`collections = ["from b"]`**: Auto-discover all contact collections from iCloud
- **`conflict_resolution = "b wins"`**: iCloud is authoritative (overwrites local changes)
- **Separate Radicale collections**: Each user has their own contact collection
- **Same sync timer**: Both pairs sync every 15 minutes

---

## Step 4: Apply Configuration

After making the changes, rebuild the NixOS configuration:

```bash
cd /etc/nixos

# Build and switch to new configuration
sudo nixos-rebuild switch --flake '.#vulcan'
```

**Expected Output:**
- vdirsyncer.service will restart
- New secrets will be deployed to `/run/secrets/`
- Initial discovery will run for iCloud contacts

---

## Step 5: Verify Configuration

### 5a. Check Secret Deployment

```bash
# Verify secrets are deployed
ls -la /run/secrets/ | grep vdirsyncer-nasimw

# Should show:
# -r-------- 1 vdirsyncer vdirsyncer ... vdirsyncer-nasimw-icloud-password
# -r-------- 1 vdirsyncer vdirsyncer ... vdirsyncer-nasimw-icloud-username
# -r-------- 1 vdirsyncer vdirsyncer ... vdirsyncer-nasimw-radicale-password
# -r-------- 1 vdirsyncer vdirsyncer ... vdirsyncer-nasimw-radicale-username
```

### 5b. Check Service Status

```bash
# Check vdirsyncer service status
sudo systemctl status vdirsyncer.service

# View recent logs
sudo journalctl -u vdirsyncer.service -n 50

# Check timer status
sudo systemctl status vdirsyncer.timer
```

### 5c. Manual Discovery and Sync

If needed, trigger discovery and sync manually:

```bash
# Become vdirsyncer user
sudo -u vdirsyncer bash

# Run discovery for iCloud
vdirsyncer --config /etc/vdirsyncer/config discover contacts_nasimw

# Run initial sync
vdirsyncer --config /etc/vdirsyncer/config sync contacts_nasimw

# Exit
exit
```

### 5d. Check vdirsyncer Status Dashboard

Open https://vdirsyncer.vulcan.lan in a browser to view:
- Sync status for both pairs (johnw and nasimw)
- Last sync times
- Error counts
- Collection information

### 5e. Verify Radicale Access

Test nasimw can access their contacts via Radicale:

1. Open https://radicale.vulcan.lan
2. Login with:
   - Username: `nasimw`
   - Password: (the Radicale password from Step 1)
3. Should see synced contacts from iCloud

---

## Accessing Contacts

### Via Radicale Web Interface

- URL: https://radicale.vulcan.lan
- Username: `nasimw`
- Password: Radicale password (from SOPS)

### Via CardDAV Client (iOS, Android, Desktop)

**Server URL:** `https://radicale.vulcan.lan/nasimw/`
**Username:** `nasimw`
**Password:** Radicale password

**Example iOS Setup:**
1. Settings → Contacts → Accounts → Add Account → Other
2. Add CardDAV Account
3. Server: `radicale.vulcan.lan`
4. User Name: `nasimw`
5. Password: (Radicale password)
6. Description: `Vulcan Contacts`
7. Use SSL: Yes

---

## Sync Behavior

### johnw (Fastmail → Radicale)
- **Direction:** Bidirectional
- **Conflict Resolution:** Radicale wins
- **Collections:** Single "personal" collection
- **Frequency:** Every 15 minutes

### nasimw (iCloud → Radicale)
- **Direction:** Bidirectional
- **Conflict Resolution:** iCloud wins (authoritative)
- **Collections:** Auto-discovered from iCloud
- **Frequency:** Every 15 minutes (shared timer)

**Note:** Both sync pairs run independently but on the same timer schedule.

---

## Troubleshooting

### Authentication Failures

**Symptom:** Logs show "401 Unauthorized" for iCloud

**Solutions:**
1. Verify app-specific password is correct in SOPS secrets
2. Check Apple ID email is accurate
3. Regenerate app-specific password if needed
4. Ensure two-factor authentication is enabled on Apple ID

```bash
# Check what vdirsyncer is using
sudo journalctl -u vdirsyncer.service | grep -i auth
```

### Sync Failures

**Symptom:** Contacts not syncing between iCloud and Radicale

**Solutions:**
1. Check vdirsyncer service logs:
   ```bash
   sudo journalctl -u vdirsyncer.service -f
   ```

2. Run manual sync with verbose output:
   ```bash
   sudo -u vdirsyncer vdirsyncer --config /etc/vdirsyncer/config sync -v contacts_nasimw
   ```

3. Clear sync state and re-discover:
   ```bash
   sudo systemctl stop vdirsyncer.timer
   sudo rm -rf /var/lib/vdirsyncer/status/contacts_nasimw*
   sudo -u vdirsyncer vdirsyncer --config /etc/vdirsyncer/config discover contacts_nasimw
   sudo -u vdirsyncer vdirsyncer --config /etc/vdirsyncer/config sync contacts_nasimw
   sudo systemctl start vdirsyncer.timer
   ```

### Radicale Access Issues

**Symptom:** Cannot login to Radicale as nasimw

**Solutions:**
1. Verify htpasswd entry was added correctly:
   ```bash
   # Check deployed htpasswd file (don't decrypt here, just verify it deployed)
   ls -la /run/secrets/radicale-users-htpasswd
   ```

2. Check Radicale logs:
   ```bash
   sudo journalctl -u radicale.service | grep nasimw
   ```

3. Regenerate htpasswd entry if needed (repeat Step 1)

### Discovery Issues

**Symptom:** vdirsyncer can't find iCloud contact collections

**Solutions:**
1. Verify iCloud credentials are correct
2. Check that contacts exist in iCloud (create one test contact if empty)
3. Run discovery manually:
   ```bash
   sudo -u vdirsyncer vdirsyncer --config /etc/vdirsyncer/config discover contacts_nasimw
   ```

### Network Issues

**Symptom:** Cannot connect to iCloud servers

**Solutions:**
1. Test connectivity:
   ```bash
   curl -I https://contacts.icloud.com/
   ```

2. Check firewall rules allow outbound HTTPS:
   ```bash
   sudo iptables -L OUTPUT -v -n | grep 443
   ```

3. Verify DNS resolution:
   ```bash
   nslookup contacts.icloud.com
   ```

---

## Monitoring

### Prometheus Metrics

The vdirsyncer-status exporter provides metrics for monitoring:

- **Endpoint:** http://127.0.0.1:8089/metrics
- **Metrics Prefix:** `vdirsyncer_`

View metrics in Grafana at https://grafana.vulcan.lan

### Status Dashboard

Visual status dashboard available at https://vdirsyncer.vulcan.lan shows:
- Sync pair status (both johnw and nasimw)
- Last sync timestamps
- Error counts per pair
- Collection details

### Alerts

Check `/etc/nixos/modules/monitoring/services/vdirsyncer-exporter.nix` for configured Prometheus alerts.

---

## Security Considerations

### Credential Storage

- All credentials stored in SOPS-encrypted `secrets.yaml`
- Secrets deployed to `/run/secrets/` with mode `0400` (read-only by owner)
- Only `vdirsyncer` user can read vdirsyncer secrets
- Private `.age` encryption keys never committed to git

### Service Hardening

The vdirsyncer service runs with extensive systemd hardening:
- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=strict`
- Restricted address families
- Namespace isolation

### Network Security

- Radicale only listens on localhost (127.0.0.1)
- External access only via Nginx reverse proxy with TLS
- TLS certificates from internal Step-CA
- All external CardDAV connections use HTTPS

---

## File Locations

| Purpose | Path |
|---------|------|
| vdirsyncer config | `/etc/vdirsyncer/config` |
| vdirsyncer state | `/var/lib/vdirsyncer/` |
| Radicale data | `/var/lib/radicale/collections/` |
| SOPS secrets | `/etc/nixos/secrets.yaml` |
| Deployed secrets | `/run/secrets/` |
| NixOS module | `/etc/nixos/modules/services/vdirsyncer.nix` |
| Status exporter | `/etc/nixos/scripts/vdirsyncer-status.py` |

---

## References

- **vdirsyncer Documentation:** https://vdirsyncer.pimutils.org/
- **Radicale Documentation:** https://radicale.org/
- **Apple ID Management:** https://appleid.apple.com
- **iCloud CardDAV URL:** https://contacts.icloud.com/
- **SOPS Documentation:** https://github.com/getsops/sops

---

## Rollback Plan

If issues arise, you can disable the nasimw sync by commenting out the new configuration in `/etc/nixos/modules/services/vdirsyncer.nix`:

1. Comment out the SOPS secret declarations for `vdirsyncer-nasimw/*`
2. Remove the nasimw pair and storage sections from the config
3. Rebuild: `sudo nixos-rebuild switch --flake '.#vulcan'`

The existing johnw/Fastmail sync will continue working unaffected.

---

## Next Steps After Setup

1. Configure nasimw's devices to sync with Radicale (see "Accessing Contacts" section)
2. Monitor initial sync in dashboard at https://vdirsyncer.vulcan.lan
3. Verify contacts appear correctly on all devices
4. Set up Grafana alerts for sync failures if needed
5. Document any device-specific setup quirks

---

**Document Version:** 1.0
**Last Updated:** 2025-11-15
**Author:** Claude Code (nixos skill)
