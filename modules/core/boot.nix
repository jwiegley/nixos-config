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
    ];

    supportedFilesystems = [ "zfs" ];
    # zfs.extraPools = [ "tank" ];

    initrd.services.udev.rules = ''
      ACTION=="add|change", SUBSYSTEM=="thunderbolt", \
      ATTR{unique_id}=="d4030000-0080-7708-2354-04990534401e" \
      ATTR{authorized}="1"
    '';

    postBootCommands = ''
      ${pkgs.coreutils}/bin/sleep 60
      echo 1 > /sys/bus/pci/rescan
      ${pkgs.bolt}/bin/boltctl enroll --policy auto \
        $(${pkgs.bolt}/bin/boltctl | ${pkgs.gnugrep}/bin/grep -A 2 "ThunderBay" \
          | ${pkgs.gnugrep}/bin/grep -o "[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}" \
          | ${pkgs.coreutils}/bin/head -n 1) || true
      ${pkgs.zfs}/bin/zpool import -a || true
      ${pkgs.systemd}/bin/systemctl restart smokeping.service || true
    '';
  };
}
