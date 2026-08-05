{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Memory limits for resource-intensive services to prevent OOM crashes
  #
  # These limits are based on observed memory usage patterns. Per-service
  # measurements live in the comment on each service below -- do NOT add a summary
  # block here. A stale header measurement contradicting the per-service comment 37
  # lines further down is exactly the trap that was removed on 2026-07-28: the header
  # carried 2026-07-27 figures for Home Assistant while the service comment carried
  # newer ones, and the header reads as more authoritative.
  #
  # Promtail's cap is NOT set here -- it is MemoryMax = 512M in
  # modules/services/promtail.nix.
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
  #   victoriametrics/grafana/jellyfin              0 events -- left alone, but see below
  #
  # OUTCOME, re-measured 2026-07-29: the loki and home-assistant raises WORKED and need no
  # further change -- loki went 1,037 events -> 0 (peak 289 MiB against a 3G soft limit)
  # and home-assistant 184 -> 0 (peak 1.47 GiB against 2G). Only postgresql still throttles,
  # and it is re-sized below. Do not raise loki or home-assistant "for symmetry": neither
  # is anywhere near its ceiling and there is nothing to gain.
  #
  # "0 events" is not the same as "ample room". victoriametrics (363 MiB peak / 2G high)
  # and grafana (340 MiB / 1.2G) genuinely have room. JELLYFIN DOES NOT: its peak is
  # 1.82 GiB against a 2.5 GiB soft limit, i.e. 73% consumed with ~680 MiB spare, on a
  # transcoding workload whose spikes depend on what is being transcoded. It has not
  # throttled yet, so it is not changed here, but it is the next candidate and should not
  # be read as comfortable.
  #
  # Note MemoryHigh/MemoryMax account PAGE CACHE, not just anonymous memory, so an
  # I/O-heavy service is throttled on cache it would otherwise be free to keep. That is
  # the dominant term for postgresql. Host has 62 GiB total with ~26 GiB available, so
  # none of this was capacity pressure -- it was self-inflicted.
  #
  # MemoryMax is a ceiling, not a reservation -- but that is not a blank cheque, so the
  # budget is written down rather than asserted. Summed 2026-07-28 against MemTotal
  # 62.25 GiB:
  #
  #   MemoryMax in this file (6 services)                        25.50 GiB
  #   MemoryMax elsewhere under modules/ (12 services)           26.00 GiB
  #   microVM QEMU allocation (hermes 3, microvm.mem = 3072)      3.00 GiB
  #   ZFS ARC c_max                                              16.00 GiB
  #                                                             ----------
  #   nominal total                                              74.50 GiB  = 120%
  #
  # Updated 2026-07-29: postgresql's MemoryMax went 8G -> 12G on measured evidence (see
  # its block below), moving this file's six caps from 21.50 to 25.50 GiB and the nominal
  # total from 113% to 120% of MemTotal 62.25 GiB.
  #
  # Deliberately over 100%, and that is safe here for four measured reasons: ceilings are
  # not reservations; ARC is elastic and currently sits at ~7 of its 16 GiB; observed
  # actuals across all capped services total ~9.5 GiB against ~30 GiB MemAvailable; and
  # `memory.events` oom_kill is 0 on every cgroup inspected, historically included. Note
  # the microVM figures are the QEMU `microvm.mem` allocations, NOT cgroup limits -- both
  # microvm@ units report MemoryMax=infinity.
  #
  # CORRECTED 2026-07-29. An earlier version of this note claimed "the MemoryMax values in
  # the removed OpenClaw VM config and hermes-vm.nix cap the host-side gateway services, not the guests".
  # Both halves were wrong. hermes-vm.nix declares NO MemoryMax at all -- its only memory
  # setting is `microvm.mem = 3072`. And the removed OpenClaw VM config's single `MemoryMax = "4G"` sits in
  # `systemd.services.openclaw` inside a file imported via `microvm.vms.openclaw.config`, so
  # it is a GUEST-internal cgroup cap, the exact inverse of what was claimed.
  #
  # Consequence for the budget above: that 4 GiB was counted twice -- once in the 26.00 GiB
  # "MemoryMax elsewhere" line as if it were a host cap, and again inside the 3.00 GiB microVM
  # allocation line. The host-side total is therefore ~70.50 GiB / ~113%, not the ~74.50 GiB
  # / 120% stated. The error was conservative (it overstated commitment), which is why nothing
  # broke, but the table should not be trusted to the GiB until re-derived.

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
    # THE DECISIVE EVIDENCE is the reclaim profile, not a static budget:
    #   pgscan_direct           328,982,937   <- 92% of all reclaim was SYNCHRONOUS,
    #   pgscan_kswapd            28,148,500      done in the allocating process's context
    #   workingset_refault_file 278,216,158   <- file pages evicted then immediately needed
    #   memory.peak           4.77 GiB        <- EXCEEDS the old MemoryMax of 4 GiB
    # The working set was genuinely larger than the old HARD ceiling and was only held
    # under it by relentless reclaim, ~278 million times re-reading pages it had just
    # dropped. That is the argument for this change.
    #
    # Composition, from live cgroup memory.stat -- note what is NOT the problem:
    #   shmem 2.05 GiB  = shared_buffers, charged to memory.current because
    #                     huge_pages=try fell back (HugePages_Total 0); with huge pages
    #                     granted it would be accounted by a separate controller instead
    #   file  4.54 GiB  = page cache -- the dominant and elastic term
    #   anon  0.23 GiB  = everything else
    # So the binding constraint was shared_buffers + page cache. maintenance_work_mem is
    # NOT a flat global line item as an earlier version of this comment implied: it is
    # per-worker, and with autovacuum_max_workers=2 and autovacuum_work_mem=-1 the
    # autovacuum path alone can claim 2 x 1 GiB, which exceeded even the old MemoryMax --
    # but anon never approaches that in practice, so it is a tail risk, not the cause.
    #
    # effective_cache_size, corrected 2026-07-28: it is 4 GiB, and an earlier version of
    # this comment got it wrong twice. It is the planner's estimate of TOTAL effective
    # cache for one query INCLUDING shared_buffers, not "4 GiB of OS cache", so the
    # OS-cache component being assumed was ~2 GiB -- comparing 4 GiB against the 3.5 GiB
    # cgroup ceiling double-counted shared_buffers on one side. It also allocates and
    # reserves nothing, so it caused exactly none of the throttling. And raising the
    # ceiling did not "resolve" the mismatch, it INVERTED the sign: at 4 GiB against the
    # new ceiling and a 4.5 GiB resident footprint, e_c_s is now the CONSERVATIVE side,
    # biasing the planner toward sequential and bitmap scans rather than index scans.
    # Left alone deliberately -- changing planner settings alters query plans and belongs
    # in a separate, separately-verified tuning change. Recorded so the next reader knows
    # it is a known open item, not an oversight.
    #
    # Sizing: High 10G / Max 12G, raised on the evidence above. Verified 2026-07-29 --
    # memory.peak 6.27 GiB, so the working set now sits under the soft limit.
    #
    # HOW TO RE-VALIDATE: re-measure the BUFFER CACHE HIT RATIO. Do NOT look for zero
    # reclaim -- a finite ceiling on an elastic page cache will always eventually be
    # filled, so the goal is fitting the working set, not eliminating reclaim. And do NOT
    # judge by memory.pressure, which badly understates the cost (68 s cumulative stall
    # over 26 days) because evicting cache is not a stall; it reappears later as disk
    # reads. Baseline to beat, from pg_stat_database:
    #
    #   overall buffer cache hit ratio  89.4%   (blks_read ~609M = ~4.6 TB re-read)
    #   mailarchiver 84.0%                      <- worst; mailarchiver is the largest
    #
    # ~89% is poor for PostgreSQL, where >99% is the normal target. Confirmed relevant:
    # the data directory is on /dev/nvme0n1p5, ext4, so it is served by the kernel PAGE
    # CACHE governed by this cgroup limit -- NOT by ZFS ARC, which caps separately at
    # 16 GiB.
    postgresql = {
      serviceConfig = {
        MemoryMax = "12G";
        MemoryHigh = "10G";
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
