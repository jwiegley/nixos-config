{ config, lib, pkgs, ... }:

{
  # Enable ZFS support with 16K page size (Apple Silicon / Asahi Linux)
  boot = {
    supportedFilesystems = [ "zfs" ];
    zfs = {
      forceImportAll = false;
      forceImportRoot = false;
      extraPools = [ "tank" "gdrive" ];
    };
  };

  # Ensure zfs-mount waits for pool imports to complete
  systemd.services.zfs-mount = {
    after = [ "zfs-import-tank.service" "zfs-import-gdrive.service" ];
    requires = [ "zfs-import-tank.service" "zfs-import-gdrive.service" ];
  };

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
      pools = [ "tank" "gdrive" ];
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

      gdrive = {
        use_template = [ "archival" ];
        recursive = true;
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
