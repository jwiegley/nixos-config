{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Memory limits for resource-intensive services to prevent OOM crashes
  #
  # These limits are based on observed memory usage patterns. Measured
  # 2026-07-27 with `systemctl show -p MemoryCurrent -p MemoryPeak <unit>`:
  # - Promtail: 91 MiB current, 224 MiB peak. Its cap is NOT set here — it is
  #   MemoryMax = 512M in modules/services/promtail.nix.
  # - Home Assistant: 1.15 GiB current, 1.50 GiB peak.
  #
  # Philosophy:
  # - MemoryMax: Hard limit, kills service if exceeded
  # - MemoryHigh: Soft limit, triggers aggressive reclaim before reaching Max
  # - Set MemoryHigh above OBSERVED PEAK plus headroom -- NOT above "typical".
  #
  # CORRECTED 2026-07-28. The previous rule here was "Max ~30% above typical usage,
  # High ~10% above typical usage", and that rule is what produced the problem it was
  # meant to prevent: a soft limit only 10% above typical means the kernel begins
  # aggressive reclaim as soon as a service exceeds its own typical usage, which for
  # anything with legitimate spikes or page-cache growth is continuous. Measured before
  # this change (`memory.events` high counter, cumulative since boot):
  #
  #   postgresql      current 3.5GB == High 3.5GB, peak 3.6GB, 3,899,187 throttle events
  #   loki            current 522MB,  peak 2.1GB   > High 2.0GB, 1,037 events
  #   home-assistant  current 1.2GB,  peak 1.6GB   > High 1.5GB,   184 events
  #   victoriametrics/grafana/jellyfin              0 events, ample room -- left alone
  #
  # Note MemoryHigh/MemoryMax account PAGE CACHE, not just anonymous memory, so an
  # I/O-heavy service is throttled on cache it would otherwise be free to keep. That is
  # the dominant term for postgresql. Host has 62 GiB total with ~26 GiB available, so
  # none of this was capacity pressure -- it was self-inflicted.
  #
  # MemoryMax is a ceiling, not a reservation: raising it costs nothing until used.

  systemd.services = {
    # NOTE: Container services managed by quadlet have their resource limits
    # set via podman's --memory and --memory-reservation flags in their
    # respective quadlet configuration files. Setting systemd limits here
    # would conflict with quadlet's overrideStrategy.
    #
    # To set memory limits for quadlet containers, use extraContainerConfig in
    # mkQuadletService:
    # podmanArgs = [ "--memory=1.8g" "--memory-reservation=1.5g" ]

    # Home Assistant memory limits
    # Measured 2026-07-28: 1.2 GiB current, 1.6 GiB peak, 184 throttle events — the peak
    # had already crossed the old 1.5G soft limit, so raise High above peak.
    home-assistant = {
      serviceConfig = {
        MemoryMax = "2.5G";
        MemoryHigh = "2G";
      };
    };

    # Loki memory limits
    # Log aggregation spikes during high ingestion. Measured 2026-07-28: 522 MiB current
    # but 2.1 GiB peak against a 2G soft limit, 1,037 throttle events — the spikes are
    # real and legitimate, so High must sit above them, not at them. Headroom matters
    # here because Phase 6 adds promtail scrapes for home-assistant, node-red, sudo and
    # kernel, which will raise ingestion volume.
    loki = {
      serviceConfig = {
        MemoryMax = "4G";
        MemoryHigh = "3G";
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
    #
    # The old values (High 3.5G / Max 4G) were labelled "generous limits to prevent
    # disruption" but were the single worst offender on the host: current sat exactly AT
    # the 3.5G soft limit with 3,899,187 throttle events, i.e. permanently in reclaim.
    #
    # Arithmetic showing why 3.5G could never work, from live pg_settings:
    #   shared_buffers       = 2 GiB   (262144 x 8kB)  -- resident, always
    #   maintenance_work_mem = 1 GiB                   -- during any VACUUM / CREATE INDEX
    #   work_mem             = 32 MiB per sort/hash node, max_connections = 200
    # So a single autovacuum put it at 3 GiB of a 3.5 GiB ceiling before one byte of
    # page cache or a single sort. Everything else was fighting for ~0.5 GiB.
    #
    # There was also a direct contradiction: effective_cache_size = 4 GiB told the query
    # PLANNER to assume 4 GiB of OS cache while the cgroup ceiling for the entire service
    # was 3.5 GiB, so the planner costed index scans against cache that could not exist.
    # Raising the cgroup ceiling resolves that inconsistency without touching planner
    # settings (which would change query plans and belongs in a separate tuning change).
    #
    # New values give shared_buffers + maintenance_work_mem + concurrent work_mem + several
    # GiB of page cache, with Max as a genuine safety net rather than a routine ceiling.
    postgresql = {
      serviceConfig = {
        MemoryMax = "12G";
        MemoryHigh = "8G";
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
