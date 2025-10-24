{ config, lib, pkgs, ... }:

{
  bindTankPath = {
    path,
    device,
    isReadOnly ? false
  }: {
    "${path}" = {
      inherit device;
      options = [
        "bind"
        "nofail"  # Don't block boot/activation if mount fails
        "x-systemd.after=zfs.target"
        "x-systemd.after=zfs-import-tank.service"
      ] ++ lib.optional isReadOnly "ro";
    };
  };
}
