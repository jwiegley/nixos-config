{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  exporter = pkgs.writers.writePython3Bin "hass-entity-availability-exporter" {
    libraries = [ ];
    flakeIgnore = [ "E501" ]; # long explanatory lines in the module docstring
  } (builtins.readFile ../../../scripts/hass-entity-availability-exporter.py);
in
{
  # Plan item M-91. Makes HA entity availability measurable: 197 entities are currently
  # unavailable/unknown and nothing tracked that number, so it could drift indefinitely.
  #
  # SHIPS DELIBERATELY WITHOUT AN ALERT RULE. D9 (the entity cleanup) is the prerequisite and
  # is operator-executed. A threshold fitted to today's baseline would encode ~33 known-dead
  # duplicate twins as normal, manufacturing exactly the dead-rule class this whole effort
  # exists to remove. The sequence is: land the metric, operator cleans up (see
  # docs/HA_ENTITY_WORKLIST_2026-07-29.md), observe the new baseline, THEN threshold.
  #
  # No new port -- node-exporter's existing textfile collector serves this, so
  # docs/ports.txt is unchanged.

  systemd.services.hass-entity-availability-exporter = {
    description = "Export Home Assistant entity availability to a node-exporter textfile";
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Runs as postgres so it can read the recorder database via local peer auth. That is
      # the reason this reads the DB rather than HA's REST API: the API would need a
      # long-lived token plumbed through SOPS for what is a read-only health count.
      User = "postgres";
      Group = "postgres";
      ExecStart = "${lib.getExe exporter}";
      TimeoutStartSec = "5m";

      # Hardening: one database read and one file write.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      CapabilityBoundingSet = [ "" ];
    };
    path = [ config.services.postgresql.package ];
  };

  systemd.timers.hass-entity-availability-exporter = {
    description = "Timer for Home Assistant entity availability collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Entity availability changes on the order of minutes at most, and the query costs
      # 0.21s against the live 3.8M-row states table, so 15 minutes is ample and cheap.
      OnCalendar = "*:0/15";
      RandomizedDelaySec = "2m";
      Persistent = true;
    };
  };
}
