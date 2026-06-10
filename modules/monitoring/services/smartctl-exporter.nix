{ config, ... }:

# SMART disk-health exporter (P0 #3, docs/MONITORING_COVERAGE_PLAN.md).
#
# Until 2026-06-09 there was ZERO SMART visibility on this host: no smartd, no
# exporter. That is the gap that matters most here because the tank pool lives on
# 4x Seagate Exos X18 (sda-sdd) behind a flaky OWC Mercury Elite Pro Quad USB/UAS
# enclosure (see memory project_tank_uas_enclosure_failure). The leading indicator
# that the UAS bridge is degrading is a rising UDMA_CRC_Error_Count on those disks
# — invisible without SMART. The NVMe root (nvme0n1) is monitored for media errors.
#
# Verified 2026-06-09 (`smartctl -H`): all five devices report PASSED and SMART
# reads pass cleanly through the UAS bridge with automatic SAT detection — no
# `-d sat` / device_type override needed.
#
# Metric names emitted (prometheus-community/smartctl_exporter):
#   smartctl_device_smart_status{device}       1=passed / 0=failed
#   smartctl_device_attribute{device,attribute_name,attribute_value_type,...}
#   smartctl_device_temperature{device,temperature_type="current"}
#   smartctl_device_media_errors{device}       NVMe
#   smartctl_devices                           count of scanned devices (no labels)
# Alerts in modules/monitoring/alerts/smart.yaml.

{
  services.prometheus.exporters.smartctl = {
    enable = true;
    port = 9633;
    # Localhost only — scraped by the local Prometheus, never exposed.
    listenAddress = "127.0.0.1";
    devices = [
      "/dev/sda" # tank — Seagate Exos X18 (UAS enclosure)
      "/dev/sdb" # tank — Seagate Exos X18 (UAS enclosure)
      "/dev/sdc" # tank — Seagate Exos X18 (UAS enclosure)
      "/dev/sdd" # tank — Seagate Exos X18 (UAS enclosure)
      "/dev/nvme0n1" # root NVMe
    ];
    # Limit how often each disk is polled. Spinning the UAS bridge harder than
    # necessary is exactly what triggers its abort-storm, so keep it gentle.
    maxInterval = "5m";
  };

  # Open the exporter port on loopback only (mirrors redis-exporter.nix).
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 9633 ];

  # Prometheus scrape configuration. scrape_interval comfortably exceeds the
  # 5m smartctl poll interval; the exporter serves cached values between polls.
  services.prometheus.scrapeConfigs = [
    {
      job_name = "smartctl";
      static_configs = [
        {
          targets = [
            "127.0.0.1:${toString config.services.prometheus.exporters.smartctl.port}"
          ];
        }
      ];
      scrape_interval = "60s";
    }
  ];
}
