{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Crown-jewel config-drift exporter (P2, security/correctness domain —
  # docs/MONITORING_DEFERRED_SPECS.md "Config-Drift Auditing", Option B).
  #
  # AIDE is the broad whole-tree net but it (a) does NOT cover /var/lib/hass or
  # /var/lib/node-red and (b) re-baselines on every rebuild, so it cannot tell
  # "this specific crown jewel changed OUTSIDE a deploy window". This exporter
  # is the sharpshooter for the ~7 highest-value mutable config artifacts:
  #
  #   /var/lib/hass/{configuration,automations,scripts,scenes}.yaml
  #   /var/lib/node-red/flows.json
  #   /etc/ssh/sshd_config
  #   /etc/nixos/secrets/secrets.yaml   (ENCRYPTED bytes — sops is never run)
  #
  # For each file it computes a sha256 of the (optionally normalized) bytes,
  # compares against a baseline in /var/lib/config-drift/baselines.json, and
  # marks config_file_drift=1 ONLY when the sha changed AND the file's mtime is
  # outside a grace window of its deploy anchor (NR backup mtime for flows.json,
  # the system-generation timestamp from system_age.prom for everything else).
  # A legitimate rebuild / Node-RED deploy re-baselines silently => no alert.
  #
  # SECURITY: emits counts / booleans / timestamps / file-NAME labels ONLY. The
  # sha256 lives in the root-0600 baseline store and is NEVER emitted; no file
  # contents, no diffs, no key paths. configuration.yaml is sha-normalized by
  # dropping the rebuild-injected "  db_url:" line (mirrors
  # home-assistant.nix:1120). secrets.yaml is hashed in ciphertext form.
  #
  # Also emits nixos_config_uncommitted_changes (count of uncommitted/untracked
  # files in /etc/nixos, ignoring the gitignored .nixos-build lock) so forgotten
  # live edits that diverge from git surface after 24h.
  #
  # Emitted to the node-exporter textfile collector
  # (/var/lib/prometheus-node-exporter-textfiles/, picked up by job=node), the
  # same idiom as system-age-exporter.nix / openclaw-config-drift-check.nix.
  # Alerts live in modules/monitoring/alerts/config-drift.yaml.
  driftScript = pkgs.writers.writePython3Bin "config-drift-exporter" {
    flakeIgnore = [
      "E501" # long lines (HELP text + dict literals)
      "W503" # line break before binary operator
      "E203" # whitespace before ':' (black-compatible)
      "E265" # writePython3Bin prepends its own shebang → ours lands on line 2
    ];
  } (builtins.readFile ../../../scripts/config-drift-exporter.py);
in
{
  # Baseline store MUST persist across rebuilds: 'd' preserves contents, never
  # 'D' (CLAUDE.md data-loss rule — 'D' empties on systemd-tmpfiles --remove).
  systemd.tmpfiles.rules = [
    "d /var/lib/config-drift 0700 root root -"
  ];

  systemd.services.config-drift-exporter = {
    description = "Crown-jewel config-drift textfile exporter";
    # Needs system_age.prom present (the generation deploy anchor) and the
    # textfile dir created.
    after = [
      "system-age-exporter.service"
      "prometheus-node-exporter.service"
    ];
    # git binary is needed by the script for the uncommitted-changes gauge;
    # under ProtectSystem=strict the unit PATH excludes the system profile.
    path = [ pkgs.git ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${driftScript}/bin/config-drift-exporter";
      RuntimeMaxSec = "120s";
      # Hardening mirrors system-age-exporter.nix / openclaw-config-drift-check.
      # Runs as root: must read root-0600 /var/lib/hass/configuration.yaml and
      # the SOPS ciphertext. It can write nothing it reads back except its own
      # baseline store + the textfile dir.
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      LockPersonality = true;
      ReadWritePaths = [
        "/var/lib/prometheus-node-exporter-textfiles"
        "/var/lib/config-drift"
      ];
    };
  };

  systemd.timers.config-drift-exporter = {
    description = "Hourly crown-jewel config-drift check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "8min";
      OnUnitActiveSec = "1h";
      Persistent = true;
      RandomizedDelaySec = "5min";
      Unit = "config-drift-exporter.service";
    };
  };

  # Operator approval helper: re-baseline every crown jewel to its current sha
  # (use after a deliberate hand edit that did not ride a rebuild).
  #   systemctl start config-drift-rebaseline.service
  systemd.services.config-drift-rebaseline = {
    description = "Re-baseline all crown-jewel config shas (operator approval)";
    path = [ pkgs.git ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${driftScript}/bin/config-drift-exporter --rebaseline";
      RuntimeMaxSec = "120s";
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [
        "/var/lib/prometheus-node-exporter-textfiles"
        "/var/lib/config-drift"
      ];
    };
  };
}
