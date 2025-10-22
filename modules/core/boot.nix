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
    # Using fixBinary to preload interpreter for container support
    # Note: preferStaticEmulators causes build failures on ARM64
    binfmt = {
      emulatedSystems = [ "x86_64-linux" ];
      registrations.x86_64-linux = {
        fixBinary = true;
      };
    };
  };
}
