{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  exporter = pkgs.writers.writePython3Bin "cgroup-pressure-exporter" {
    libraries = [ ];
    flakeIgnore = [ "E501" ]; # long explanatory lines in the module docstring
  } (builtins.readFile ../../../scripts/cgroup-pressure-exporter.py);
in
{
  # Plan item M-92 (exporter half; the memory-ceiling half landed 2026-07-29 as Y-01 in
  # modules/core/memory-limits.nix). Makes "is this service SLOW or is it STARVED?" an
  # answerable question per unit, which it has not been on this host.
  #
  # VERIFIED NOT A DUPLICATE (2026-07-30, live Prometheus):
  #   * a full __name__ census returns ZERO names matching `cgroup` -- the gap is total;
  #   * node_pressure_* exists but is HOST-WIDE (exactly 1 series per name, from
  #     /proc/pressure, no unit label). It says the machine stalled, never which service;
  #   * microvm_memory_pressure_{some,full}_avg300 covers only the two microvm@* units,
  #     only memory, and only as an avg300 gauge rather than a monotonic total.
  #   So this is additive at a different granularity, not a second implementation.
  #
  # CALIBRATION WARNING, restated here because a threshold will eventually be written
  # against a Grafana panel rather than against the script: memory.pressure UNDERSTATES
  # cache-eviction cost. Evicting clean page cache is not a stall, so it does not show up
  # in memory PSI; the cost is deferred and returns later as a disk read (io.pressure,
  # query latency). Measured on postgresql 2026-07-30: memory.events high = 3,932,353
  # lifetime reclaim events against memory.pressure full avg10/60/300 all 0.00. NEVER read
  # low memory.pressure as "memory is fine" -- read it together with
  # cgroup_memory_events_total. The full reasoning is in the script docstring.
  #
  # SHIPS DELIBERATELY WITHOUT ANY ALERT RULE. No baseline exists for these series yet, and
  # the 2026-07-29 ceiling raise just changed the regime being measured (postgresql now at
  # 56% of its new 10G memory.high, and its reclaim-event counter was UNCHANGED across
  # three samples 20s apart -- the old continuous ~0.05 events/sec floor has stopped). A
  # threshold fitted today would be fitted to a three-day-old regime. Land the metric, let
  # a baseline accumulate over the full history, then threshold.
  #
  # No new port -- node-exporter's existing textfile collector serves this, so
  # docs/ports.txt is unchanged.
  #
  # POST-SWITCH CHECK, one command, because one claim below is reasoned rather than
  # runtime-verified: the collector was proven to work unprivileged and outside the sandbox
  # (108 lines, 92 series, `promtool check metrics` exit 0), but ProtectControlGroups=true
  # was NOT exercised live -- doing so needs a transient unit. It is read-only-mount
  # semantics, so reads are expected to succeed, but confirm rather than assume:
  #   curl -sG localhost:9090/api/v1/query --data-urlencode \
  #     'query=count(cgroup_pressure_unit_present == 1)'      # expect 6
  # If that returns 0 or a short count, drop ProtectControlGroups (a private cgroup
  # namespace, not a read-only bind, would be the cause) and re-check.

  systemd.services.cgroup-pressure-exporter = {
    description = "Export per-cgroup PSI stall totals to a node-exporter textfile";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Runs as prometheus, NOT root and NOT DynamicUser. Root is unnecessary: every input
      # (/sys/fs/cgroup/<cg>/{memory,io,cpu}.pressure, memory.events, memory.{current,high,
      # max}) is world-readable and `systemctl show -p ControlGroup` needs no privilege --
      # verified by running the collector unprivileged. DynamicUser is wrong for a
      # different reason: textfileDir is mode 1777 (sticky), so a rotating uid cannot
      # rename(2) over a .prom file left behind by a previous run.
      User = "prometheus";
      Group = "prometheus";
      ExecStart = "${lib.getExe exporter}";
      TimeoutStartSec = "1m";

      # Hardening: a handful of /sys reads and one file write.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      # /sys/fs/cgroup mounted READ-ONLY. The collector only ever reads it, and a read-only
      # cgroup tree also guarantees this unit can never perturb the accounting it measures.
      ProtectControlGroups = true;
      # systemctl talks to PID 1 over a unix socket; no network of any kind is needed.
      RestrictAddressFamilies = [ "AF_UNIX" ];
      CapabilityBoundingSet = [ "" ];
    };
    path = [ pkgs.systemd ];
  };

  systemd.timers.cgroup-pressure-exporter = {
    description = "Timer for per-cgroup PSI collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # PSI totals are monotonic counters, so the cadence only bounds the resolution of
      # rate()/increase() over them. 60s matches microvm-resource-exporter.nix (the other
      # cgroup reader) and costs ~20 small /sys reads per run. A stall episode shorter than
      # a minute still shows up -- the counter accumulates it either way; only the shape is
      # smoothed.
      OnBootSec = "2min";
      OnUnitActiveSec = "60s";
      Unit = "cgroup-pressure-exporter.service";
    };
  };
}
