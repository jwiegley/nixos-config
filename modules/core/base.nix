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
