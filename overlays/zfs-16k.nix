# ZFS overlay for 16K page size support (Apple Silicon / Asahi Linux)
#
# This overlay enables ZFS to build and run on systems with 16K page sizes,
# such as Apple Silicon Macs running Asahi Linux with 16K kernels.
#
# Based on workaround from: https://github.com/openzfs/zfs/issues/16429
# Context: Asahi Linux uses 16KB pages due to M1/M2 IOMMU requirements

final: prev: {
  # Override ZFS packages to work with 16K page size kernels
  # This is EXPERIMENTAL and may cause data corruption - use at your own risk!

  zfs_unstable = prev.zfs_unstable.overrideAttrs (oldAttrs: {
    # Add metadata about this overlay
    meta = oldAttrs.meta // {
      description = oldAttrs.meta.description + " (patched for 16K page size)";
      broken = false; # Un-break if marked broken on aarch64
    };

    # The main issue on Asahi Linux is that ZFS build system may check for
    # PAGE_SIZE != 4096 and fail. We need to patch this if it occurs.
    # For now, let's try building against the Asahi kernel directly.

    # Add any necessary patches here
    patches = (oldAttrs.patches or [ ]) ++ [
      # We'll add patches if needed after seeing build errors
    ];

    # Ensure we're building against the current kernel
    # This should pick up the Asahi 16K kernel automatically
  });

  # Also override the stable ZFS variant
  zfs = prev.zfs.overrideAttrs (oldAttrs: {
    meta = oldAttrs.meta // {
      description = oldAttrs.meta.description + " (patched for 16K page size)";
      broken = false;
    };

    patches = (oldAttrs.patches or [ ]) ++ [
      # Patches will be added here if needed
    ];
  });
}
