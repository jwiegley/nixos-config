{ config, lib, pkgs, ... }:

{
  # Create a dedicated PCI rescan service that runs before ZFS pool import
  # This is necessary for Thunderbolt storage devices that require PCI bus
  # enumeration before the devices appear to the system.
  systemd.services.thunderbolt-pci-rescan = {
    description = "PCI bus rescan for Thunderbolt storage devices";

    # Make this a hard dependency of zfs-import-tank
    # Using requiredBy instead of wantedBy avoids ordering cycles
    requiredBy = [ "zfs-import-tank.service" ];
    before = [ "zfs-import-tank.service" ];

    # Ensure kernel modules are loaded first
    after = [ "systemd-modules-load.service" ];

    # Don't create dependencies on basic.target or sysinit.target
    unitConfig.DefaultDependencies = false;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      echo "Rescanning PCI bus for Thunderbolt storage devices..."
      echo 1 > /sys/bus/pci/rescan

      # Wait for devices to enumerate
      sleep 5

      # Trigger udev to process new devices
      ${pkgs.systemd}/bin/udevadm trigger
      ${pkgs.systemd}/bin/udevadm settle --timeout=15

      # Additional settling time for device initialization
      sleep 3

      # Enroll ThunderBay device with auto policy
      echo "Enrolling Thunderbolt devices..."
      ${pkgs.bolt}/bin/boltctl enroll --policy auto \
        $(${pkgs.bolt}/bin/boltctl | ${pkgs.gnugrep}/bin/grep -A 2 "ThunderBay" \
          | ${pkgs.gnugrep}/bin/grep -o "[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}" \
          | ${pkgs.coreutils}/bin/head -n 1) || true

      echo "PCI rescan and Thunderbolt enrollment complete"
    '';
  };

  # Ensure zfs-import-tank waits for the PCI rescan to complete
  systemd.services.zfs-import-tank = {
    after = [ "thunderbolt-pci-rescan.service" ];
    requires = [ "thunderbolt-pci-rescan.service" ];
  };
}
