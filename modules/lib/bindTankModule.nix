{
  config,
  lib,
  pkgs,
  ...
}:

{
  bindTankPath =
    {
      path,
      device,
      isReadOnly ? false,
    }:
    {
      "${path}" = {
        inherit device;
        options = [
          "bind"
          # tank lives on a USB enclosure that can vanish; a dead pool must never
          # hang boot, so these binds stay nofail.
          "nofail"
          # Depend ONLY on the concrete zfs-mount.service barrier -- deliberately
          # NOT on the auto-generated tank-<dataset>.mount unit and NOT via
          # RequiresMountsFor (which also pulls in that unit). systemd creates
          # tank-<dataset>.mount from /proc/mountinfo only AFTER zfs-mount runs, so
          # at boot-transaction time it is unloadable; a nofail bind that Requires an
          # unloadable unit is silently dropped from the transaction and never
          # retried -- which left copyparty/static-nginx and the backup binds down
          # across the 2026-06-02 reboots (the bind was never even enqueued). Earlier
          # fixes ADDED zfs-mount.service ordering but kept the poisonous
          # tank-<dataset>.mount Requires, so the drop persisted. zfs-mount.service
          # is a real, always-present unit whose completion guarantees every tank
          # dataset (incl. ${device}) is mounted, so requiring + ordering after it
          # both keeps the bind in the boot transaction AND guarantees the source
          # exists before the bind runs. See project_tank_uas_enclosure_failure.
          "x-systemd.requires=zfs-mount.service"
          "x-systemd.after=zfs-mount.service"
        ]
        ++ lib.optional isReadOnly "ro";
      };
    };
}
