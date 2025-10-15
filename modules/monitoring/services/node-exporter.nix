{ config, lib, pkgs, ... }:

{
  # Prometheus node exporter for system metrics
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;

    # Enable additional collectors
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

  # Prometheus scrape configuration for node exporter
  services.prometheus.scrapeConfigs = [
    {
      job_name = "node";
      static_configs = [{
        targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ];
        labels = {
          alias = "vulcan";
        };
      }];
    }
  ];

  # Service hardening and reliability
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
  # Using a oneshot service that runs after tmpfiles to ensure correct permissions
  systemd.services.prometheus-textfiles-permissions = {
    description = "Fix permissions for Prometheus textfiles directory";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    before = [ "prometheus-node-exporter.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/chmod 1777 /var/lib/prometheus-node-exporter-textfiles";
    };
  };

  # Firewall configuration
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    config.services.prometheus.exporters.node.port
  ];
}
