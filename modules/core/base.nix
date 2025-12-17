{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # Core Base Configuration
  # Consolidates: boot, nix, firewall, hardware, and DNS override settings
  # ============================================================================

  # --------------------------------------------------------------------------
  # Boot Configuration
  # --------------------------------------------------------------------------
  boot = {
    loader = {
      systemd-boot.enable = true;
      systemd-boot.configurationLimit = 10;  # Keep only 10 boot entries to save /boot space
      efi.canTouchEfiVariables = false;
    };

    # Enable QEMU user-mode emulation for running amd64 containers on ARM64
    # Note: preferStaticEmulators causes build failures on ARM64
    # Using default (non-static) emulator configuration with wrapper for
    # container support
    binfmt = {
      emulatedSystems = [ "x86_64-linux" ];

      # Don't override fixBinary - let it default to false for non-static
      # emulators
      # This allows the QEMU wrapper (wrapQemuBinfmtP) to work correctly in
      # containers
    };
  };

  # --------------------------------------------------------------------------
  # Nix Configuration
  # --------------------------------------------------------------------------
  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Configure Nix to use system CA bundle (includes step-ca root certificate)
  # This allows git+https:// flake inputs to work with internal services
  # using certificates signed by step-ca
  nix.settings.ssl-cert-file = "/etc/ssl/certs/ca-bundle.crt";

  # Limit build parallelism to prevent WiFi driver crashes on Asahi Linux
  # The brcmfmac driver becomes unstable under high CPU + network load
  # Reducing parallelism prevents kernel panics during nixos-rebuild
  nix.settings.max-jobs = 4;  # Limit concurrent builds (default: auto = 10 cores)
  nix.settings.cores = 2;     # Limit cores per build job (default: 0 = all cores)

  # Also set NIX_SSL_CERT_FILE environment variable for all users
  # This ensures git operations invoked by Nix use the correct CA bundle
  environment.variables.NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
  environment.variables.GIT_SSL_CAINFO = "/etc/ssl/certs/ca-bundle.crt";

  # --------------------------------------------------------------------------
  # Firewall Configuration
  # --------------------------------------------------------------------------
  networking.firewall = {
    enable = true;
    logRefusedConnections = true;
    logRefusedPackets = true;
    logRefusedUnicastsOnly = true;
    logReversePathDrops = true;

    # Use loose reverse path filtering for asymmetric routing
    # Allows WiFi devices (192.168.3.x) to reach services at Ethernet IP (192.168.1.2)
    # when packets are routed between networks
    checkReversePath = "loose";

    # Allow IGMP (protocol 2) on WiFi interface
    # Router sends IGMP membership queries to 224.0.0.1 (all-hosts multicast)
    # These have unicast MAC but multicast IP, so logRefusedUnicastsOnly doesn't filter them
    # IGMP is harmless - just for multicast group management
    extraCommands = ''
      iptables -A nixos-fw -i wlp1s0f0 -p igmp -j nixos-fw-accept
    '';
    extraStopCommands = ''
      iptables -D nixos-fw -i wlp1s0f0 -p igmp -j nixos-fw-accept 2>/dev/null || true
    '';
  };

  # Enable loose reverse path filtering for asymmetric routing
  # This allows WiFi devices (192.168.3.0/24) to access services at the
  # Ethernet IP (192.168.1.2) without rpfilter dropping packets
  # Mode 2 = loose mode (allows packets from any interface)
  # Mode 1 = strict mode (default, drops asymmetric packets)
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
  };

  # --------------------------------------------------------------------------
  # Hardware Configuration
  # --------------------------------------------------------------------------
  # Enable hardware graphics acceleration
  # Required for GPU support including Vulkan on Asahi Linux
  hardware.graphics = {
    enable = true;
    # Enable 32-bit support for compatibility (if needed)
    enable32Bit = false;  # Not needed on aarch64
  };

  # Use modesetting driver for Apple Silicon GPU
  # Mesa provides OpenGL and Vulkan support via the Asahi driver
  services.xserver.videoDrivers = [ "modesetting" ];

  # --------------------------------------------------------------------------
  # NetworkManager DNS Override
  # --------------------------------------------------------------------------
  # NetworkManager dispatcher script to clear DHCP-provided DNS servers
  # This ensures only hard-coded DNS servers from networking.nameservers are used
  networking.networkmanager.dispatcherScripts = [{
    source = pkgs.writeText "clear-dhcp-dns" ''
      #!/bin/sh
      # Clear DNS servers from NetworkManager connections
      # Only runs on DHCP events
      if [ "$2" = "dhcp4-change" ] || [ "$2" = "dhcp6-change" ] || [ "$2" = "up" ]; then
        ${pkgs.systemd}/bin/resolvectl dns "$1" ""
      fi
    '';
    type = "basic";
  }];
}
