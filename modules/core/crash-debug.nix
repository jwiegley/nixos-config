{
  config,
  lib,
  pkgs,
  ...
}:

{
  # ============================================================================
  # Crash Debugging and System Monitoring Configuration
  # Purpose: Aid debugging of spontaneous reboots and system crashes
  # ============================================================================

  # --------------------------------------------------------------------------
  # Persistent Journald Logging
  # Keeps logs after reboot to diagnose causes of spontaneous reboots
  # --------------------------------------------------------------------------
  services.journald = {
    extraConfig = ''
      # Store journals persistently in /var/log/journal
      # This preserves logs across reboots for crash analysis
      Storage=persistent

      # Compress journal files to save disk space
      Compress=yes

      # Set reasonable size limits
      # SystemMaxUse: Maximum disk space for journal files
      SystemMaxUse=2G

      # SystemKeepFree: Minimum free space to maintain
      SystemKeepFree=10G

      # SystemMaxFileSize: Maximum size of individual journal files
      SystemMaxFileSize=128M

      # RuntimeMaxUse: Maximum space for volatile journals (in /run)
      RuntimeMaxUse=256M

      # MaxRetentionSec: Keep logs for 30 days maximum
      MaxRetentionSec=30day

      # MaxFileSec: Rotate journal files monthly
      MaxFileSec=1month

      # Forward to syslog for additional logging redundancy
      ForwardToSyslog=yes

      # Forward kernel messages to kmsg for dmesg visibility
      ForwardToKMsg=yes

      # Rate limiting: Allow high burst for capturing crash events
      # These are per-service limits
      RateLimitIntervalSec=30s
      RateLimitBurst=10000
    '';

    # Forward to syslog for rsyslog/syslog-ng compatibility
    forwardToSyslog = true;
  };

  # --------------------------------------------------------------------------
  # Kernel Log Monitoring (rsyslogd for kern.log)
  # Provides traditional /var/log/kern.log for kernel message analysis
  # --------------------------------------------------------------------------
  services.rsyslogd = {
    enable = true;
    defaultConfig = ''
      # Log kernel messages to kern.log
      kern.*                          /var/log/kern.log

      # Log all messages to syslog
      *.*                             /var/log/syslog

      # Log auth/security messages
      auth,authpriv.*                 /var/log/auth.log

      # Log daemon messages
      daemon.*                        /var/log/daemon.log

      # Emergency messages to all users
      *.emerg                         :omusrmsg:*
    '';
    extraConfig = ''
      # Ensure kern.log directory exists and set proper ownership
      $FileOwner root
      $FileGroup root
      $FileCreateMode 0640
      $DirCreateMode 0755
      $Umask 0022
    '';
  };

  # --------------------------------------------------------------------------
  # Crash Dump (kdump) Configuration
  # Captures kernel crash dumps for post-mortem analysis
  # Note: This requires reserved memory and may not work on all ARM64 systems
  # --------------------------------------------------------------------------
  boot.crashDump = {
    enable = true;

    # Reserve 512MB for crash kernel (adjust if dmesg shows reservation failed)
    # ARM64 may need different values; start conservative
    reservedMemory = "512M";

    # Additional kernel parameters for crash kernel
    kernelParams = [
      # Minimal boot for crash kernel
      "irqpoll"
      "nr_cpus=1"
      "reset_devices"
      # Disable unnecessary subsystems in crash kernel
      "udev.children-max=2"
    ];
  };

  # --------------------------------------------------------------------------
  # Sysstat (sar) Configuration
  # Track CPU, memory, I/O trends for performance analysis
  # --------------------------------------------------------------------------
  services.sysstat = {
    enable = true;

    # Collect stats every 5 minutes (default is every 10 minutes)
    collect-frequency = "*:0/5";

    # Collect all available statistics
    collect-args = "-S ALL";
  };

  # Install additional diagnostic tools
  environment.systemPackages = with pkgs; [
    # System monitoring and diagnostics
    sysstat # sar, iostat, mpstat, pidstat, etc.
    procps # ps, top, vmstat, free, etc. (includes dmesg)
    lsof # List open files
    strace # System call tracer
    htop # Interactive process viewer
    iotop # I/O monitoring
    atop # Advanced system monitor with logging

    # Memory analysis
    numactl # NUMA policy control

    # Hardware diagnostics
    lshw # Hardware lister
    pciutils # lspci
    usbutils # lsusb
  ];

  # --------------------------------------------------------------------------
  # Kernel Panic and Debugging Settings
  # Configure kernel behavior during crashes for better diagnostics
  # --------------------------------------------------------------------------
  boot.kernel.sysctl = {
    # ---- Panic Behavior ----

    # kernel.panic: Seconds to wait before auto-reboot after panic
    # 0 = don't auto-reboot (hang for debugging)
    # >0 = wait N seconds then reboot
    # 60 seconds gives time to capture crash info while still recovering
    "kernel.panic" = 60;

    # kernel.panic_on_oops: Convert kernel oops to panic
    # 1 = panic on oops (better for crash dump capture)
    # 0 = try to continue after oops (may cause instability)
    "kernel.panic_on_oops" = 1;

    # kernel.panic_on_warn: Panic on WARN() assertions
    # 0 = don't panic (default, WARNs are informational)
    # 1 = panic on WARN (very aggressive, for deep debugging only)
    "kernel.panic_on_warn" = 0;

    # ---- OOM (Out of Memory) Settings ----

    # vm.panic_on_oom: Panic on out-of-memory condition
    # 0 = kill process (OOM killer behavior, default)
    # 1 = panic if OOM (enables crash dump of OOM situations)
    # 2 = panic forcefully even if OOM killer could recover
    # For debugging spontaneous reboots, 0 is usually better - lets OOM killer
    # run and logs which process was killed
    "vm.panic_on_oom" = 0;

    # vm.oom_kill_allocating_task: Kill the allocating task on OOM
    # 0 = kill task with highest memory score (default)
    # 1 = kill the task that triggered OOM
    "vm.oom_kill_allocating_task" = 0;

    # vm.oom_dump_tasks: Dump task info on OOM
    # 1 = dump all tasks' memory info when OOM occurs (useful for debugging)
    "vm.oom_dump_tasks" = 1;

    # ---- Softlockup Detection ----

    # kernel.softlockup_panic: Panic on soft lockup detection
    # 1 = panic when soft lockup detected (CPU held for >20s default)
    # This helps capture what caused the lockup via crash dump
    "kernel.softlockup_panic" = 1;

    # kernel.softlockup_all_cpu_backtrace: Dump all CPU backtraces on lockup
    # 1 = show all CPUs' backtraces (helps identify deadlocks)
    "kernel.softlockup_all_cpu_backtrace" = 1;

    # ---- Hung Task Detection ----

    # kernel.hung_task_panic: Panic on hung task detection
    # 1 = panic when a task is stuck in D state too long
    # Helps capture filesystem/IO deadlocks
    "kernel.hung_task_panic" = 1;

    # kernel.hung_task_timeout_secs: Seconds before considering task hung
    # Default is 120, setting to 300 (5 min) to avoid false positives
    "kernel.hung_task_timeout_secs" = 300;

    # ---- Watchdog Settings ----

    # kernel.nmi_watchdog: NMI watchdog for hard lockup detection
    # 1 = enable (crashes on hard lockups)
    # Note: boot.crashDump.enable already activates this
    "kernel.nmi_watchdog" = 1;

    # kernel.watchdog_thresh: Threshold for lockup detection in seconds
    # Default is 10, setting to 20 to reduce false positives
    "kernel.watchdog_thresh" = 20;

    # ---- Logging Verbosity ----

    # kernel.printk: Kernel message logging levels
    # Format: console_loglevel default_message_loglevel minimum_console_loglevel default_console_loglevel
    # 4 4 1 7 = show warnings and above on console, log everything
    "kernel.printk" = "4 4 1 7";

    # kernel.printk_ratelimit: Seconds between rate-limited messages
    # Lower value = more messages captured during crash events
    "kernel.printk_ratelimit" = 1;

    # kernel.printk_ratelimit_burst: Messages allowed before rate limiting
    "kernel.printk_ratelimit_burst" = 100;

    # ---- Memory Debugging ----

    # kernel.sysrq: Enable SysRq key for emergency debugging
    # 1 = enable all SysRq functions (useful for manual crash triggering)
    "kernel.sysrq" = 1;
  };

  # --------------------------------------------------------------------------
  # Kernel Command Line Parameters for Boot-time Debugging
  # --------------------------------------------------------------------------
  boot.kernelParams = [
    # Enable verbose kernel messages during boot
    "loglevel=7"

    # Disable quiet boot to see all kernel messages
    # (commented out - may already be handled by NixOS)
    # "verbose"

    # Enable kernel oops reporting to console
    "oops=panic"
  ];

  # --------------------------------------------------------------------------
  # Log Rotation for Traditional Log Files
  # --------------------------------------------------------------------------
  services.logrotate = {
    enable = true;
    settings = {
      # Rotate kern.log specifically
      "/var/log/kern.log" = {
        rotate = 7;
        frequency = "weekly";
        compress = true;
        delaycompress = true;
        missingok = true;
        notifempty = true;
        create = "0640 root root";
        postrotate = "systemctl reload rsyslog 2>/dev/null || true";
      };

      # Rotate syslog
      "/var/log/syslog" = {
        rotate = 7;
        frequency = "weekly";
        compress = true;
        delaycompress = true;
        missingok = true;
        notifempty = true;
        create = "0640 root root";
        postrotate = "systemctl reload rsyslog 2>/dev/null || true";
      };
    };
  };

  # --------------------------------------------------------------------------
  # Ensure /var/log/journal exists for persistent journal storage
  # --------------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    # Create journal directory with correct permissions
    # Using 'd' (preserve) NOT 'D' (which would empty on boot!)
    "d /var/log/journal 2755 root systemd-journal - -"
  ];

  # --------------------------------------------------------------------------
  # atop Daemon for Historical System Monitoring
  # Captures detailed system metrics with process accounting
  # --------------------------------------------------------------------------
  programs.atop = {
    enable = true;

    # Enable the atop service for storing statistics
    atopService.enable = true;

    # Enable process accounting (tracks per-process resource usage)
    atopacctService.enable = true;

    # Enable log rotation timer
    atopRotateTimer.enable = true;

    # Configuration for atop
    settings = {
      # Interval in seconds for atop sampling
      interval = 10;

      # Flags to enable all monitoring features
      flags = "afD";
    };
  };
}
