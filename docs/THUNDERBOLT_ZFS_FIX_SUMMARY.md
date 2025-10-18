# Thunderbolt ZFS Boot Fix - Summary

**Date:** 2025-10-18
**Status:** READY TO DEPLOY (requires reboot to test)

## Problem

PCI rescan service ran **too early** - before bolt.service (Thunderbolt authorization daemon) was ready, causing devices to appear but not be usable for ZFS import.

## Root Cause

```diff
- DefaultDependencies = false  (ran before system infrastructure)
- After = ["systemd-modules-load.service"]  (too early!)
+ DefaultDependencies = true   (proper boot phase)
+ After = ["systemd-udev-settle.service" "bolt.service" "basic.target"]
+ Requires = ["bolt.service"]  (hard dependency)
```

## Solution Applied

Updated `/etc/nixos/modules/storage/pci-rescan.nix` with proper systemd ordering:

### Key Changes

1. **Added bolt.service dependency**
   - `after = [ "bolt.service" ]` - Wait for daemon to start
   - `requires = [ "bolt.service" ]` - Hard dependency (fail if bolt fails)

2. **Added infrastructure dependencies**
   - `after = [ "basic.target" ]` - Ensures dbus, polkit, sockets ready
   - `after = [ "systemd-udev-settle.service" ]` - Initial udev events processed

3. **Enabled default dependencies**
   - `DefaultDependencies = true` - Runs in proper boot phase (after sysinit.target)

4. **Improved script logic**
   - Verify bolt daemon accessibility via D-Bus before rescan
   - Better error messages and device verification
   - Reduced total wait time (~20-50s vs 65s+)

## Boot Sequence (New)

```
basic.target (dbus + polkit ready)
  └─ bolt.service (Thunderbolt daemon)
      └─ thunderbolt-pci-rescan.service (PCI rescan + enrollment)
          └─ zfs-import-tank.service (import pool)
```

## Deploy Steps

```bash
# Build to verify
sudo nixos-rebuild build --flake '.#vulcan'

# Deploy
sudo nixos-rebuild switch --flake '.#vulcan'

# REBOOT REQUIRED to test boot ordering
sudo reboot
```

## Verification After Reboot

```bash
# Check service status
systemctl status thunderbolt-pci-rescan.service
systemctl status zfs-import-tank.service

# Verify pool is imported
zpool status tank

# Check boot logs
journalctl -b -u thunderbolt-pci-rescan.service
journalctl -b -u bolt.service
journalctl -b -u zfs-import-tank.service
```

## Expected Results

- ✅ thunderbolt-pci-rescan.service: active (exited)
- ✅ zfs-import-tank.service: active (exited)
- ✅ tank pool: ONLINE with all devices
- ✅ No emergency mode or failed services
- ✅ All services depending on /tank paths start successfully

## Files Modified

- `/etc/nixos/modules/storage/pci-rescan.nix` - Fixed systemd ordering
- `/etc/nixos/docs/THUNDERBOLT_ZFS_BOOT_ORDERING.md` - Complete documentation
- `/etc/nixos/docs/THUNDERBOLT_ZFS_FIX_SUMMARY.md` - This summary

## Rollback Plan

If boot fails:

1. Select previous generation in GRUB
2. Boot to working system
3. Review logs: `journalctl -b -1 -u thunderbolt-pci-rescan.service`
4. Report findings for further debugging

## References

- Complete documentation: `/etc/nixos/docs/THUNDERBOLT_ZFS_BOOT_ORDERING.md`
- Service configuration: `/etc/nixos/modules/storage/pci-rescan.nix`
- Previous attempts: `/etc/nixos/docs/ZFS_BOOT_FIX.md`
