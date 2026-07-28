{
  config,
  lib,
  pkgs,
  ...
}:

let
  exporter = pkgs.writers.writePython3Bin "gitea-push-mirror-exporter" {
    libraries = [ ];
    flakeIgnore = [
      "E501" # long explanatory lines in the module docstring
    ];
  } (builtins.readFile ../../../scripts/gitea-push-mirror-exporter.py);
in
{
  # Gitea push-mirror OUTCOME monitoring.
  #
  # The nightly sync job only *triggers* mirror pushes and cannot observe whether
  # they landed: its shell loop treats a failed POST the same as "repo has no push
  # mirrors" and exits 0 regardless. That let the nixos-config -> GitHub mirror fail
  # every day from 2026-05-05 to 2026-07-28 (678 commits behind, blocked by GitHub
  # push protection) with every unit reporting success and nothing alerting. This
  # exporter reads Gitea's recorded per-mirror result instead of the trigger.
  #
  # No port is used (node-exporter textfile collector), so docs/ports.txt is
  # unchanged.

  systemd.services.gitea-push-mirror-exporter = {
    description = "Export Gitea push-mirror outcome metrics for Prometheus";
    after = [
      "network-online.target"
      "sops-install-secrets.service"
      "gitea.service"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # Sanctioned secret path: the token is read from the credential directory by
      # the exporter itself and is never written to a metric, label, or log line.
      LoadCredential = "gitea-token:${config.sops.secrets."gitea-mirror-token".path}";
      ExecStart = lib.getExe exporter;
      # A partial pass exits non-zero on purpose, so failure is loud rather than
      # silently publishing an incomplete set.
      TimeoutStartSec = "5m";

      # Hardening: this only needs to read one credential, talk to localhost Gitea,
      # and write one file.
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  systemd.timers.gitea-push-mirror-exporter = {
    description = "Timer for Gitea push-mirror outcome metrics";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Mirrors sync on an 8h Gitea interval plus a nightly 03:00 sweep; hourly
      # sampling detects a newly-broken mirror the same morning without hammering
      # the API (one call per repo, all to localhost).
      OnCalendar = "hourly";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };

  # The exporter's own liveness is covered by GiteaPushMirrorExporterStale and
  # GiteaPushMirrorExporterFailing in modules/monitoring/alerts/gitea.yaml, so this
  # monitor cannot itself become the silent failure it was written to prevent.
  # Deliberately NOT wired to backup-alert@: that template is gated on
  # ConditionPathIsMountPoint=/tank and would quietly not run when tank is down.
}
