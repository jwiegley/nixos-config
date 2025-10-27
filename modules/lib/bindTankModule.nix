{ config, lib, pkgs, ... }:

{
  bindTankPath = {
    path,
    device,
    isReadOnly ? false
  }:
  let
    # Convert device path to systemd mount unit name
    # Example: /tank/Nextcloud -> tank-Nextcloud.mount
    deviceUnitName =
      (lib.replaceStrings ["/"] ["-"]
        (lib.removePrefix "/" device)) + ".mount";
  in
  {
    "${path}" = {
      inherit device;
      options = [
        "bind"
        "nofail"  # Don't block boot/activation if mount fails
        "x-systemd.requires-mounts-for=${device}"  # Ensure source is mounted first
        "x-systemd.requires=${deviceUnitName}"  # Explicit dependency on the ZFS mount unit
        "x-systemd.after=${deviceUnitName}"  # Wait for ZFS dataset to mount
        "x-systemd.after=zfs.target"
        "x-systemd.after=zfs-import-tank.service"
      ] ++ lib.optional isReadOnly "ro";
    };
  };
}
