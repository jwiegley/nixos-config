{ config, lib, pkgs, ... }:

{
  services.sanoid = {
    enable = true;

    datasets = {
      # Snapshot individual filesystems for replication
      "rpool/home".use_template = [ "active" ];
      "rpool/nix".use_template = [ "active" ];
      "rpool/root".use_template = [ "active" ];

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

  systemd = {
    services.zpool-scrub = {
      description = "Scrub ZFS pool";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = "${pkgs.zfs}/bin/zpool scrub rpool tank";
      };
    };

    timers.zpool-scrub = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "monthly";
        Unit = "zpool-scrub.service";
      };
    };
  };
}
