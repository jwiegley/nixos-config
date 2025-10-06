{ config, lib, pkgs, ... }:

{
  # Add restart policies for critical services to improve reliability
  # Note: Prometheus exporters already have restart policies in prometheus-monitoring.nix

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

    # Container services
    podman-litellm = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "30s";
        RestartSteps = 3;
        RestartMaxDelaySec = "5min";
      };
    };

    podman-wallabag = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "30s";
        RestartSteps = 3;
        RestartMaxDelaySec = "5min";
      };
    };

    podman-organizr = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "30s";
        RestartSteps = 3;
        RestartMaxDelaySec = "5min";
      };
    };

    podman-silly-tavern = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "30s";
        RestartSteps = 3;
        RestartMaxDelaySec = "5min";
      };
    };

    # Sanoid (ZFS snapshots) - important for data protection
    sanoid = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "1min";
      };
    };
  };

}
