# Windows 11 ARM Container Setup

## Overview

Windows 11 ARM running in a container using `dockurr/windows-arm` with KVM acceleration on Apple Silicon (M1 Max).

**Purpose:** Running CTA software (CTA1.1_DB1.8-1-Nov-2016-CTASetup_Full.exe) in a persistent Windows 11 environment.

## Container Specifications

- **Image:** `docker.io/dockurr/windows-arm:latest`
- **Windows Version:** Windows 11 ARM Pro
- **CPU Cores:** 4 (cores 2-9 on big.LITTLE architecture)
- **RAM:** 8GB
- **Disk:** 128GB virtual disk
- **Acceleration:** KVM (via /dev/kvm)
- **Storage Location:** `/var/lib/windows` (ext4 filesystem)
- **Auto-start:** No (manual start to conserve memory)

## Access Methods

### Web Interface (noVNC)

**Local Access:**
- URL: `http://localhost:8006`
- Interface: Browser-based VNC viewer
- Quality: Suitable for installation and basic use
- Features: Keyboard, mouse support

**Network Access via Nginx (RECOMMENDED):**
- URL: `https://windows.vulcan.lan`
- SSL: Step-CA generated certificate (auto-renewed)
- Access: From any device on the local network
- **This is the primary access method** - use this URL from your browser

**Browser Requirements:**
- Modern browser with WebSocket support
- JavaScript enabled
- Recommended: Chrome, Firefox, Safari

### RDP (Remote Desktop Protocol)

**Connection Details:**
- Host: `localhost` (or `vulcan.lan` from network)
- Port: `3389`
- Protocol: RDP (TCP + UDP)
- Credentials: Default user `Docker` / password `admin`

**RDP Clients:**
- **Windows:** Built-in Remote Desktop Connection (`mstsc`)
- **macOS:** Microsoft Remote Desktop (App Store)
- **Linux:** Remmina, FreeRDP (`xfreerdp /v:localhost:3389`)
- **iOS/Android:** Microsoft Remote Desktop apps

**RDP provides better performance than web interface:**
- Lower latency
- Better display quality
- Clipboard sharing
- Audio support

## File Sharing

### Shared Folder

**Location in Container:** Desktop folder named `Shared`
**Host Location:** `/var/lib/windows/shared/`

**Current Contents:**
- `CTA1.1_DB1.8-1-Nov-2016-CTASetup_Full.exe` (32 MB)

**Usage:**
1. Access Windows via web interface or RDP
2. Open `Shared` folder on Desktop
3. Run `CTA1.1_DB1.8-1-Nov-2016-CTASetup_Full.exe`
4. Follow installation wizard

**Adding More Files:**
```bash
# Copy files to shared folder
sudo cp /path/to/file /var/lib/windows/shared/

# Ensure correct permissions
sudo chown root:root /var/lib/windows/shared/*
sudo chmod 644 /var/lib/windows/shared/*
```

Files appear immediately in Windows without restart.

## Service Management

### On-Demand Usage (Memory Conservation)

The Windows container uses **8GB of RAM** and is configured for **manual start** to conserve system resources. Start it only when you need to use Windows.

**Quick Start/Stop Commands:**

```bash
# Start Windows container
windows-start

# Stop Windows container
windows-stop

# Check if running
windows-status

# View live logs
windows-logs

# Restart container
windows-restart
```

**Wait Time:** After starting, Windows takes ~2-3 minutes to boot. Access via `https://windows.vulcan.lan` once ready.

**Automatic Shutdown:** Consider stopping the container when done to free 8GB RAM for other services.

### SystemD Commands (Alternative)

If shell aliases aren't available, use systemctl directly:

```bash
# Check container status
sudo systemctl status windows11.service

# View logs (live)
sudo journalctl -u windows11.service -f

# Restart Windows container
sudo systemctl restart windows11.service

# Stop Windows container
sudo systemctl stop windows11.service

# Start Windows container
sudo systemctl start windows11.service
```

### Container Commands

```bash
# List running containers
podman ps

# Access container shell
podman exec -it windows11 bash

# View Windows console output
podman logs windows11
```

## Windows Installation Process

### First Boot

1. Windows 11 ARM ISO downloads automatically (7.3 GB)
2. QEMU creates 128GB virtual disk
3. Windows boots from ISO and starts installation
4. Installation is automatic (no user input required)
5. Takes 15-30 minutes depending on CPU speed

### Installation Progress

**Monitor via logs:**
```bash
sudo journalctl -u windows11.service -f
```

**Monitor via web interface:**
1. Open `http://localhost:8006`
2. Watch installation progress
3. System will reboot several times

### Post-Installation

After Windows completes installation:
- Default user: `Docker`
- Default password: `admin`
- Windows updates may install automatically
- Desktop appears with `Shared` folder

## Installing CTA Software

### Method 1: Via Web Interface

1. Open `http://localhost:8006` in browser
2. Log in to Windows (user: `Docker`, password: `admin`)
3. Open `Shared` folder on Desktop
4. Double-click `CTA1.1_DB1.8-1-Nov-2016-CTASetup_Full.exe`
5. Follow installation wizard
6. Software will be installed persistently

### Method 2: Via RDP

1. Connect with RDP client to `localhost:3389`
2. Log in to Windows (user: `Docker`, password: `admin`)
3. Navigate to `Shared` folder on Desktop
4. Run `CTA1.1_DB1.8-1-Nov-2016-CTASetup_Full.exe`
5. Complete installation

## Persistence

### What Persists

- **Windows installation** - Full OS state saved
- **Installed applications** - CTA and other software
- **User data** - Documents, settings, registry
- **Disk changes** - All writes to C: drive
- **Shared folder** - Files in `/var/lib/windows/shared/`

### What Doesn't Persist

- Container filesystem (except `/storage` mount)
- Temporary files in container `/tmp`
- Network configuration (regenerated on start)

### Backup

**Manual Backup:**
```bash
# Stop container
sudo systemctl stop windows11.service

# Backup Windows data
sudo tar -czf windows-backup-$(date +%Y%m%d).tar.gz /var/lib/windows/

# Restart container
sudo systemctl start windows11.service
```

**Automatic Backup (via Restic):**
- `/var/lib/windows/` is NOT currently in Restic backups
- To add: Update `/etc/nixos/modules/storage/backups.nix`

## Storage Details

### Disk Layout

```
/var/lib/windows/
├── data.img          # 128GB Windows C: drive (sparse file)
├── win11arm64.iso    # 7.3GB Windows 11 ARM installer
├── windows.rom       # 64MB UEFI firmware (read-only)
├── windows.vars      # 64MB UEFI variables
├── windows.logo      # 64MB boot logo
├── windows.base      # Version marker
├── windows.mac       # MAC address
├── windows.ver       # Version number
└── shared/           # Files shared with Windows
    └── CTA1.1_DB1.8-1-Nov-2016-CTASetup_Full.exe
```

### Disk Usage

- **Initial:** ~7.5 GB (ISO + empty disk)
- **After Windows install:** ~15-20 GB
- **After CTA install:** ~20-25 GB
- **Maximum:** 128 GB (virtual disk size)

### File Permissions

```bash
# Windows data owned by root
sudo chown -R root:root /var/lib/windows/

# Shared folder readable by all
sudo chmod 755 /var/lib/windows/shared/
sudo chmod 644 /var/lib/windows/shared/*
```

## Networking

### Port Mappings

- **8006:** Web interface (noVNC) - localhost only
- **3389:** RDP - localhost only

### Firewall

```bash
# Podman bridge network allows container access
# No external ports exposed (security)

# To allow external RDP access (NOT recommended):
# sudo firewall-cmd --add-port=3389/tcp --permanent
```

### DNS Resolution

Container uses Podman default DNS:
- Forwards to host DNS resolver
- Can resolve `.lan` domains
- Internal DNS: `dnsmasq` on `10.88.0.1`

## Troubleshooting

### Container Won't Start

**Check logs:**
```bash
sudo journalctl -u windows11.service -n 100
```

**Common Issues:**
1. **KVM not available:** Check `/dev/kvm` exists
2. **Storage full:** Check disk space with `df -h /var/lib`
3. **Port conflict:** Check if 8006 or 3389 already in use
4. **Podman issue:** Restart with `sudo systemctl restart podman`

### Windows Not Booting

**Symptoms:** Web interface shows black screen

**Solutions:**
1. Wait 2-3 minutes (UEFI/BIOS initialization)
2. Check QEMU logs: `podman logs windows11`
3. Restart container: `sudo systemctl restart windows11.service`
4. If corrupted, delete `/var/lib/windows/data.img` and restart (reinstall)

### Web Interface Not Loading

**Check nginx:**
```bash
sudo systemctl status nginx
curl http://localhost:8006
```

**Fix nginx:**
```bash
sudo systemctl restart nginx
```

### RDP Not Working

**Test port:**
```bash
ss -tlnp | grep 3389
```

**Test connection:**
```bash
nc -zv localhost 3389
```

**Restart container:**
```bash
sudo systemctl restart windows11.service
```

### Performance Issues

**Check resource usage:**
```bash
# CPU and memory
systemctl status windows11.service

# Detailed stats
podman stats windows11
```

**Increase resources:**
Edit `/etc/nixos/modules/containers/windows11-quadlet.nix`:
```nix
CPU_CORES = "8";  # Increase CPUs
RAM_SIZE = "16G";  # Increase RAM
```

Rebuild: `sudo nixos-rebuild switch --flake '.#vulcan'`

## Configuration

### Module Location

**File:** `/etc/nixos/modules/containers/windows11-quadlet.nix`

**Configuration Format:** NixOS Quadlet container definition

**Editing:**
```bash
# Edit module
vim /etc/nixos/modules/containers/windows11-quadlet.nix

# Add to git
git add modules/containers/windows11-quadlet.nix

# Rebuild system
sudo nixos-rebuild switch --flake '.#vulcan'
```

### Environment Variables

Available in `containerConfig.environments`:

- `VERSION`: Windows version (`11`, `10`, etc.)
- `CPU_CORES`: Number of CPU cores
- `RAM_SIZE`: RAM allocation (e.g., `8G`)
- `DISK_SIZE`: Virtual disk size (e.g., `128G`)
- `USERNAME`: Windows username (default: `Docker`)
- `PASSWORD`: Windows password (default: `admin`)
- `LANGUAGE`: Installation language (default: `English`)

### Advanced Options

**Custom ports:**
```nix
environments = {
  USER_PORTS = "5000,8080";  # Forward additional ports
};
```

**Manual installation:**
```nix
environments = {
  MANUAL = "Y";  # Disable automatic installation
};
```

**Different Windows version:**
```nix
environments = {
  VERSION = "10";  # Windows 10 instead of 11
};
```

## Architecture Notes

### ARM64 Compatibility

- **Host CPU:** Apple Silicon M1 Max (ARM64/aarch64)
- **Windows:** Windows 11 ARM64 native
- **x86/x64 Apps:** Windows 11 ARM includes x86/x64 emulation
- **CTA Software:** Likely x86/x64, will run via emulation
- **Performance:** Native ARM apps run at full speed, x86 apps slower

### KVM Acceleration

- **Hardware:** /dev/kvm device
- **Virtualization:** ARM Virtualization Extensions
- **Performance:** Near-native speed for ARM code
- **Support:** Asahi Linux provides full KVM support

### Storage Backend

- **Filesystem:** ext4 (`/var/lib` is on root ext4 partition)
- **Why not ZFS:** ZFS has issues with QEMU O_DIRECT
- **Performance:** ext4 provides excellent performance for VMs
- **Snapshots:** Use tar/rsync for backups instead of ZFS snapshots

## Security Considerations

### Network Isolation

- **Ports:** Bound to `127.0.0.1` only (localhost)
- **No external access** without SSH tunnel or firewall rules
- **Container network:** Isolated Podman bridge network
- **NAT:** Windows has outbound internet access

### SSH Tunnel for Remote Access

**From remote machine:**
```bash
# Forward web interface
ssh -L 8006:localhost:8006 vulcan.lan

# Then open http://localhost:8006 on remote machine
```

```bash
# Forward RDP
ssh -L 3389:localhost:3389 vulcan.lan

# Then connect RDP client to localhost:3389
```

### Windows Security

- **Firewall:** Windows Defender Firewall enabled
- **Updates:** Windows Update active
- **Antivirus:** Windows Defender active
- **Account:** Standard user `Docker` (not administrator)

**To elevate to admin:**
1. Right-click application
2. "Run as administrator"
3. Enter password: `admin`

## Maintenance

### Regular Tasks

**Weekly:**
- Check Windows updates
- Check disk space: `df -h /var/lib`
- Review logs for errors

**Monthly:**
- Backup Windows data
- Clean up unused files in Windows
- Update container image (if new version available)

### Update Container Image

```bash
# Pull latest image
podman pull docker.io/dockurr/windows-arm:latest

# Restart container (will use new image)
sudo systemctl restart windows11.service
```

**Note:** Windows installation persists across image updates.

### Rebuild System

**After editing module:**
```bash
cd /etc/nixos
git add modules/containers/windows11-quadlet.nix
sudo nixos-rebuild switch --flake '.#vulcan'
```

## Support and References

- **dockur/windows-arm:** https://github.com/dockur/windows-arm
- **QEMU Documentation:** https://www.qemu.org/docs/master/
- **Podman Quadlet:** https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- **Windows 11 ARM:** https://support.microsoft.com/en-us/windows

## Quick Reference

```bash
# Access web interface
xdg-open http://localhost:8006

# Connect via RDP
xfreerdp /v:localhost:3389 /u:Docker /p:admin

# Service status
sudo systemctl status windows11.service

# View logs
sudo journalctl -u windows11.service -f

# Restart Windows
sudo systemctl restart windows11.service

# Add files to shared folder
sudo cp /path/to/file /var/lib/windows/shared/

# Backup Windows data
sudo systemctl stop windows11.service
sudo tar -czf windows-backup.tar.gz /var/lib/windows/
sudo systemctl start windows11.service
```
