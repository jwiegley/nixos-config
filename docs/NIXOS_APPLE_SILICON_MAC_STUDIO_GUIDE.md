# NixOS on M1 Max Mac Studio Installation Guide

**Date**: 2025-10-20
**Target Hardware**: M1 Max Mac Studio
**Project**: [nix-community/nixos-apple-silicon](https://github.com/nix-community/nixos-apple-silicon)
**Status**: Production-ready with some limitations

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Hardware Compatibility Overview](#hardware-compatibility-overview)
3. [Pre-Installation Preparation](#pre-installation-preparation)
4. [Installation Process](#installation-process)
5. [Post-Installation Configuration](#post-installation-configuration)
6. [Migrating Your Vulcan Configuration](#migrating-your-vulcan-configuration)
7. [Known Issues and Workarounds](#known-issues-and-workarounds)
8. [Troubleshooting](#troubleshooting)
9. [Community Resources](#community-resources)

---

## Executive Summary

**Can you run NixOS natively on M1 Max Mac Studio?** YES!

The nix-community/nixos-apple-silicon project provides a production-ready NixOS experience on Apple Silicon hardware, including the M1 Max Mac Studio. This uses the Asahi Linux kernel and bootloader for hardware enablement while providing a standard NixOS configuration experience.

### Key Points

- ✅ **Native NixOS**: Run actual NixOS, not a compatibility layer
- ✅ **Dual-boot**: Keep macOS alongside NixOS
- ✅ **GPU Acceleration**: Full OpenGL 4.6, Vulkan 1.3, OpenCL support
- ✅ **Most hardware works**: WiFi, Bluetooth, USB, audio, display
- ⚠️ **Some limitations**: Partial Thunderbolt, no Steam yet
- 🚀 **Active development**: Regular updates from nix-community

### Why This Instead of nix-darwin?

Unlike nix-darwin (which runs on macOS), this approach gives you:
- Full NixOS with systemd services
- Ability to reuse most of your existing vulcan configuration
- Native Linux environment for server workloads
- ZFS support (though different from x86_64 Linux)
- Container support via Docker/Podman

---

## Hardware Compatibility Overview

### ✅ What Works

| Component | Status | Notes |
|-----------|--------|-------|
| **CPU** | Fully supported | All M1 Max cores available |
| **GPU** | Fully supported | OpenGL 4.6, Vulkan 1.3, OpenCL conformant drivers |
| **RAM** | Fully supported | All memory accessible |
| **Display** | Fully supported | Including high refresh rates |
| **Audio** | Fully supported | Speakers and headphone jack work |
| **WiFi** | Fully supported | Full performance |
| **Bluetooth** | Fully supported | All protocols |
| **Ethernet** | Fully supported | 10Gb Ethernet works |
| **USB** | Fully supported | USB-A and USB-C ports |
| **NVMe SSD** | Fully supported | Full speed access |
| **Power Management** | Mostly working | CPU frequency scaling works |

### ⚠️ Partial Support

| Component | Status | Notes |
|-----------|--------|-------|
| **Thunderbolt** | Partial | USB-C works, Thunderbolt devices limited |
| **Video Decode** | Partial | Software decode works, hardware acceleration WIP |
| **Sleep/Wake** | Experimental | May have issues |

### ❌ Not Working

| Component | Status | Notes |
|-----------|--------|-------|
| **Steam** | Not working | x86 emulation issues with 16k pages |
| **DRM video** | Not working | No Widevine support |

---

## Pre-Installation Preparation

### 1. Backup Your Data

**CRITICAL**: Back up your Mac before proceeding!

```bash
# If using Time Machine
# Ensure a recent backup exists

# For critical data, also copy to external drive
```

### 2. Check macOS Version

Ensure macOS is updated for best firmware support:

```bash
# Check current version
sw_vers

# Should be macOS 13.5 or later for full hardware support
# Update via System Settings > Software Update if needed
```

### 3. Prepare Disk Space

You'll need at least **100GB free space** for a comfortable NixOS installation:

```bash
# Check available space
df -h

# Consider these allocations:
# - 60GB minimum for NixOS root
# - 40GB+ for /home
# - Additional space for your data
```

### 4. Download Installation Media

Download the latest NixOS Apple Silicon ISO:

```bash
# Get the latest release
# Visit: https://github.com/nix-community/nixos-apple-silicon/releases

# Download the ISO (example - check for latest version):
curl -LO https://github.com/nix-community/nixos-apple-silicon/releases/download/nixos-24.11/nixos-apple-silicon-24.11.iso

# Verify checksum (replace with actual checksum from release page)
sha256sum nixos-apple-silicon-24.11.iso
```

### 5. Create Installation USB

You'll need a USB drive with at least 8GB capacity:

```bash
# On macOS, identify your USB drive
diskutil list

# CAREFUL: Replace /dev/diskN with your USB drive
# This will ERASE the USB drive!
sudo dd if=nixos-apple-silicon-24.11.iso of=/dev/rdiskN bs=1m

# Eject when complete
diskutil eject /dev/diskN
```

### 6. Prepare for Reduced Security

NixOS requires booting with Reduced Security. This is safe and reversible.

---

## Installation Process

### Step 1: Boot into Recovery Mode

1. **Shut down** your Mac Studio completely
2. **Press and hold** the power button until "Loading startup options" appears
3. Click **Options** → **Continue**
4. Enter your **admin password** when prompted

### Step 2: Modify Security Policy

In Recovery Mode:

1. Open **Utilities** → **Startup Security Utility**
2. Select your disk
3. Click **Security Policy**
4. Choose **Reduced Security**
5. Check **"Allow user management of kernel extensions"**
6. Click **OK** and enter your password
7. **Restart** your Mac

### Step 3: Resize macOS Partition

Boot back into macOS normally:

```bash
# Check current disk layout
diskutil list

# Resize APFS container (example: shrink to 500GB, leaving rest for NixOS)
# Replace disk1 with your APFS container
sudo diskutil apfs resizeContainer disk1 500GB

# Verify the free space
diskutil list
```

### Step 4: Install Asahi Linux Bootloader

The NixOS installation uses Asahi Linux's bootloader:

```bash
# Run the Asahi installer
curl -L https://alx.sh | sh

# When prompted:
# 1. Choose "Install an OS"
# 2. Select the free space you created
# 3. Choose "UEFI environment only (m1n1 + U-Boot + ESP)"
# 4. Name it "NixOS"
```

### Step 5: Boot from USB Installer

1. **Insert** your NixOS USB drive
2. **Restart** your Mac
3. **Hold the power button** until boot options appear
4. Select the **USB drive**
5. You should see the NixOS installer boot

### Step 6: Install NixOS

Once in the NixOS installer:

```bash
# 1. Set up networking (WiFi if needed)
sudo systemctl start wpa_supplicant
wpa_cli

# In wpa_cli:
> add_network
> set_network 0 ssid "YourWiFiName"
> set_network 0 psk "YourWiFiPassword"
> enable_network 0
> quit

# 2. Partition the disk
# Identify the free space (usually nvme0n1)
lsblk

# Create partitions
sudo parted /dev/nvme0n1
(parted) mkpart primary ext4 <start> <end>  # For root
(parted) mkpart primary linux-swap <start> <end>  # Optional swap
(parted) quit

# 3. Format partitions
sudo mkfs.ext4 -L nixos /dev/nvme0n1pX  # Replace X with partition number
sudo mkswap -L swap /dev/nvme0n1pY  # If using swap

# 4. Mount filesystems
sudo mount /dev/disk/by-label/nixos /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/EFI /mnt/boot  # Mount the ESP created by Asahi
sudo swapon /dev/disk/by-label/swap  # If using swap

# 5. Generate initial configuration
sudo nixos-generate-config --root /mnt
```

### Step 7: Configure NixOS

Edit the configuration to include Apple Silicon support:

```bash
sudo nano /mnt/etc/nixos/configuration.nix
```

Add essential Apple Silicon configuration:

```nix
{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    # Import Apple Silicon module (this should be auto-detected)
  ];

  # Apple Silicon support
  hardware.asahi.enable = true;
  hardware.asahi.withRust = true;
  hardware.asahi.useExperimentalGPUDriver = true;
  hardware.asahi.experimentalGPUInstallMode = "replace";

  # Boot configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.kernelPackages = lib.mkDefault config.hardware.asahi.pkgs.linux-asahi;

  # Basic system configuration
  networking.hostName = "mac-studio-nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "America/Los_Angeles";

  # Enable the X11 windowing system
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # User account
  users.users.johnw = {
    isNormalUser = true;
    description = "John Wiegley";
    extraGroups = [ "wheel" "networkmanager" ];
  };

  # Allow unfree packages (needed for some firmware)
  nixpkgs.config.allowUnfree = true;

  # Essential packages
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    firefox
  ];

  # Enable sound
  hardware.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  system.stateVersion = "24.11";
}
```

### Step 8: Install NixOS

```bash
# Run the installation
sudo nixos-install

# Set root password when prompted
# Reboot when complete
sudo reboot
```

### Step 9: First Boot

On first boot:

1. **Hold the power button** to see boot options
2. Select **NixOS**
3. Log in with your user account
4. Verify hardware functionality:

```bash
# Check GPU acceleration
glxinfo | grep "OpenGL renderer"

# Check audio
speaker-test

# Check network
ip addr show
ping google.com
```

---

## Post-Installation Configuration

### Enable Flakes

Edit `/etc/nixos/configuration.nix`:

```nix
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
```

### Convert to Flake-based Configuration

Create `/etc/nixos/flake.nix`:

```nix
{
  description = "M1 Max Mac Studio NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-apple-silicon.url = "github:nix-community/nixos-apple-silicon";
  };

  outputs = { self, nixpkgs, nixos-apple-silicon, ... }: {
    nixosConfigurations.mac-studio = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        nixos-apple-silicon.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

### Install Development Tools

```nix
environment.systemPackages = with pkgs; [
  # Development
  vscode
  git
  docker
  podman

  # System tools
  htop
  btop
  tmux
  zsh

  # Your preferred tools
];
```

---

## Migrating Your Vulcan Configuration

### What Can Be Migrated

✅ **Directly Portable** (minimal changes):
- User packages and environment
- Shell configurations (zsh, bash)
- Git configuration
- Most systemd services (with minor path adjustments)
- Docker/Podman containers
- PostgreSQL configuration
- Prometheus/Grafana stack
- Home Assistant (may need architecture-specific packages)
- Nginx configurations
- SOPS secrets (with new keys)

⚠️ **Needs Modification**:
- Hardware-specific configurations (different from x86_64)
- ZFS configuration (if you choose to use ZFS on Apple Silicon)
- Network interface names (different on ARM)
- Some container images (need ARM64 versions)
- Boot configuration (completely different)

❌ **Cannot Migrate**:
- x86_64-specific packages
- Hardware-specific modules (nixos-hardware.nixosModules.apple-t2)
- LUKS encryption (use FileVault or native encryption)
- Some proprietary software without ARM support

### Migration Strategy

#### Phase 1: Core System Setup

1. **Start with minimal configuration** - Get basic system working
2. **Test hardware functionality** - Ensure GPU, audio, network work
3. **Set up development environment** - Install essential tools

#### Phase 2: Service Migration

Migrate services incrementally:

```nix
# Example: Migrate PostgreSQL service
services.postgresql = {
  enable = true;
  package = pkgs.postgresql_17;  # ARM64 version
  # Rest of config remains the same
};
```

#### Phase 3: Container Migration

Update container configurations for ARM64:

```nix
virtualisation.podman = {
  enable = true;
  dockerCompat = true;
  # Container configs mostly unchanged
  # But ensure images have ARM64 versions
};
```

#### Phase 4: Data Migration

Options for migrating data from vulcan:

1. **Network transfer** (recommended):
   ```bash
   # From vulcan
   rsync -avz /tank/Documents/ mac-studio:/home/johnw/Documents/
   ```

2. **External drive**:
   - Format as exFAT for cross-platform compatibility
   - Copy data from vulcan
   - Copy to Mac Studio

3. **Keep vulcan running**:
   - Access services remotely
   - Gradually migrate workloads

### Example Migration: Core Services

Create a modular structure similar to vulcan:

```
/etc/nixos/
├── flake.nix
├── configuration.nix
├── hardware-configuration.nix
└── modules/
    ├── services/
    │   ├── databases.nix      # PostgreSQL, Redis
    │   ├── monitoring.nix      # Prometheus, Grafana
    │   ├── web.nix            # Nginx
    │   └── containers.nix      # Podman/Docker
    └── users/
        └── johnw.nix           # User configuration
```

---

## Known Issues and Workarounds

### Issue 1: Thunderbolt Devices Not Recognized

**Problem**: Thunderbolt devices may not work properly.

**Workaround**: Use USB-C mode (most devices support both):
```bash
# Check connected devices
lsusb
# Thunderbolt support is being improved in newer kernels
```

### Issue 2: High Battery Drain (MacBooks)

**Problem**: Power management not fully optimized (less relevant for Mac Studio).

**Workaround**: For Mac Studio, this primarily affects sleep states:
```nix
# Disable sleep if experiencing issues
systemd.targets.sleep.enable = false;
systemd.targets.suspend.enable = false;
```

### Issue 3: Steam/x86 Games Don't Work

**Problem**: Apple Silicon uses 16K page size, incompatible with x86 emulation.

**Current Status**: muvm/FEX development ongoing, not yet ready for NixOS.

**Alternative**: Use native ARM games or cloud gaming services.

### Issue 4: No Hardware Video Acceleration

**Problem**: Hardware video decode not yet implemented.

**Workaround**: Software decoding works fine for most content:
```nix
# Use mpv with software decoding
programs.mpv = {
  enable = true;
  config = {
    hwdec = "no";
  };
};
```

### Issue 5: External Display Issues

**Problem**: Some displays may not work at full resolution.

**Workaround**: Use different cable or port:
```bash
# Check available outputs
xrandr

# Manually set resolution if needed
xrandr --output HDMI-1 --mode 3840x2160 --rate 60
```

---

## Troubleshooting

### Common Installation Errors

#### Error -69519: "Target disk is too small for this operation"

This error occurs during the Asahi installer partition creation phase.

**Root Causes:**
1. APFS filesystem inconsistencies (orphan inodes, metadata corruption)
2. APFS snapshots consuming "free" space invisibly
3. Insufficient contiguous free space after target partition

**Solution Steps:**

**Step 1: Check Current Disk Layout**
```bash
# List all partitions
diskutil list

# Check APFS container details
diskutil apfs list

# List APFS snapshots
sudo diskutil apfs listSnapshots /
```

**Step 2: Clean Up APFS Snapshots**

Time Machine local snapshots often consume free space invisibly, preventing partition operations:

```bash
# List snapshots and their UUIDs
sudo diskutil apfs listSnapshots /

# Delete individual snapshot by UUID
sudo diskutil apfs deleteSnapshot / -uuid <UUID>

# OR: Thin Time Machine snapshots (request 100GB cleanup)
tmutil thinlocalsnapshots / $(echo "100 * 1000000000" | bc) 2

# For aggressive cleanup (request 2TB to remove ALL local snapshots)
tmutil thinlocalsnapshots / 2000000000000 2

# Verify free space after cleanup
diskutil apfs list
```

**Step 3: Repair APFS Filesystem**

Standard Disk Utility cannot fix deep APFS issues. Use Recovery Mode:

1. **Boot into Recovery Mode:**
   - Restart Mac Studio
   - Hold power button until "Loading startup options" appears
   - Select "Options" → "Continue"

2. **Open Terminal** (from Utilities menu)

3. **Unlock encrypted volume** (if using FileVault):
   ```bash
   diskutil apfs list
   # Note the volume identifier (e.g., disk3s1)
   diskutil apfs unlockVolume /dev/disk3s1
   ```

4. **Run filesystem check and repair:**
   ```bash
   # For main APFS volume (adjust disk identifier as needed)
   /sbin/fsck_apfs -y /dev/disk3s1

   # Or for the entire container
   /sbin/fsck_apfs -y /dev/disk3
   ```

5. **Reboot** after successful repair

**Step 4: Resize APFS Container (if needed)**

If free space exists but isn't recognized:

```bash
# Resize container to reclaim all available space
# (0 means "use all available space")
sudo diskutil apfs resizeContainer disk3 0

# Or manually specify size to leave space for Linux
# Example: resize to 500GB to free up remaining space
sudo diskutil apfs resizeContainer disk3 500g
```

**Step 5: Retry Asahi Installer**

After completing the above steps:

```bash
curl https://alx.sh | sh
```

### Boot Issues

**Cannot boot into NixOS:**

1. Boot into macOS Recovery (hold power button)
2. Open Terminal
3. Check boot entries:
   ```bash
   bless --info /
   ```
4. Re-run Asahi installer if needed

**Kernel panic on boot:**

- Boot with previous generation (select in boot menu)
- Check for configuration errors:
  ```bash
  nixos-rebuild build --flake .#mac-studio
  ```

### Hardware Not Working

**WiFi not connecting:**

```bash
# Restart NetworkManager
sudo systemctl restart NetworkManager

# Check for errors
journalctl -u NetworkManager -b
```

**No sound:**

```bash
# Check audio devices
pactl list sinks

# Restart PipeWire
systemctl --user restart pipewire pipewire-pulse
```

**GPU not accelerated:**

```bash
# Verify Mesa drivers
glxinfo | grep "OpenGL renderer"
# Should show "Apple M1 Max" or similar

# Check Vulkan
vulkaninfo | grep "deviceName"
```

### System Updates

**Updating NixOS:**

```bash
# Update flake inputs
nix flake update

# Rebuild system
sudo nixos-rebuild switch --flake .#mac-studio

# If issues, rollback:
sudo nixos-rebuild switch --rollback
```

---

## Performance Expectations

### What to Expect

| Workload | Performance | Notes |
|----------|-------------|-------|
| **CPU tasks** | Native speed | All cores available |
| **GPU compute** | Excellent | OpenCL works great |
| **3D graphics** | Very good | OpenGL 4.6, Vulkan 1.3 |
| **Video playback** | Good | Software decode is fast |
| **Compilation** | Excellent | Faster than most x86_64 systems |
| **Virtualization** | Good | KVM works but limited |
| **Networking** | Full speed | 10Gb Ethernet works |

### Benchmark Results

```bash
# CPU benchmark
sysbench cpu --threads=20 run

# Disk benchmark
hdparm -tT /dev/nvme0n1

# GPU benchmark
glmark2
vkcube  # Vulkan test
```

---

## Community Resources

### Official Resources

- **GitHub Repository**: https://github.com/nix-community/nixos-apple-silicon
- **Documentation**: https://github.com/nix-community/nixos-apple-silicon/tree/main/docs
- **Issue Tracker**: https://github.com/nix-community/nixos-apple-silicon/issues
- **Releases**: https://github.com/nix-community/nixos-apple-silicon/releases

### Asahi Linux Resources

- **Asahi Linux Site**: https://asahilinux.org/
- **Feature Support Matrix**: https://github.com/AsahiLinux/docs/wiki/Feature-Support
- **Asahi Blog**: https://asahilinux.org/blog/ (GPU updates, etc.)

### Community Support

- **NixOS Discourse**: https://discourse.nixos.org/
  - Tag: `apple-silicon`
- **NixOS Wiki**: https://wiki.nixos.org/wiki/NixOS_on_ARM/Apple_Silicon_Macs
- **Matrix Chat**: #asahi:matrix.org
- **IRC**: #asahi on OFTC

### Useful Blogs/Guides

- Yusef Napora's NixOS Asahi Experience: https://yusef.napora.org/blog/nixos-asahi/
- NixOS on Apple Silicon (various authors): Search for recent posts

---

## Maintenance and Updates

### Regular Maintenance

```bash
# Weekly: Update system
nix flake update
sudo nixos-rebuild switch --flake .#mac-studio

# Monthly: Garbage collection
nix-collect-garbage -d
sudo nix-collect-garbage -d

# Quarterly: Check for firmware updates
# Boot into macOS and check for updates
```

### Firmware Updates

**Important**: Firmware updates must be done from macOS:

1. Boot into macOS
2. Check System Settings → Software Update
3. Install any firmware updates
4. Reboot back to NixOS

### Kernel Updates

The Asahi kernel is updated regularly:

```nix
# In flake.nix, update nixos-apple-silicon input
nix flake lock --update-input nixos-apple-silicon

# Rebuild with new kernel
sudo nixos-rebuild switch --flake .#mac-studio
```

---

## Dual-Boot Best Practices

### Switching Between OSes

**Boot to macOS**:
- Hold power button on startup
- Select macOS

**Boot to NixOS**:
- Hold power button on startup
- Select NixOS

### Set Default OS

From macOS:
```bash
sudo bless --setBoot --mount /Volumes/NixOS
```

From NixOS (to set macOS as default):
```bash
# This requires additional configuration
# Generally easier to set from macOS
```

### Shared Data

**Option 1**: ExFAT partition (readable by both)

```bash
# Create shared partition during installation
mkfs.exfat -L Shared /dev/nvme0n1pX
```

**Option 2**: Network sharing
- Run Samba on NixOS
- Access from macOS via SMB

---

## Recovery Procedures

### If NixOS Won't Boot

1. **Boot macOS Recovery**:
   - Hold power button → Options

2. **Mount NixOS partition from macOS**:
   ```bash
   # Install ext4 support (from macOS)
   brew install --cask macfuse
   brew install ext4fuse
   ```

3. **Chroot from USB installer**:
   - Boot NixOS USB
   - Mount partitions
   - Chroot and fix configuration

### Complete Reinstallation

If needed, you can reinstall without affecting macOS:

1. Boot Asahi installer
2. Delete NixOS partition
3. Reinstall following this guide

### Removing NixOS Completely

To remove NixOS and reclaim space for macOS:

1. Boot into macOS Recovery
2. Use Disk Utility to delete NixOS partitions
3. Expand macOS partition
4. Remove boot entry:
   ```bash
   sudo bless --unbless /Volumes/NixOS
   ```

---

## Migration Checklist

Before starting migration from vulcan:

- [ ] **Backup vulcan configuration** to git
- [ ] **Document** service dependencies and configurations
- [ ] **Export** any databases that need migration
- [ ] **List** all critical services and their requirements
- [ ] **Check** which packages have ARM64 versions
- [ ] **Plan** network topology (how Mac Studio will integrate)
- [ ] **Decide** on data migration strategy
- [ ] **Test** backup restoration procedures
- [ ] **Create** rollback plan

---

## FAQ

### Q: Can I run x86_64 Docker containers?

**A**: Not directly. Use ARM64 images or rebuild for ARM64. Some images support multi-arch.

### Q: Will my NixOS configuration from vulcan work?

**A**: Most of it will work with minor modifications. Main changes needed:
- Hardware configuration (obviously)
- Architecture-specific packages
- Network interface names
- Boot configuration

### Q: Can I use this as a server like vulcan?

**A**: Yes! Mac Studio is excellent for server workloads. Consider:
- It's very power-efficient
- Quiet operation
- Powerful CPU/GPU
- Reliable hardware

### Q: What about ZFS?

**A**: ZFS works on ARM64 Linux but:
- Different from macOS APFS
- No boot from ZFS root (use ext4 for root)
- Can use ZFS for data volumes

### Q: Is this stable enough for production?

**A**: Yes, for most workloads:
- Many users run this as daily driver
- Server workloads are very stable
- GPU acceleration is production-ready
- Active development and support

### Q: Can I contribute?

**A**: Yes! The project welcomes contributions:
- Report issues on GitHub
- Submit PRs for fixes/improvements
- Share your configuration examples
- Help document edge cases

---

## Summary

Installing NixOS on your M1 Max Mac Studio is a viable and powerful option that will allow you to:

1. **Run real NixOS** with systemd and full Linux environment
2. **Reuse most of your vulcan configuration** with minor changes
3. **Keep macOS** for compatibility when needed (dual-boot)
4. **Leverage powerful hardware** with great Linux support
5. **Join an active community** working on Apple Silicon Linux

The installation process is straightforward, hardware support is excellent, and the system is stable enough for daily use and server workloads.

**Next Steps**:
1. Back up your data
2. Download the NixOS Apple Silicon ISO
3. Follow this guide step-by-step
4. Migrate your configuration gradually
5. Enjoy NixOS on powerful Apple Silicon hardware!

---

## Quick Command Reference

```bash
# System Management
sudo nixos-rebuild switch --flake .#mac-studio
nix flake update
nix-collect-garbage -d

# Hardware Verification
glxinfo | grep renderer     # Check GPU
pactl list sinks            # Check audio
ip addr show                # Check network
lsusb                       # List USB devices

# Troubleshooting
journalctl -b               # Check boot logs
journalctl -u NetworkManager # Check network logs
systemctl status            # Check services
dmesg                       # Kernel messages

# Performance
htop                        # CPU/memory monitor
iotop                       # Disk I/O monitor
powertop                    # Power usage
```

---

**Document Version**: 1.0
**Last Updated**: 2025-10-20
**Maintainer**: John Wiegley
**Status**: Ready for implementation