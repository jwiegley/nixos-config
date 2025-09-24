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
    smokeping = {
      serviceConfig = {
        Restart = lib.mkDefault "on-failure";
        RestartSec = "30s";
        RestartSteps = 3;
        RestartMaxDelaySec = "5min";
      };
    };

    prometheus = {
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

  # Add health check for critical services
  systemd.services.critical-services-health-check = {
    description = "Check health of critical services";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "health-check" ''
        CRITICAL_SERVICES="postgresql nginx step-ca prometheus"
        FAILED_SERVICES=""

        for service in $CRITICAL_SERVICES; do
          if ! ${pkgs.systemd}/bin/systemctl is-active --quiet "$service"; then
            FAILED_SERVICES="$FAILED_SERVICES $service"
            echo "❌ $service is not running" | ${pkgs.systemd}/bin/systemd-cat -p err -t health-check
          else
            echo "✓ $service is running" | ${pkgs.systemd}/bin/systemd-cat -t health-check
          fi
        done

        if [ -n "$FAILED_SERVICES" ]; then
          echo "Critical services failed:$FAILED_SERVICES" | ${pkgs.systemd}/bin/systemd-cat -p crit -t health-check
          exit 1
        fi
      '';
    };
  };

  systemd.timers.critical-services-health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "10min";
      Persistent = true;
    };
  };
}
