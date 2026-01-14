{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

{
  # Increase D-Bus pending replies limit for systemd_exporter
  services.dbus.packages = [
    (pkgs.writeTextDir "share/dbus-1/system.d/systemd-exporter-limits.conf" ''
      <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <limit name="max_replies_per_connection">2048</limit>
      </busconfig>
    '')
  ];

  services.hardware.bolt.enable = false;

  time.timeZone = "America/Los_Angeles";

  i18n.defaultLocale = "en_US.UTF-8";

  console = {
    font = "Lat2-Terminus16";
    keyMap = "dvorak";
  };

  security = {
    polkit.enable = true;
    sudo.wheelNeedsPassword = false;
  };

  sops = {
    defaultSopsFile = secrets.outPath + "/secrets.yaml";
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = true;
    };
  };

  # Hybrid swap configuration: zram (fast, compressed) + disk (overflow)
  # Based on best practices research for 62GB RAM systems with heavy workloads
  #
  # Architecture:
  # 1. zram swap (31GB, ~50% of RAM): Fast compressed swap in RAM, priority 5
  # 2. Disk swap (16GB at /var/swap): Overflow capacity, priority -2
  #
  # Total: 47GB swap capacity (exceeds 16-32GB recommendation for 64GB RAM)
  #
  # Priority ordering ensures zram is used first (fast), disk swap as fallback (slow)
  # See: https://wiki.archlinux.org/title/Zram

  # zram swap configuration
  # Provides compressed swap in RAM to prevent OOM kills during memory pressure
  # 50% of RAM (32GB) can hold ~64-96GB of compressed data with 2-3x compression
  # Priority 5 (higher than disk swap) ensures zram is used first
  zramSwap = {
    enable = true;
    memoryPercent = 50;
    algorithm = "zstd"; # Best compression ratio and performance
    priority = 5; # Higher priority = used first
  };

  # Physical swap file configuration
  # Provides additional 16GB swap on disk as overflow when RAM + zram are exhausted
  # This acts as a safety net for extreme memory pressure situations
  # Priority -2 (lower than zram) ensures disk swap is only used when zram is full
  swapDevices = [
    {
      device = "/var/swap";
      size = 16 * 1024; # 16GB in MB
      priority = -2; # Lower priority = used last (overflow only)
    }
  ];

  # Kernel memory management tuning
  # Optimized for systems with zram + disk swap hybrid configuration
  boot.kernel.sysctl = {
    # vm.swappiness: How aggressively the kernel swaps memory pages
    # Higher values (180-200) favor swap usage, reducing disk I/O from evicting page cache
    # With zram, higher swappiness is beneficial because compressed RAM swap is fast
    # Default: 60 (desktop), 180+ (server with zram)
    "vm.swappiness" = 180;

    # vm.page-cluster: Number of pages to read from swap in a single attempt
    # 0 = read one page at a time (optimal for zram/SSD)
    # Default: 3 (read 2^3 = 8 pages at once, optimized for spinning disks)
    "vm.page-cluster" = 0;

    # vm.watermark_boost_factor: Boost watermarks temporarily when system is low on memory
    # 0 = disable boosting (prevents aggressive reclaim triggering)
    # Default: 15000 (1.5% boost)
    "vm.watermark_boost_factor" = 0;

    # vm.watermark_scale_factor: How much memory to keep free
    # Higher values = more aggressive about keeping memory free
    # 125 = 0.125% of RAM (780MB for 62GB RAM) kept free
    # Default: 10 (0.1% of RAM)
    "vm.watermark_scale_factor" = 125;

    # vm.vfs_cache_pressure: Tendency to reclaim VFS caches (dentries and inodes)
    # Higher values = more aggressive reclaim of VFS cache
    # Useful for systems with many files (backups, logs, containers)
    # Default: 100 (balanced), 150+ (aggressive cache reclaim)
    "vm.vfs_cache_pressure" = 150;
  };

  # Systemd coredump configuration with limits
  # Prevents excessive disk usage and CPU load from core dump processing
  # See: coredump.conf(5) for details
  systemd.coredump = {
    enable = true;
    extraConfig = ''
      # Storage mode: "external" stores cores in /var/lib/systemd/coredump
      # Alternative: "journal" stores in journal (slower, more space-efficient)
      Storage=external

      # Compress core dumps with zstd (reduces storage significantly)
      Compress=yes

      # Processing limits to prevent system overload during mass crashes
      # ProcessSizeMax: Maximum size of a single core dump (500M)
      ProcessSizeMax=500M

      # ExternalSizeMax: Total disk space for all external core dumps (2G)
      # This limits /var/lib/systemd/coredump to 2GB
      ExternalSizeMax=2G

      # JournalSizeMax: Total disk space for journal-stored cores (1G)
      JournalSizeMax=1G

      # KeepFree: Minimum free space to maintain on disk (5G)
      # Prevents core dumps from filling up the filesystem
      KeepFree=5G

      # MaxUse: Maximum total disk usage by coredump (3G)
      # Combined limit for both external and journal storage
      MaxUse=3G
    '';
  };
}
