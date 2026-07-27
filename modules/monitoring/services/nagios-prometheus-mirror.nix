{
  config,
  lib,
  pkgs,
  ...
}:

# Tier 2 of the Nagios <-> Prometheus reverse mirror
# (docs/NAGIOS_PROMETHEUS_MIRROR_SPEC.md). Generated at BUILD TIME from the same
# rule YAML the three rulers consume, so the duplication is 100% by construction
# and can never drift: a NEW rule file is auto-mirrored on the next rebuild.
#
# For every alert rule in modules/monitoring/{alerts,loki-rules,vm-alerts}/*.yaml
# this emits one `define service` (PROM-MIRROR <alertname>) plus a writeText
# query file holding the expr verbatim. The check_prom_rule plugin re-evaluates
# that expr through Nagios's own scheduler/severity/notification path against the
# matching datasource's instant-query API. This is an independent alerting
# pipeline over the same data — it catches a wedged ruler, broken Alertmanager
# routing, or a silently-dead rule file (the 2026-06-09 123-dead-rules class).
#
# IFD NOTE: YAML->JSON happens in one pkgs.runCommand (remarshal) imported via
# builtins.fromJSON (builtins.readFile drv). Import-from-derivation is acceptable
# here (the repo builds locally and services.nagios.validateConfig already runs
# build-time `nagios -v`). If IFD ever becomes a problem the fallback is a
# checked-in generated JSON + drift assertion (spec 2.1) — not implemented.
#
# SECURITY: query files land world-readable in the nix store; rule exprs are
# public repo content (house rule: no secret may ever live in an alert expr).
# The plugin emits series COUNTS ONLY — never label values or response bodies.

let
  # --- the check_prom_rule plugin (stdlib-only, house writePython3Bin idiom) ---
  checkPromRule = pkgs.writers.writePython3Bin "check_prom_rule" {
    flakeIgnore = [
      "E501" # long lines (HELP text + dict literals)
      "W503" # line break before binary operator
      "E203" # whitespace before ':' (black-compatible)
      "E265" # writePython3Bin prepends its own shebang -> ours lands on line 2
    ];
  } (builtins.readFile ../../../scripts/check_prom_rule.py);

  # --- rule-file discovery (mirrors alerting.nix / vmalert.nix readDir) -------
  # datasource -> source directory (relative to this module).
  ruleDirs = {
    prometheus = ../alerts;
    loki = ../loki-rules;
    vm = ../vm-alerts;
  };

  yamlFilesIn =
    dir: builtins.filter (n: lib.hasSuffix ".yaml" n) (builtins.attrNames (builtins.readDir dir));

  # Flat list of { datasource, file (basename), path } for every *.yaml.
  fileEntries = lib.flatten (
    lib.mapAttrsToList (
      ds: dir:
      map (name: {
        datasource = ds;
        # Repo-relative label keyed into the JSON blob, e.g.
        # "alerts/application-services.yaml".
        relkey = "${baseNameOf (toString dir)}/${name}";
        # The actual source subdir name for the per-service comment line.
        subdir = baseNameOf (toString dir);
        inherit name;
        path = "${dir}/${name}";
      }) (yamlFilesIn dir)
    ) ruleDirs
  );

  # --- one runCommand: yaml2json every file into a single JSON object ---------
  # Keyed by "<subdir>/<file>" so we can recover the datasource + source file
  # for each rule on the Nix side.
  rulesJsonDrv = pkgs.runCommand "prom-mirror-rules.json" { } ''
    ${pkgs.coreutils}/bin/printf '{' > "$out"
    first=1
    ${lib.concatMapStringsSep "\n" (e: ''
      if [ "$first" -eq 0 ]; then ${pkgs.coreutils}/bin/printf ',' >> "$out"; fi
      first=0
      ${pkgs.coreutils}/bin/printf '%s:' ${lib.escapeShellArg (builtins.toJSON e.relkey)} >> "$out"
      ${pkgs.remarshal}/bin/remarshal -if yaml -of json < ${e.path} >> "$out"
    '') fileEntries}
    ${pkgs.coreutils}/bin/printf '}' >> "$out"
  '';

  rulesByKey = builtins.fromJSON (builtins.readFile rulesJsonDrv);

  # Look up the datasource for a relkey (from fileEntries).
  dsForKey = builtins.listToAttrs (
    map (e: {
      name = e.relkey;
      value = {
        inherit (e) datasource subdir name;
      };
    }) fileEntries
  );

  # --- exclusions (spec 2.4) — the COMPLETE list, 9 rules -------------------
  #   * Watchdog (meta-monitoring.yaml): fires-by-design dead-man; mirroring it
  #     is meaningless (it would page Nagios constantly by design).
  #   * ServiceStuckActivating (systemd.yaml): un-mirrorable by instant
  #     sampling. The expr is a broad multi-series selector where short-lived
  #     `activating` blips are NORMAL (a dozen frequent exporter oneshots are
  #     each activating for seconds-to-a-minute, many times an hour). The
  #     ruler's `for: 15m` requires ONE series continuously true; the mirror's
  #     max_check_attempts emulation only sees "some series true" at sparse
  #     5-minute instants, so a rotating cast of unrelated blips reads as one
  #     sustained condition. Observed 2026-06-11: mirror went HARD WARNING
  #     twice (04:26, 06:31) on different exporters each sample while the
  #     ruler stayed correctly silent — and missed the one genuine 17-minute
  #     event (02:00 postgresql-backup) to sampling phase. Tier-3 divergence
  #     auto-skips excluded rules (no mirror service => outside its universe).
  #   * BlackboxICMPIoTDeviceDown (network.yaml): un-mirrorable by instant
  #     sampling — same class as ServiceStuckActivating. The expr spans the
  #     sleepy Wi-Fi IoT fleet (host_group="iot", ~15 devices) probed by
  #     single-shot ICMP (5s at observation; 10s same-day via icmp_ping_iot
  #     in blackbox-monitoring.nix — softens but cannot eliminate the
  #     class); power-save wakeup latency makes per-instant blips routine
  #     (ring-doorbell measured 0% real loss yet 1.2s avg / 2.9s max RTT),
  #     so at nearly every sample SOME device reads as down. The ruler's `for: 1h`
  #     requires ONE device continuously down; the mirror's instant samples
  #     see "some series true" at almost every check, so a rotating cast of
  #     wakeup blips reads as one sustained condition. Observed 2026-06-12:
  #     mirror HARD WARNING for hours (13 distinct devices blipping in 2h,
  #     >=1 at every 10-min sample) while the ruler correctly stayed silent
  #     => chronic nagios_only divergence. Coverage retained: the live ruler
  #     rule (fires on any device down >=1h) plus Nagios's native PING
  #     services on the IoT fleet.
  #   * Every rule whose source file is alerts/nagios.yaml: Nagios checking "is
  #     Nagios up" through its own scheduler is circular; the Prometheus side
  #     owns those 6 rules.
  excludedAlertnames = [
    "Watchdog"
    "ServiceStuckActivating"
    "BlackboxICMPIoTDeviceDown"
  ];
  excludedFileKeys = [ "alerts/nagios.yaml" ];

  # --- flatten groups[].rules[] into a rule list -----------------------------
  # Each: { alertname, expr, for, severity, datasource, subdir, file }.
  rawRules = lib.flatten (
    lib.mapAttrsToList (
      relkey: doc:
      let
        meta = dsForKey.${relkey};
        groups = doc.groups or [ ];
      in
      lib.flatten (
        map (
          group:
          map (rule: {
            alertname = rule.alert;
            expr = rule.expr;
            for = rule."for" or "0m";
            severity = (rule.labels or { }).severity or "warning";
            datasource = meta.datasource;
            subdir = meta.subdir;
            file = relkey;
          }) (builtins.filter (r: r ? alert) (group.rules or [ ]))
        ) groups
      )
    ) rulesByKey
  );

  # Apply exclusions.
  keptRules = builtins.filter (
    r: !(lib.elem r.alertname excludedAlertnames) && !(lib.elem r.file excludedFileKeys)
  ) rawRules;

  # --- dedupe alertnames across the WHOLE set --------------------------------
  # foldl' with a seen-count accumulator; first occurrence keeps the bare name,
  # subsequent collisions get "-2", "-3", ... The accumulator carries both the
  # running seen-count map and the rules-with-resolved-svcname list.
  dedupeAcc =
    lib.foldl'
      (
        acc: r:
        let
          n = r.alertname;
          prior = acc.seen.${n} or 0;
          count = prior + 1;
          svc = if count == 1 then n else "${n}-${toString count}";
        in
        {
          seen = acc.seen // {
            ${n} = count;
          };
          rules = acc.rules ++ [ (r // { svcname = svc; }) ];
        }
      )
      {
        seen = { };
        rules = [ ];
      }
      keptRules;

  mirrorRules = dedupeAcc.rules;

  # --- duration parsing (Prometheus-style "30s"/"5m"/"1h"/"3d"/"2h30m"/"0m") --
  # Returns whole minutes, rounding any sub-minute remainder UP to 1 minute.
  # Units present in the corpus: s, m, h, d (verified); w supported for safety.
  unitSeconds = {
    s = 1;
    m = 60;
    h = 3600;
    d = 86400;
    w = 604800;
  };

  # Tokenize a duration string into [{num, unit}] pairs. Implemented by walking
  # the characters: accumulate digits, then on a letter flush (digits, letter).
  parseDurationSeconds =
    str:
    let
      chars = lib.stringToCharacters str;
      step =
        st: c:
        if (builtins.match "[0-9]" c) != null then
          st // { numbuf = st.numbuf + c; }
        else if (lib.hasAttr c unitSeconds) && st.numbuf != "" then
          {
            numbuf = "";
            total = st.total + (lib.toInt st.numbuf) * unitSeconds.${c};
          }
        else
          # Unknown char or unit with no preceding number: ignore (defensive;
          # the corpus has no such cases). A bare "0" with no unit also lands
          # here and contributes nothing -> 0s, the intended result.
          st;
      result = lib.foldl' step {
        numbuf = "";
        total = 0;
      } chars;
    in
    result.total;

  # for: in whole minutes, sub-minute rounded up (so 30s -> 1m).
  forMinutes =
    str:
    let
      secs = parseDurationSeconds str;
    in
    if secs == 0 then 0 else (secs + 59) / 60; # integer ceil-div to minutes

  # ceil(a / b) for positive ints.
  ceilDiv = a: b: (a + b - 1) / b;

  clamp =
    lo: hi: x:
    if x < lo then
      lo
    else if x > hi then
      hi
    else
      x;

  # --- per-severity template + retry_interval (from nagios.nix templates) ----
  # critical -> standard-service (check 5m, retry 2m); warning|info ->
  # low-priority-service (check 15m, retry 5m). We deliberately do NOT use the
  # 2m critical-service template (single check worker; ARM64 SEGV workaround).
  templateFor = sev: if sev == "critical" then "standard-service" else "low-priority-service";
  retryMinutesFor = sev: if sev == "critical" then 2 else 5;

  # max_check_attempts = clamp(1 + ceil(for / retry_interval), 1, 20).
  maxCheckAttempts =
    r:
    let
      fm = forMinutes r.for;
      retry = retryMinutesFor r.severity;
      raw = 1 + (if fm == 0 then 0 else ceilDiv fm retry);
    in
    clamp 1 20 raw;

  # --- per-rule query file (expr verbatim; sidesteps Nagios $ARG$ escaping) ---
  queryFileFor = r: pkgs.writeText "prom-mirror-${r.svcname}.promql" r.expr;

  # Datasource -> servicegroup membership (umbrella + per-ds for the dependency
  # storm-guard). Every mirror joins "prometheus-mirror" plus one of the three
  # per-ds groups so a single servicedependency keyed on the per-ds group can
  # couple all of that ds's mirrors to that ds's API health check.
  dsServiceGroup = ds: "prometheus-mirror-${ds}";

  # --- emit one `define service` block per rule ------------------------------
  serviceBlock =
    r:
    let
      qf = queryFileFor r;
      tmpl = templateFor r.severity;
      mca = maxCheckAttempts r;
      fm = forMinutes r.for;
      retry = retryMinutesFor r.severity;
    in
    ''
      # source: modules/monitoring/${r.file}  (ruler datasource: ${r.datasource})
      # for: ${r.for} approximated by max_check_attempts=${toString mca}
      #   (1 + ceil(${toString fm}m / ${toString retry}m retry_interval), clamped 1..20)
      define service {
        use                     ${tmpl}
        host_name               vulcan
        service_description     PROM-MIRROR ${r.svcname}
        check_command           check_prom_rule!${r.datasource}!${qf}!${r.severity}
        servicegroups           prometheus-mirror,${dsServiceGroup r.datasource}
        max_check_attempts      ${toString mca}
        # notifications_enabled 0: the mirror is a silent BACKSTOP, not a
        # second email channel. Alertmanager already emails every Prometheus
        # alert; these mirror checks duplicated it (2026-07-21: the same alerts
        # arrived from both alertmanager@ and Nagios PROM-MIRROR). Keep them as
        # Nagios checks (state stays visible + the divergence reconciler still
        # catches a silently-dead Prometheus rule), but don't notify. Re-enable
        # if Alertmanager email ever becomes unreliable.
        notifications_enabled   0
      }
    '';

  serviceBlocks = lib.concatMapStringsSep "\n" serviceBlock mirrorRules;

  # --- notification-storm guard (spec 2.3) -----------------------------------
  # One health check per datasource. When a ruler API is down, a
  # servicedependency keyed on that datasource's servicegroup suppresses the
  # mirror checks/notifications (so Nagios does not emit one UNKNOWN per mirror
  # — 480 of them as of 2026-07-27); the
  # API-down condition itself pages.
  #
  # Health endpoints verified live 2026-06-10:
  #   prometheus 127.0.0.1:9090/-/healthy  -> 200
  #   loki       127.0.0.1:3100/ready      -> 200 (503 only during the ~15s
  #                                                 post-ready ingester warmup)
  #   vm         127.0.0.1:8428/health     -> 200
  # check_http (global command in nagios.nix) targets $HOSTADDRESS$ (vulcan);
  # these are loopback services, so we use a dedicated command that hits
  # 127.0.0.1 on the explicit port/path instead.
  checkPromMirrorApi = pkgs.writeShellScript "check_prom_mirror_api.sh" ''
    set -uo pipefail
    PORT="''${1:?port}"
    URLPATH="''${2:?path}"
    NAME="''${3:-API}"
    CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout 5 --max-time 10 \
      "http://127.0.0.1:$PORT$URLPATH" 2>/dev/null) || CODE="000"
    if [ "$CODE" = "200" ]; then
      echo "OK: $NAME healthy (HTTP $CODE)"
      exit 0
    fi
    echo "CRITICAL: $NAME unhealthy (HTTP $CODE)"
    exit 2
  '';

  apiServiceBlocks = ''
    # Prometheus ruler API health (storm-guard master for datasource=prometheus)
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     PROM-MIRROR prometheus API
      check_command           check_prom_mirror_api!9090!/-/healthy!Prometheus
      servicegroups           prometheus-mirror
    }

    # Loki ruler API health (storm-guard master for datasource=loki)
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     PROM-MIRROR loki API
      check_command           check_prom_mirror_api!3100!/ready!Loki
      servicegroups           prometheus-mirror
    }

    # VictoriaMetrics / vmalert TSDB API health (storm-guard master for datasource=vm)
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     PROM-MIRROR vm API
      check_command           check_prom_mirror_api!8428!/health!VictoriaMetrics
      servicegroups           prometheus-mirror
    }
  '';

  # One servicedependency per datasource: when the per-ds API service is in a
  # bad state, suppress execution (u,c) and notifications (u,c,w) of every
  # mirror in that ds's servicegroup. dependent_servicegroup_name fans the
  # dependency across all members without listing 400+ services explicitly.
  #
  # NOTE: dependent_host_name is deliberately OMITTED. Nagios 4.5 fails config
  # validation ("Could not expand dependent service(s)") when a
  # servicedependency combines dependent_host_name WITH
  # dependent_servicegroup_name (verified against nagios 4.5.10 -v, 2026-06-10).
  # The servicegroup already scopes the dependents to host vulcan (every member
  # is a vulcan service), so the host name is redundant anyway.
  dependencyBlock = ds: apiSvc: ''
    define servicedependency {
      host_name                       vulcan
      service_description             ${apiSvc}
      dependent_servicegroup_name     ${dsServiceGroup ds}
      execution_failure_criteria      u,c
      notification_failure_criteria   u,c,w
    }
  '';

  dependencyBlocks = lib.concatStrings [
    (dependencyBlock "prometheus" "PROM-MIRROR prometheus API")
    (dependencyBlock "loki" "PROM-MIRROR loki API")
    (dependencyBlock "vm" "PROM-MIRROR vm API")
  ];

  mirrorObjectDefs = pkgs.writeText "nagios-prometheus-mirror.cfg" ''
    # ==========================================================================
    # Nagios <-> Prometheus reverse mirror — Tier 2 (GENERATED, do not hand-edit)
    # docs/NAGIOS_PROMETHEUS_MIRROR_SPEC.md
    # ${toString (builtins.length mirrorRules)} mirror services
    # (484 rules - 8 excluded [Watchdog + ServiceStuckActivating + 6 in alerts/nagios.yaml]).
    # ==========================================================================

    define command {
      command_name    check_prom_rule
      command_line    ${checkPromRule}/bin/check_prom_rule --datasource $ARG1$ --query-file $ARG2$ --severity $ARG3$
    }

    define command {
      command_name    check_prom_mirror_api
      command_line    ${checkPromMirrorApi} $ARG1$ $ARG2$ $ARG3$
    }

    define servicegroup {
      servicegroup_name   prometheus-mirror
      alias               Prometheus rule mirrors
    }

    define servicegroup {
      servicegroup_name   prometheus-mirror-prometheus
      alias               Prometheus rule mirrors (prometheus datasource)
    }

    define servicegroup {
      servicegroup_name   prometheus-mirror-loki
      alias               Prometheus rule mirrors (loki datasource)
    }

    define servicegroup {
      servicegroup_name   prometheus-mirror-vm
      alias               Prometheus rule mirrors (vm datasource)
    }

    # --------------------------------------------------------------------------
    # Datasource API health checks (notification-storm guard masters)
    # --------------------------------------------------------------------------
    ${apiServiceBlocks}

    # --------------------------------------------------------------------------
    # Storm-guard dependencies: a down ruler API suppresses its mirrors
    # --------------------------------------------------------------------------
    ${dependencyBlocks}

    # --------------------------------------------------------------------------
    # Mirror services (one per non-excluded alert rule)
    # --------------------------------------------------------------------------
    ${serviceBlocks}
  '';
in
{
  services.nagios.objectDefs = [ mirrorObjectDefs ];
}
