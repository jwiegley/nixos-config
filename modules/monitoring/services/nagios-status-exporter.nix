{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  outputFile = "${textfileDir}/nagios_status.prom";
  statusDat = "/var/lib/nagios/status.dat";

  # Bridge Nagios -> Prometheus WITHOUT a new port or exporter (restores the
  # intent of the deleted Nagios-aggregate rules, see
  # docs/MONITORING_COVERAGE_PLAN.md "20 deleted rules"). Nagios already writes
  # /var/lib/nagios/status.dat on every check cycle; this oneshot parses it and
  # emits COUNTS ONLY (no host names, service descriptions, or plugin output)
  # to a textfile collector picked up by job=node. Alert rules live in
  # modules/monitoring/alerts/nagios.yaml.
  #
  # status.dat block layout (verified live 2026-06-09): per-service
  # `servicestatus { ... }` and per-host `hoststatus { ... }` blocks with
  # current_state (svc: 0=OK 1=WARN 2=CRIT 3=UNKNOWN; host: 0=UP 1=DOWN
  # 2=UNREACHABLE), state_type (0=soft 1=hard), has_been_checked,
  # active_checks_enabled, last_check (epoch), check_interval (minutes).
  #
  # We count HARD states only (matching Nagios's own notification logic: soft
  # states are transient retries and Nagios does not notify on them), so the
  # gauges align with what Nagios would page on. Staleness counts active checks
  # whose last_check is older than 2x their configured interval.
  parseScript =
    pkgs.writers.writePython3 "nagios-status-parse"
      {
        flakeIgnore = [
          "E501" # long lines (HELP/TYPE strings, comments)
        ];
      }
      ''
        import os
        import sys
        import time

        STATUS = ${"\"" + statusDat + "\""}
        OUT = ${"\"" + outputFile + "\""}

        now = int(time.time())


        def parse_blocks(text, name):
            header = name + " {"
            out = []
            cur = None
            for raw in text.splitlines():
                s = raw.strip()
                if s == header:
                    cur = {}
                elif s == "}" and cur is not None:
                    out.append(cur)
                    cur = None
                elif cur is not None and "=" in s:
                    k, _, v = s.partition("=")
                    cur[k] = v
            return out


        services_critical = 0
        services_warning = 0
        services_unknown = 0
        services_suppressed = 0
        hosts_down = 0
        stale = 0
        parse_ok = 1


        def _suppressed(b):
            """True if Nagios would NOT notify for this object right now.

            These counts exist to mirror "what Nagios would page on" (see the header).
            Hard-state filtering alone does not achieve that: Nagios also stays silent
            for an object in SCHEDULED DOWNTIME and for an ACKNOWLEDGED problem.
            Counting those kept NagiosServicesCritical firing on 2026-07-30 for a
            service deliberately placed in downtime -- the bridge disagreeing with the
            very notification logic it documents itself as following.

            Suppressed objects are NOT discarded; they are counted separately, because
            dropping them silently would make "in downtime" indistinguishable from
            "recovered", and an object parked in permanent downtime is worth seeing.
            """
            depth = b.get("scheduled_downtime_depth", "0")
            acked = b.get("problem_has_been_acknowledged")
            return depth not in ("0", "", None) or acked == "1"


        try:
            with open(STATUS, "r", errors="replace") as fh:
                text = fh.read()
            svc = parse_blocks(text, "servicestatus")
            hosts = parse_blocks(text, "hoststatus")

            for b in svc:
                if b.get("has_been_checked") != "1":
                    continue
                if b.get("state_type") == "1":  # hard state only
                    st = b.get("current_state")
                    if st in ("1", "2", "3") and _suppressed(b):
                        services_suppressed += 1
                    elif st == "2":
                        services_critical += 1
                    elif st == "1":
                        services_warning += 1
                    elif st == "3":
                        services_unknown += 1
                # Staleness on active checks regardless of state.
                if b.get("active_checks_enabled") == "1":
                    try:
                        lc = float(b.get("last_check", "0") or 0)
                        iv = float(b.get("check_interval", "0") or 0) * 60.0
                    except ValueError:
                        lc = iv = 0.0
                    if iv > 0 and lc > 0 and (now - lc) > (2 * iv):
                        stale += 1

            for b in hosts:
                if b.get("has_been_checked") != "1":
                    continue
                if b.get("state_type") == "1" and b.get("current_state") in ("1", "2"):
                    hosts_down += 1
        except FileNotFoundError:
            parse_ok = 0
        except Exception:
            parse_ok = 0

        lines = [
            "# HELP nagios_services_critical_total Number of Nagios services in a HARD CRITICAL state",
            "# TYPE nagios_services_critical_total gauge",
            "nagios_services_critical_total %d" % services_critical,
            "# HELP nagios_services_warning_total Number of Nagios services in a HARD WARNING state",
            "# TYPE nagios_services_warning_total gauge",
            "nagios_services_warning_total %d" % services_warning,
            "# HELP nagios_services_unknown_total Number of Nagios services in a HARD UNKNOWN state",
            "# TYPE nagios_services_unknown_total gauge",
            "nagios_services_unknown_total %d" % services_unknown,
            "# HELP nagios_services_suppressed_total Non-OK HARD services Nagios will not notify on (scheduled downtime or acknowledged)",
            "# TYPE nagios_services_suppressed_total gauge",
            "nagios_services_suppressed_total %d" % services_suppressed,
            "# HELP nagios_hosts_down_total Number of Nagios hosts in a HARD DOWN or UNREACHABLE state",
            "# TYPE nagios_hosts_down_total gauge",
            "nagios_hosts_down_total %d" % hosts_down,
            "# HELP nagios_stale_results_total Number of active Nagios checks whose last_check is older than 2x their interval",
            "# TYPE nagios_stale_results_total gauge",
            "nagios_stale_results_total %d" % stale,
            "# HELP nagios_status_parse_success Whether the last status.dat parse succeeded (1) or failed (0)",
            "# TYPE nagios_status_parse_success gauge",
            "nagios_status_parse_success %d" % parse_ok,
            "# HELP nagios_status_exporter_run_timestamp_seconds Unix time of the last nagios-status-exporter run",
            "# TYPE nagios_status_exporter_run_timestamp_seconds gauge",
            "nagios_status_exporter_run_timestamp_seconds %d" % now,
            "",
        ]

        tmp = OUT + "." + str(os.getpid())
        with open(tmp, "w") as fh:
            fh.write("\n".join(lines))
        os.chmod(tmp, 0o644)
        os.replace(tmp, OUT)
        sys.exit(0)
      '';

  exporterScript = pkgs.writeShellScript "nagios-status-exporter" ''
    set -euo pipefail
    # status.dat is owned nagios:nagios (mode 664). The parser runs as root (so
    # it can read the file regardless of its mode) and writes the textfile into
    # the collector dir as 644. ReadOnlyPaths pins status.dat read-only for
    # defence in depth. Counts only — no host/service identifiers are ever
    # emitted.
    ${parseScript}
  '';
in
{
  # Nagios -> Prometheus aggregate-count bridge (textfile collector, no port).
  #
  # Runs as root (matching the other textfile collectors) so it can read the
  # nagios-owned status.dat and write the collector dir. The parser emits COUNTS
  # ONLY; it never writes host names, service descriptions, or plugin output.

  systemd.services.nagios-status-exporter = {
    description = "Nagios status.dat aggregate-count textfile exporter";
    after = [ "nagios.service" ];
    # No wantedBy - service only runs via timer.

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = exporterScript;

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

  systemd.timers.nagios-status-exporter = {
    description = "Timer for the Nagios status.dat aggregate-count exporter";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min"; # status.dat is rewritten each check cycle
      AccuracySec = "10s";
    };
  };
}
