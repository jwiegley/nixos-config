{ config, lib, pkgs, ... }:

{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = false;
    };

    supportedFilesystems = [ "zfs" ];
    zfs.extraPools = [ "tank" ];
  };
}
