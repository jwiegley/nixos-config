{ config, lib, pkgs, secrets, ... }:

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

  # zram swap configuration
  # Provides compressed swap in RAM to prevent OOM kills during memory pressure
  # 50% of RAM (32GB) can hold ~64-96GB of compressed data
  zramSwap = {
    enable = true;
    memoryPercent = 50;
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
