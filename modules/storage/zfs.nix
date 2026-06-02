{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Enable ZFS support with 16K page size (Apple Silicon / Asahi Linux)
  boot = {
    supportedFilesystems = [ "zfs" ];

    # Force the OWC Mercury Elite Pro Quad (USB VID:PID 1e91:a4a7) that hosts the
    # `tank` pool off the UAS driver onto the slower but rock-solid BOT/usb-storage
    # driver. The bridge's UAS firmware hangs under concurrent multi-bay load: on
    # 2026-06-02 the 02:00 backup herd triggered a `uas_eh_abort_handler` storm ->
    # `cmd cmplt err -108` (ESHUTDOWN) -> all four bays dropped off USB at once,
    # taking the pool MISSING until a physical power-cycle. `:u` = US_FL_IGNORE_UAS.
    # Takes effect on the next boot (kernel command line).
    kernelParams = [ "usb-storage.quirks=1e91:a4a7:u" ];

    zfs = {
      forceImportAll = false;
      forceImportRoot = false;
      extraPools = [
        "tank"
      ];
      # Don't request encryption credentials during boot
      # Encrypted datasets with canmount=noauto must be loaded manually
      requestEncryptionCredentials = false;
    };

    # ZFS ARC (Adaptive Replacement Cache) memory limits
    # Maximum: 16 GiB (17179869184 bytes)
    # Minimum: 2 GiB (2147483648 bytes)
    # Using extraModprobeConfig instead of kernelParams so limits apply
    # at module load time without requiring a reboot
    extraModprobeConfig = ''
      options zfs zfs_arc_max=17179869184
      options zfs zfs_arc_min=2147483648
      options zfs zfs_vdev_scrub_max_active=1
    '';
  };

  # Ensure zfs-mount waits for pool imports to complete
  systemd.services.zfs-mount = {
    after = [
      "zfs-import-tank.service"
    ];
    requires = [
      "zfs-import-tank.service"
    ];
  };

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
      pools = [
        "tank"
      ];
    };
  };

  services.sanoid = {
    enable = true;

    datasets = {
      tank = {
        use_template = [ "archival" ];
        recursive = true;
        process_children_only = true;
      };

      "tank/Downloads".use_template = [ "active" ];
    };

    templates = {
      active = {
        frequently = 0;
        hourly = 24;
        daily = 7;
        monthly = 3;
        autosnap = true;
        autoprune = true;
      };

      archival = {
        frequently = 0;
        hourly = 24;
        daily = 30;
        weekly = 8;
        monthly = 12;
        yearly = 5;
        autosnap = true;
        autoprune = true;
      };

      production = {
        frequently = 0;
        hourly = 24;
        daily = 14;
        weekly = 4;
        monthly = 3;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };
    };
  };
}
