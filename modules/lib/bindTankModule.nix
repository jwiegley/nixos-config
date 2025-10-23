{ config, lib, pkgs, ... }:

{
  bindTankPath = {
    path,
    device
  }: {
    "${path}" = lib.mkIf false {
      inherit device;
      options = [
        "bind"
        "nofail"  # Don't block boot/activation if mount fails
        "x-systemd.after=zfs-import-tank.service"
      ];
    };
  };
}
