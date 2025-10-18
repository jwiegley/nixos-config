{ config, lib, pkgs, ... }:

{
  boot = {
    loader = {
      systemd-boot.enable = false;
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };

    kernelParams = [
      "pcie_ports=native"  # instead of "pcie_ports=compat"
      # ZFS ARC tuning for 64GB RAM system
      "zfs.zfs_arc_max=34359738368"  # 32GB max (50% of RAM)
      "zfs.zfs_arc_min=4294967296"   # 4GB min
      # Increase audit backlog to prevent kauditd overflow during boot
      "audit_backlog_limit=8192"
    ];

    supportedFilesystems = [ "zfs" ];
    zfs.extraPools = [ "tank" ];

    initrd.services.udev.rules = ''
      ACTION=="add|change", SUBSYSTEM=="thunderbolt", \
      ATTR{unique_id}=="d4030000-0080-7708-2354-04990534401e" \
      ATTR{authorized}="1"
    '';

    # PCI rescan and ZFS import are now handled by systemd services
    # See modules/storage/pci-rescan.nix for Thunderbolt device enumeration
  };
}
