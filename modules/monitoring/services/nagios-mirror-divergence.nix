{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  statusDat = "/var/lib/nagios/status.dat";

  # Tier-3 of the Nagios <-> Prometheus reverse mirror (see
  # docs/NAGIOS_PROMETHEUS_MIRROR_SPEC.md section 4). A 5-minute reconciler
  # that parses the PROM-MIRROR servicestatus blocks Nagios writes into
  # status.dat and compares their HARD states against the firing sets of the
  # three rulers (Prometheus :9090, Loki ruler :3100, vmalert :8880). It emits
  # COUNTS + diverged ALERTNAMES ONLY (alertnames are public repo content; no
  # other label values are ever written) into a textfile collector picked up by
  # job=node. Alert rules live in modules/monitoring/alerts/nagios-mirror.yaml.
  #
  # Pattern mirrors nagios-status-exporter.nix: root oneshot + timer +
  # writePython3Bin over scripts/, atomic tmp+mv 0644 textfile. Runs as root so
  # it can read the nagios-owned status.dat regardless of mode; queries loopback
  # ruler APIs only, unauthenticated (existing posture). ReadOnlyPaths pins
  # status.dat for defence in depth.
  reconciler = pkgs.writers.writePython3Bin "nagios-mirror-divergence" {
    flakeIgnore = [
      "E501" # long lines (HELP/TYPE strings, metric lines, comments)
      "W503" # line break before binary operator
      "E203" # whitespace before ':' (slice style)
      "E265" # block comment should start with '# '
    ];
  } (builtins.readFile ../../../scripts/nagios-mirror-divergence.py);
in
{
  systemd.services.nagios-mirror-divergence = {
    description = "Nagios <-> Prometheus mirror divergence reconciler (tier 3)";
    after = [ "nagios.service" ];
    # No wantedBy - service only runs via timer.

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${reconciler}/bin/nagios-mirror-divergence";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      ReadOnlyPaths = [ statusDat ];
      ReadWritePaths = [ textfileDir ];
    };
  };

  systemd.timers.nagios-mirror-divergence = {
    description = "Timer for the Nagios <-> Prometheus mirror divergence reconciler";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "5min"; # divergence skew is judged over a 30m window
      Persistent = true;
      AccuracySec = "10s";
    };
  };
}
