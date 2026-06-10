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

  # Belt-and-suspenders for the /tank bind-mount boot race (see
  # modules/lib/bindTankModule.nix and project_tank_uas_enclosure_failure). The
  # fstab fix should mount the binds on its own, but this oneshot guarantees it:
  # once ZFS has mounted the datasets, explicitly (re)mount every tank bind and
  # start the nspawn containers that depend on them. Idempotent (no-op if they are
  # already up) and a no-op when /tank is absent, so it never hangs or breaks a
  # degraded boot. This codifies the manual recovery that has always worked.
  systemd.services.tank-binds-ensure = {
    description = "Ensure /tank bind mounts and their containers are up after ZFS";
    after = [
      "zfs-mount.service"
      "local-fs.target"
    ];
    wants = [ "zfs-mount.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.util-linux
      pkgs.gnugrep
      pkgs.gawk
      config.systemd.package
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Tolerate a dead/absent tank: do nothing if /tank is not mounted.
      if ! mountpoint -q /tank; then
        echo "/tank not mounted; skipping tank bind ensure"
        exit 0
      fi

      # Mount every tank bind mount (each is tagged with the zfs-mount.service
      # dependency in /etc/fstab by bindTankPath). Idempotent: a no-op if already
      # mounted, mounts it otherwise.
      grep 'x-systemd.requires=zfs-mount.service' /etc/fstab | awk '{print $2}' | while read -r mp; do
        [ -z "$mp" ] && continue
        unit="$(systemd-escape -p --suffix=mount "$mp")"
        systemctl start "$unit" || true
      done

      # Ensure the nspawn containers that bind tank paths are up. Clear any
      # skipped/failed state first; start async so we never block boot.
      systemctl reset-failed container@copyparty.service container@static-nginx.service 2>/dev/null || true
      systemctl start --no-block container@copyparty.service container@static-nginx.service || true
    '';
  };

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
      pools = [
        "tank"
      ];
    };

    # ZFS Event Daemon (zed) kernel-level email notification — defense in depth,
    # entirely independent of the Prometheus/Alertmanager pipeline. zed fires the
    # instant the kernel emits a ZFS event (vdev FAULTED/REMOVED, checksum/IO
    # errors, pool SUSPENDED, scrub finished, resilver, etc.), which is exactly
    # the UAS-enclosure failure mode the textfile collector can only catch on its
    # 2-minute poll. Before this, ZED_EMAIL_ADDR was unset, so zed sent nothing.
    #
    # Delivery: ZED_EMAIL_PROG is the mailutils `mail` (absolute store path — zed's
    # own PATH does not include mailutils, so a bare "mail" would not resolve), which
    # hands off to the local postfix sendmail; root is redirected to the real mailbox
    # by the existing postfix aliases. ZED_NOTIFY_INTERVAL_SECS=3600 rate-limits
    # repeat notifications for the same class of event to once per hour so a flapping
    # device cannot mail-bomb. enableMail already defaults true on this host (a
    # sendmail setuid wrapper exists), but ZED only mails when ZED_EMAIL_ADDR is set.
    zed.settings = {
      ZED_EMAIL_ADDR = [ "root" ];
      ZED_EMAIL_PROG = "${pkgs.mailutils}/bin/mail";
      ZED_EMAIL_OPTS = "-s '@SUBJECT@' @ADDRESS@";
      ZED_NOTIFY_INTERVAL_SECS = 3600;
      # Notify on every event class, not only those that changed state, so a
      # completed scrub / cleared error is reported too (verbose is cheap here).
      ZED_NOTIFY_VERBOSE = true;
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
