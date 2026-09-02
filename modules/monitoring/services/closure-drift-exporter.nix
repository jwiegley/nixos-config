{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  exporter = pkgs.writers.writePython3Bin "closure-drift-exporter" {
    libraries = [ ];
    flakeIgnore = [ "E501" ]; # long explanatory lines in the module docstring
  } (builtins.readFile ../../../scripts/closure-drift-exporter.py);
in
{
  # Detection for services stranded on an abandoned generation.
  #
  # switch-to-configuration restarts units by diffing the OUTGOING generation against
  # the incoming one; it never compares declared state against RUNNING state. A switch
  # that dies partway can therefore leave a unit executing a binary from a generation
  # that is then abandoned, and since every later generation agrees with its
  # predecessor, no subsequent switch sees a change. The drift is permanent and silent.
  #
  # Measured incident (obr nixos-t5w): a failed switch on 2026-08-31 restarted
  # PostgreSQL onto generation 2611's postgresql-17.11 / glibc-2.42 at 20:58:10 and then
  # exited 4. /run/current-system never advanced, so the rollback diffed 2610 against
  # 2610 and left it running. It stayed on the wrong binary for ~24h and roughly eight
  # switches, reporting a collation-version mismatch on all 23 databases throughout,
  # while remaining `active`, healthy and passing every probe. Nothing here detected it;
  # it surfaced by accident during an unrelated investigation.
  #
  # NOT a duplicate of the two nearest neighbours:
  #   * system-age-exporter asks "is the system being PATCHED?" -- flake.lock and
  #     generation mtimes only, nothing about what is executing.
  #   * config-drift-exporter asks "did a watched CONFIG FILE change outside a deploy?"
  #     -- sha256 against a stored baseline, again nothing about running processes.
  # Neither compares running binaries against the closure, and no other check on this
  # host does either.
  systemd.services.closure-drift-exporter = {
    description = "Export services running binaries outside the current system closure";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Root is required to readlink /proc/<pid>/exe for processes owned by other users;
      # without it every service but this one's own reads as unknown and the collector
      # silently inspects nothing.
      User = "root";
      Group = "root";
      ExecStart = "${lib.getExe exporter}";
      TimeoutStartSec = "2m";

      # Hardening: this reads the store DB and /proc, and writes exactly one file.
      # Deliberately NOT DynamicUser -- textfileDir is mode 1777 (sticky), so a rotating
      # uid cannot rename(2) over the .prom left by the previous run.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
    # nix-store for the closure query, systemd for unit enumeration.
    path = [
      config.nix.package
      pkgs.systemd
    ];
  };

  systemd.timers.closure-drift-exporter = {
    description = "Timer for closure-drift detection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # HOURLY, not faster. The condition can only appear at switch time and then
      # persists indefinitely -- it is a latch, not a fluctuation -- so detection
      # latency of an hour costs nothing operationally; the 2026-08-31 case went
      # undetected for ~24h. Hourly also keeps this off the Fast staleness tier, which
      # is reserved for collectors whose data genuinely goes stale in 30 minutes.
      # Cost is not the constraint: the closure query measured 0.19s for 5852 paths.
      OnBootSec = "10m";
      OnCalendar = "hourly";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };
}
