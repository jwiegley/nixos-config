{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Add restart policies for critical services to improve reliability
  # Note: Prometheus exporters already have restart policies in their own modules
  # under modules/monitoring/services/ (the old modules/services/prometheus-monitoring.nix
  # was removed in 2025-12 when that tree was split out).

  systemd.services = {
    # Database service - critical
    postgresql = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "10s";
        RestartSteps = 5;
        RestartMaxDelaySec = "5min";
      };
    };

    # Web services
    nginx = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = lib.mkForce "5s";
        RestartSteps = 3;
        RestartMaxDelaySec = "1min";
      };
    };

    # Certificate Authority - critical for TLS
    step-ca = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "30s";
        RestartSteps = 3;
        RestartMaxDelaySec = "5min";
      };
    };

    # Monitoring services
    prometheus = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "10s";
        RestartSteps = 3;
        RestartMaxDelaySec = "2min";
      };
    };

    # Mail services
    postfix = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "10s";
        RestartSteps = 3;
        RestartMaxDelaySec = "2min";
      };
    };

    # Note: Container services managed by Quadlet (litellm, wallabag, and the other
    # rootless per-user quadlets defined under modules/users/home-manager/)
    # are excluded from restart policies here because Quadlet handles their lifecycle management
    # differently. Applying systemd service overrides causes conflicts with quadlet-nix's
    # overrideStrategy. These containers already have restart policies defined in their
    # Quadlet .container files.

    # Sanoid (ZFS snapshots) - important for data protection
    sanoid = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "1min";
      };
    };
  };

}
