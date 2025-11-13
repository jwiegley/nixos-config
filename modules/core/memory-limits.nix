{ config, lib, pkgs, ... }:

{
  # Memory limits for resource-intensive services to prevent OOM crashes
  # See: docs/OOM_ANALYSIS_2025-11-12.md for context
  #
  # These limits are based on observed memory usage patterns:
  # - Promtail: ~1.1GB (limited in promtail.nix)
  # - Paperless-AI: ~1.1GB
  # - Metabase: ~962MB (Java heap already limited to 2GB)
  # - Home Assistant: ~612MB
  #
  # Philosophy:
  # - MemoryMax: Hard limit, kills service if exceeded
  # - MemoryHigh: Soft limit, triggers aggressive reclaim before reaching Max
  # - Set Max ~30% above typical usage, High ~10% above typical usage

  systemd.services = {
    # NOTE: Container services (paperless-ai, metabase, etc.) managed by quadlet
    # have their resource limits set via podman's --memory and --memory-reservation flags
    # in their respective quadlet configuration files. Setting systemd limits here
    # would conflict with quadlet's overrideStrategy.
    #
    # To set memory limits for quadlet containers, use extraContainerConfig in mkQuadletService:
    # podmanArgs = [ "--memory=1.8g" "--memory-reservation=1.5g" ]

    # Home Assistant memory limits
    # Typically uses ~600MB, limit to 1.2GB for integrations and automations
    home-assistant = {
      serviceConfig = {
        MemoryMax = "1.2G";
        MemoryHigh = "1G";
      };
    };

    # Loki memory limits
    # Log aggregation can spike during high ingestion periods
    loki = {
      serviceConfig = {
        MemoryMax = "2.5G";
        MemoryHigh = "2G";
      };
    };

    # VictoriaMetrics memory limits
    # Time-series database with potentially large working sets
    victoriametrics = {
      serviceConfig = {
        MemoryMax = "2.5G";
        MemoryHigh = "2G";
      };
    };

    # Grafana memory limits
    # Dashboard rendering can be memory-intensive
    grafana = {
      serviceConfig = {
        MemoryMax = "1.5G";
        MemoryHigh = "1.2G";
      };
    };

    # Postgres memory limits
    # Critical service, generous limits to prevent disruption
    postgresql = {
      serviceConfig = {
        MemoryMax = "4G";
        MemoryHigh = "3.5G";
      };
    };

    # Jellyfin memory limits
    # Video transcoding can be memory-intensive
    jellyfin = {
      serviceConfig = {
        MemoryMax = "3G";
        MemoryHigh = "2.5G";
      };
    };
  };
}
