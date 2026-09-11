{
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  exporter = pkgs.writers.writePython3Bin "smart-selftest-exporter" {
    libraries = [ ];
    flakeIgnore = [ "E501" ]; # long explanatory lines in the module docstring
  } (builtins.readFile ../../../scripts/smart-selftest-exporter.py);
in
{
  # SMART self-test results for the four tank disks.
  #
  # smartctl_exporter collects SMART attributes but emits NO self-test family at all --
  # verified against its live /metrics on 2026-09-11, where the nearest thing is
  # smartctl_device_error_log_count. So the scheduled tests introduced in smartd.nix would
  # have had both their failures AND their silent absence invisible to Prometheus, which is
  # the precise failure mode that let these disks go 3.5 years untested unnoticed.
  #
  # No new port: node-exporter's existing textfile collector serves these, so
  # docs/ports.txt is unchanged. Alerts live in ../alerts/smart-selftest.yaml.

  systemd.services.smart-selftest-exporter = {
    description = "Export SMART self-test results to a node-exporter textfile";
    serviceConfig = {
      Type = "oneshot";
      # Root is required: smartctl needs raw device access to read the self-test log.
      User = "root";
      ExecStart = "${lib.getExe exporter}";
      # Four sequential smartctl calls, each capped at 120s inside the script. The UAS
      # bridge can be slow to answer when a self-test is running on the drive being polled.
      TimeoutStartSec = "10m";

      # Hardening: needs four device reads and one file write.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      DeviceAllow = [
        "/dev/sda r"
        "/dev/sdb r"
        "/dev/sdc r"
        "/dev/sdd r"
      ];
      CapabilityBoundingSet = [
        "CAP_SYS_ADMIN"
        "CAP_SYS_RAWIO"
      ];
    };
    path = [ pkgs.smartmontools ];
  };

  systemd.timers.smart-selftest-exporter = {
    description = "Timer for SMART self-test result collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Self-test state moves slowly -- a long test runs for 23.5 hours -- so 15 minutes is
      # ample to catch a run starting, finishing or failing. This is a lighter SMART read
      # than the 5-minute poll smartctl_exporter already performs on the same devices.
      OnCalendar = "*:0/15";
      RandomizedDelaySec = "2m";
      Persistent = true;
    };
  };
}
