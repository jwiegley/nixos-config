# ZFS Pool Import Boot Failure - Root Cause and Solution

**Date:** 2025-10-17
**Issue:** ZFS pool "tank" failed to import at boot, causing cascading service failures
**Status:** FIXED (requires reboot to test)

## Problem Summary

The ZFS pool "tank" is located on external Thunderbolt storage devices. At boot, the pool failed to import because:

1. **Thunderbolt devices require PCI bus enumeration** - The devices don't appear to the system until a PCI bus rescan is triggered
2. **Original workaround timing issue** - The original `boot.postBootCommands` approach ran PCI rescan AFTER systemd started services
3. **Cascading failures** - Services depending on /tank/* paths failed when the pool wasn't available

## Root Cause Analysis

### Why Previous Attempts Failed

#### Attempt 1: Separate systemd service (commit 089ae9e)
**What I did:**
- Created `pci-rescan-thunderbolt.service` with:
  ```nix
  wantedBy = [ "zfs-import.target" ];
  before = [ "zfs-import-tank.service" "zfs-import.target" ];
  ```

**Why it failed:**
- Created systemd ordering cycles through the boot critical path:
  ```
  sysinit.target → local-fs.target → zfs-mount.service → zfs-import.target
  → pci-rescan-thunderbolt.service → basic.target → sockets.target
  → sshd-unix-local.socket → sysinit.target
  ```
- Systemd broke the cycle by deleting jobs, so PCI rescan never ran

#### Attempt 2: ExecStartPre override (commit dacd37f)
**What I did:**
- Attempted to override zfs-import-tank.service:
  ```nix
  systemd.services.zfs-import-tank = {
    serviceConfig.ExecStartPre = [ ... ];
  };
  ```

**Why it failed:**
- The NixOS ZFS module generates services using the `script` attribute (not `ExecStart`)
- Services created via `lib.listToAttrs` and `lib.nameValuePair` don't properly merge `serviceConfig` overrides
- The `ExecStartPre` directive was silently ignored
- System went into emergency recovery mode on boot

### Key Insights from NixOS ZFS Module Analysis

From examining `/nixos/modules/tasks/filesystems/zfs.nix`:

1. **No built-in hooks** - The ZFS module doesn't provide any pre-import hook options
2. **Script-based service generation** - Uses `script` attribute, not `ExecStart`/`ExecStartPre`
3. **Override limitations** - Direct serviceConfig overrides don't work due to how services are generated
4. **Proper solution** - Use a wrapper service with hard dependencies

## The Solution

### Implementation

Created `/etc/nixos/modules/storage/pci-rescan.nix` with a **wrapper service pattern**:

```nix
systemd.services.thunderbolt-pci-rescan = {
  description = "PCI bus rescan for Thunderbolt storage devices";

  # Make this a hard dependency of zfs-import-tank using requiredBy
  # This avoids ordering cycles by not using wantedBy
  requiredBy = [ "zfs-import-tank.service" ];
  before = [ "zfs-import-tank.service" ];

  after = [ "systemd-modules-load.service" ];
  unitConfig.DefaultDependencies = false;

  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
  };

  script = ''
    echo 1 > /sys/bus/pci/rescan
    sleep 5
    udevadm trigger
    udevadm settle --timeout=15
    sleep 3

    # Enroll ThunderBay device with auto policy
    boltctl enroll --policy auto $(boltctl | grep -A 2 "ThunderBay" | ...) || true
  '';
};

# Ensure zfs-import-tank waits for PCI rescan
systemd.services.zfs-import-tank = {
  after = [ "thunderbolt-pci-rescan.service" ];
  requires = [ "thunderbolt-pci-rescan.service" ];
};
```

### Why This Works

1. **No ordering cycles** - Uses `requiredBy` instead of `wantedBy`, avoiding the boot critical path
2. **Hard dependency** - `Requires` ensures ZFS import won't start without successful PCI rescan
3. **Proper ordering** - `Before` and `After` ensure correct execution sequence
4. **DefaultDependencies=false** - Prevents unwanted dependencies on basic.target/sysinit.target

### Service Dependencies (Verified)

```
thunderbolt-pci-rescan.service
├── After: systemd-modules-load.service
├── Before: zfs-import-tank.service
└── DefaultDependencies: false

zfs-import-tank.service
├── After: thunderbolt-pci-rescan.service
├── Requires: thunderbolt-pci-rescan.service
└── After: systemd-udev-settle.service, systemd-modules-load.service
```

### Changes Made

1. **Created:** `/etc/nixos/modules/storage/pci-rescan.nix`
2. **Modified:** `/etc/nixos/hosts/vulcan/default.nix` - added pci-rescan.nix import
3. **Modified:** `/etc/nixos/modules/core/boot.nix` - removed postBootCommands logic

## Testing Status

- ✅ Configuration builds successfully
- ✅ systemd service files generated correctly
- ✅ Service dependencies verified
- ⏳ **REQUIRES REBOOT** to test actual boot behavior

## Expected Behavior After Reboot

1. Kernel modules load (`systemd-modules-load.service`)
2. PCI bus rescan runs (`thunderbolt-pci-rescan.service`)
3. Thunderbolt storage devices enumerate
4. udev processes new devices
5. Thunderbolt devices enrolled via boltctl (within pci-rescan service)
6. ZFS pool "tank" import succeeds (`zfs-import-tank.service`)
7. Dependent services start successfully:
   - redis-litellm.service
   - redis-ragflow.service
   - postgresql.service
   - nextcloud-setup.service
   - litellm.service
   - wallabag.service

## Lessons Learned

1. **Read the NixOS module source** - Understanding how services are generated is critical for proper overrides
2. **Avoid boot critical path** - Use `requiredBy` instead of `wantedBy` for boot-time dependencies
3. **Test systemd dependencies** - Use `systemctl cat` to verify generated service files
4. **ExecStartPre doesn't work with script** - NixOS services using `script` attribute need different override approaches
5. **DefaultDependencies matters** - Setting to false prevents unwanted systemd ordering dependencies

## References

- NixOS ZFS Module: `/nixos/modules/tasks/filesystems/zfs.nix`
- systemd ordering: `man systemd.unit`
- Thunderbolt authorization: `/etc/nixos/modules/core/boot.nix` (udev rules)
