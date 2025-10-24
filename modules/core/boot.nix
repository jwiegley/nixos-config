{ config, lib, pkgs, ... }:

{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = false;
    };

    supportedFilesystems = [ "zfs" ];
    zfs.extraPools = [ "tank" ];

    # Enable QEMU user-mode emulation for running amd64 containers on ARM64
    # Note: preferStaticEmulators causes build failures on ARM64
    # Using default (non-static) emulator configuration with wrapper for container support
    binfmt = {
      emulatedSystems = [ "x86_64-linux" ];
      # Don't override fixBinary - let it default to false for non-static emulators
      # This allows the QEMU wrapper (wrapQemuBinfmtP) to work correctly in containers
    };
  };

  systemd.services.zfs-import-tank = {
    after = [ "zfs.target" ];
  };
}
