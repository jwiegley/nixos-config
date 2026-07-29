{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  exporter = pkgs.writers.writePython3Bin "nvme-smart-exporter" {
    libraries = [ ];
    flakeIgnore = [ "E501" ]; # long explanatory lines in the module docstring
  } (builtins.readFile ../../../scripts/nvme-smart-exporter.py);
in
{
  # Boot-NVMe SMART coverage.
  #
  # /dev/nvme0n1 backs / and /nix/store and had NO automated SMART coverage. It cannot be
  # served by smartctl_exporter: it was listed there once and removed on 2026-07-03 because
  # that exporter hardcodes `--log=error`, which hits unsupported log page 0x109 on this
  # Apple ANS NVMe -- smartctl exits 4 and the exporter DISCARDS the device, so it never
  # appeared in smartctl_devices while SmartDeviceMissing fired every boot. See the comment
  # in smartctl-exporter.nix; re-adding it there would reintroduce that known-broken state.
  #
  # This is the textfile follow-up that comment anticipated. It works because it avoids the
  # failing log page entirely: `smartctl -j -H -A` returns exit_status 0 on this device.
  # No new port -- node-exporter's existing textfile collector serves these, so
  # docs/ports.txt is unchanged.

  systemd.services.nvme-smart-exporter = {
    description = "Export boot-NVMe SMART health to a node-exporter textfile";
    serviceConfig = {
      Type = "oneshot";
      # Root is required: smartctl needs raw device access for NVMe admin commands.
      User = "root";
      ExecStart = "${lib.getExe exporter}";
      TimeoutStartSec = "2m";

      # Hardening: needs one device read and one file write.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      # smartctl needs these to issue NVMe admin passthrough ioctls.
      DeviceAllow = [ "/dev/nvme0n1 r" ];
      CapabilityBoundingSet = [
        "CAP_SYS_ADMIN"
        "CAP_SYS_RAWIO"
      ];
    };
    path = [ pkgs.smartmontools ];
  };

  systemd.timers.nvme-smart-exporter = {
    description = "Timer for boot-NVMe SMART health collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # NVMe wear and media errors change slowly; 15 minutes is ample and keeps admin
      # passthrough traffic to the controller negligible.
      OnCalendar = "*:0/15";
      RandomizedDelaySec = "2m";
      Persistent = true;
    };
  };
}
