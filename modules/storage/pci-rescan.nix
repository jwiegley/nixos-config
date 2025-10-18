{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Create a dedicated PCI rescan service that runs before ZFS pool import.
  # This is necessary for Thunderbolt storage devices that require PCI bus
  # enumeration before the devices appear to the system.
  #
  # Key ordering requirements:
  # 1. Must run AFTER bolt.service is ready (for Thunderbolt authorization)
  # 2. Must run AFTER basic system infrastructure (udev, dbus)
  # 3. Must run BEFORE zfs-import-tank.service
  # 4. Should allow system to stabilize to avoid race conditions
  systemd.services.thunderbolt-pci-rescan = {
    description = "PCI bus rescan for Thunderbolt storage devices";

    # Make this a hard dependency of zfs-import-tank
    # Using requiredBy instead of wantedBy avoids ordering cycles
    requiredBy = [ "zfs-import-tank.service" ];
    before = [ "zfs-import-tank.service" ];

    # Critical: Wait for the infrastructure needed for Thunderbolt authorization
    # - systemd-udev-settle: All udev events processed
    # - bolt.service: Thunderbolt daemon ready to authorize devices
    # - basic.target: Ensures dbus, sockets, and other infrastructure is ready
    after = [
      "systemd-udev-settle.service"
      "bolt.service"
      "basic.target"
    ];

    # Ensure bolt daemon is running before we rescan
    # This is critical because bolt must be ready to authorize devices
    # when they appear on the PCI bus
    requires = [ "bolt.service" ];

    # Allow default dependencies (basic.target, sysinit.target)
    # This ensures we run in the proper boot phase
    unitConfig.DefaultDependencies = true;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      echo "Starting Thunderbolt PCI rescan..."

      # Verify bolt daemon is accessible via D-Bus
      # This confirms the entire authorization stack is ready
      if ! ${pkgs.bolt}/bin/boltctl list >/dev/null 2>&1; then
        echo "WARNING: bolt daemon not responding, waiting 5s..."
        sleep 5
      fi

      # Trigger PCI bus rescan to enumerate Thunderbolt devices
      echo "Rescanning PCI bus for Thunderbolt storage devices..."
      echo 1 > /sys/bus/pci/rescan

      # Wait for devices to appear on the bus
      echo "Waiting for device enumeration (10s)..."
      sleep 10

      # Trigger udev to process new devices and wait for completion
      echo "Triggering udev events..."
      ${pkgs.systemd}/bin/udevadm trigger
      ${pkgs.systemd}/bin/udevadm settle --timeout=30

      # Allow time for bolt to authorize devices via udev rules
      echo "Waiting for Thunderbolt authorization (5s)..."
      sleep 5

      # Explicitly enroll ThunderBay device with auto policy if not already enrolled
      # The grep/head pipeline extracts the device UUID
      echo "Ensuring Thunderbolt devices are enrolled..."
      DEVICE_UUID=$(${pkgs.bolt}/bin/boltctl list | ${pkgs.gnugrep}/bin/grep -A 2 "ThunderBay" \
        | ${pkgs.gnugrep}/bin/grep -o "[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}" \
        | ${pkgs.coreutils}/bin/head -n 1 || true)

      if [ -n "$DEVICE_UUID" ]; then
        ${pkgs.bolt}/bin/boltctl enroll --policy auto "$DEVICE_UUID" || true
        echo "Enrolled device: $DEVICE_UUID"
      else
        echo "No ThunderBay device found to enroll"
      fi

      # Final settling time for storage devices to initialize
      echo "Waiting for storage device initialization (5s)..."
      sleep 5

      # Verify devices are visible
      if ${pkgs.systemd}/bin/udevadm info -q path /dev/disk/by-id/* 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "thunderbolt"; then
        echo "SUCCESS: Thunderbolt storage devices are now visible"
      else
        echo "WARNING: No Thunderbolt storage devices detected"
      fi

      echo "PCI rescan complete - devices ready for ZFS import"
    '';
  };

  # Ensure zfs-import-tank waits for the PCI rescan to complete
  systemd.services.zfs-import-tank = {
    after = [ "thunderbolt-pci-rescan.service" ];
    requires = [ "thunderbolt-pci-rescan.service" ];
  };
}
