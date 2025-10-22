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
    binfmt = {
      emulatedSystems = [ "x86_64-linux" ];
    };
  };
}
