{
  config,
  lib,
  pkgs,
  ...
}:

{
  # ============================================================================
  # System-Level Prometheus Exporters
  # Consolidates: node-exporter, systemd-exporter, and zfs-exporter
  # ============================================================================

  # --------------------------------------------------------------------------
  # Node Exporter - System Metrics
  # --------------------------------------------------------------------------
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;

    # Enable additional collectors
    # Note: systemd collector is enabled here, making systemd-exporter redundant
    enabledCollectors = [
      "systemd"
      "processes"
      "logind"
      "textfile"
    ];

    # Disable collectors that might have security implications
    disabledCollectors = [
      "wifi"
    ];

    extraFlags = [
      "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker)($|/)"
      "--collector.netclass.ignored-devices=^(lo|podman[0-9]|br-|veth).*"
      "--collector.textfile.directory=/var/lib/prometheus-node-exporter-textfiles"
    ];
  };

  # Service hardening and reliability for node exporter
  systemd.services."prometheus-node-exporter" = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Fix permissions for prometheus-node-exporter-textfiles directory
  # The NixOS prometheus exporter creates this with restrictive permissions (0755)
  # We need world-writable (1777) so mbsync and other services can write metrics
  # Use 'z' directive to recursively set permissions on existing directory
  # Note: Using prometheus user which is created by the prometheus service
  systemd.tmpfiles.rules = [
    "z /var/lib/prometheus-node-exporter-textfiles 1777 prometheus prometheus -"
  ];

  # --------------------------------------------------------------------------
  # ZFS Exporter - Storage Metrics
  # --------------------------------------------------------------------------
  services.prometheus.exporters.zfs = {
    enable = true;
    port = 9134;
    # Monitor all pools (default behavior when pools is not specified)
  };

  # Service hardening and reliability for ZFS exporter
  # Auto-start when tank mount becomes available
  # ConditionPathIsMountPoint prevents "failed" status during rebuild when mount unavailable
  systemd.services."prometheus-zfs-exporter" = {
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "zfs.target"
      "zfs-import-tank.service"
    ];
    wantedBy = [ "tank.mount" ];
    unitConfig = {
      RequiresMountsFor = [ "/tank" ];
      ConditionPathIsMountPoint = "/tank";
    };
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  # --------------------------------------------------------------------------
  # Prometheus Scrape Configurations
  # --------------------------------------------------------------------------
  services.prometheus.scrapeConfigs = [
    # Node exporter (includes systemd metrics)
    {
      job_name = "node";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ];
          labels = {
            alias = "vulcan";
          };
        }
      ];
    }

    # ZFS exporter
    {
      job_name = "zfs";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.prometheus.exporters.zfs.port}" ];
        }
      ];
    }
  ];

  # --------------------------------------------------------------------------
  # Firewall Configuration
  # --------------------------------------------------------------------------
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.exporters.node.port
    config.services.prometheus.exporters.zfs.port
  ];
}
