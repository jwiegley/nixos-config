{ config, lib, pkgs, ... }:

{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = false;
    };

    supportedFilesystems = lib.optionals false [ "zfs" ];
    zfs.extraPools = lib.optionals false [ "tank" ];

    # Enable QEMU user-mode emulation for running amd64 containers on ARM64
    # Note: preferStaticEmulators causes build failures on ARM64
    # Using default (non-static) emulator configuration with wrapper for container support
    binfmt = {
      emulatedSystems = [ "x86_64-linux" ];
      # Don't override fixBinary - let it default to false for non-static emulators
      # This allows the QEMU wrapper (wrapQemuBinfmtP) to work correctly in containers
    };
  };
}
