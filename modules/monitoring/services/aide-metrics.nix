{
  config,
  lib,
  pkgs,
  ...
}:

# AIDE **database** dead-man collector.
#
# SCOPE (deliberately narrow since 2026-07-29): this collector emits ONLY
#   aide_database_exists
#   aide_database_age_seconds
# and it does NOT run `aide --check`.
#
# Why it used to do more, and why it must not any more: this file previously
# parsed its OWN full `aide --check` walk into aide.prom (aide_check_status,
# aide_added/removed/changed_files, aide_total_entries) while
# modules/security/aide.nix separately derived aide_changes_detected from the
# same check's exit status. Two independent computations of one security fact
# drifted, and live they contradicted each other outright: aide_check_status=0
# ("clean") in the same scrape as aide_changes_detected=1 and
# aide_changed_files=71. Root cause was the shape
#     CHECK_OUTPUT=$(aide --check 2>&1 || true); EXIT_CODE=$?
# — `|| true` makes the substitution succeed, so EXIT_CODE was ALWAYS 0, which
# pinned aide_check_status at 0 forever and made both AIDEChangesDetected and
# AIDECheckError structurally unfirable. All of those check-derived metrics now
# come from the single walk in aide-check.service's ExecStart wrapper
# (modules/security/aide.nix), which keeps the real exit code.
#
# Why the database metrics STAY here, separately: they are the only dead-man for
# "aide-check never ran at all". If they were folded into the check's emitter
# they would freeze in lockstep with the very failure they are meant to detect.
# Staleness coverage, corrected 2026-08-19: aide.prom -- the file THIS collector
# writes -- IS on the TextfileCollectorStaleDaily allowlist
# (meta-monitoring.yaml, >26h). It was added there on 2026-07-31, which is when
# the old "aide*.prom is in NEITHER tier" claim went stale. The daily timer below
# is what keeps aide.prom inside that 26h window. aide_result.prom (written by
# aide-check, modules/security/aide.nix) is still on no tier allowlist and is
# caught only by the loose 14-day TextfileCollectorUnclassifiedStale backstop, so
# this collector's independence remains the primary freshness signal for the
# check itself. Alerts AIDEDatabaseMissing / AIDEDatabaseStale (security.yaml)
# read these two gauges.
#
# Cheap by construction: a stat(2), no filesystem walk, so it is also wired as
# an ExecStartPre on aide-check.service (see below).

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";

  aideDbMetrics = pkgs.writeShellScript "aide-db-metrics" ''
    set -u
    OUTPUT_FILE="${textfileDir}/aide.prom"
    TEMP_FILE="$OUTPUT_FILE.$$"
    DB_PATH=/var/lib/aide/aide.db

    if [ -f "$DB_PATH" ]; then
      EXISTS=1
      AGE=$(( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$DB_PATH") ))
    else
      EXISTS=0
      AGE=0
    fi

    [ -d "${textfileDir}" ] || ${pkgs.coreutils}/bin/mkdir -p "${textfileDir}"
    {
      ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_database_exists Whether the AIDE integrity database exists'
      ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_database_exists gauge'
      ${pkgs.coreutils}/bin/printf 'aide_database_exists %s\n' "$EXISTS"
      ${pkgs.coreutils}/bin/printf '%s\n' '# HELP aide_database_age_seconds Age of the AIDE integrity database in seconds'
      ${pkgs.coreutils}/bin/printf '%s\n' '# TYPE aide_database_age_seconds gauge'
      ${pkgs.coreutils}/bin/printf 'aide_database_age_seconds %s\n' "$AGE"
    } > "$TEMP_FILE"
    ${pkgs.coreutils}/bin/chmod 0644 "$TEMP_FILE"
    ${pkgs.coreutils}/bin/mv -f "$TEMP_FILE" "$OUTPUT_FILE"
  '';

in
{
  systemd.services.aide-metrics = {
    description = "Collect AIDE database freshness metrics for Prometheus";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${aideDbMetrics}";
      User = "root";
    };
  };

  # Also refresh the database gauges immediately BEFORE each check. Two reasons:
  #   1. it keeps aide_database_age_seconds honest at the moment the check runs;
  #   2. it guarantees aide.prom has been rewritten in its new (db-only) form
  #      before aide-check's ExecStart writes aide_check_status into
  #      aide_result.prom, so the two textfiles can never both declare the same
  #      metric family in one scrape (which node-exporter reports as a textfile
  #      collector error). This matters only in the window right after the
  #      switch that introduced the split, but it is free.
  # `-` prefix: a failure here must never prevent the integrity check itself.
  # Runs BEFORE ExecStart, so it does NOT add a filesystem walk.
  systemd.services.aide-check.serviceConfig.ExecStartPre = [
    "-${aideDbMetrics}"
  ];

  # Independent daily timer — the dead-man. Must stay independent of
  # aide-check.timer: if the check stops running, aide_database_age_seconds has
  # to keep climbing so AIDEDatabaseStale can fire.
  systemd.timers.aide-metrics = {
    description = "Collect AIDE database freshness metrics daily";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };

  # Defensive, not corrective: nixpkgs already defaults `wantedBy` to [ ]
  # (nixos/lib/systemd-unit-options.nix), so there is no multi-user.target
  # default to undo. The mkForce just guarantees that no other definition of
  # this option can pull aide-metrics.service into a boot target. The service is
  # started by aide-metrics.timer above.
  systemd.services.aide-metrics.wantedBy = lib.mkForce [ ];
}
