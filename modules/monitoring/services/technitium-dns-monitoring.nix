{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/prometheus-node-exporter-textfiles";
  outputFile = "${textfileDir}/dns_correctness.prom";

  # DNS correctness collector (P2, dns domain). The blackbox dns_internal probe
  # (P0 #9) and the technitium_dns_* exporter cover availability and query-
  # outcome rates, but two correctness properties of the local resolver have NO
  # backing metric and cannot be expressed as a blackbox `dns` module on this
  # host (blackbox-monitoring.nix is owned by another workstream this round):
  #
  #   1. DNSSEC validation. A *validating* resolver must SERVFAIL on the
  #      deliberately-broken zone dnssec-failed.org. If it returns NOERROR,
  #      validation is OFF — the resolver is accepting forged/expired
  #      signatures. Live evidence (2026-06-10): dnssec-failed.org -> SERVFAIL,
  #      i.e. validation is currently ACTIVE, so the gauge reads 1 and the
  #      DNSSECValidationInactive alert will NOT fire on deploy.
  #
  #   2. Reverse (PTR) resolution. The local zone's reverse lookup for the host
  #      itself must resolve. Live evidence (2026-06-10): `dig -x 192.168.1.2`
  #      returns `vulcan.` (NOT `vulcan.lan.` — the host's own PTR is the bare
  #      `vulcan`; the router uses `router.lan.`). We therefore match the
  #      ACTUAL configured value `vulcan.` so the gauge reads 1 today and
  #      DNSPTRBroken does not false-fire.
  #
  # All lookups are local (@127.0.0.1) with a short 3s timeout and a single try
  # so the oneshot can never hang the timer. The collector emits, atomically:
  #   dns_dnssec_validation_active   1 iff dnssec-failed.org -> SERVFAIL
  #   dns_ptr_correct                1 iff PTR(192.168.1.2) == vulcan.
  #   dns_correctness_probe_errors   count of dig invocations that errored
  #                                  (timeout / no reply / connection refused)
  #   dns_correctness_run_timestamp_seconds  last run (collector liveness)
  #
  # A probe that simply gets no rcode (resolver unreachable) leaves the
  # corresponding gauge at 0 AND increments probe_errors, so a resolver outage
  # trips both DNSSECValidationInactive/DNSPTRBroken and is distinguishable
  # from a genuine "validation turned off / PTR record changed" via the
  # probe-error gauge.

  dig = "${pkgs.dnsutils}/bin/dig";

  exporterScript = pkgs.writeShellScript "dns-correctness-exporter" ''
    set -uo pipefail

    NOW=$(${pkgs.coreutils}/bin/date +%s)
    ERRORS=0

    # --- (1) DNSSEC validation: dnssec-failed.org must SERVFAIL ---
    DNSSEC_RCODE=$(${dig} +time=3 +tries=1 @127.0.0.1 dnssec-failed.org A +noall +comments 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -oE 'status: [A-Z]+' | ${pkgs.coreutils}/bin/head -1 | ${pkgs.gnused}/bin/sed 's/status: //') || DNSSEC_RCODE=""
    if [ -z "$DNSSEC_RCODE" ]; then
      # No rcode at all => resolver did not answer (timeout / refused).
      DNSSEC_VALID=0
      ERRORS=$((ERRORS + 1))
    elif [ "$DNSSEC_RCODE" = "SERVFAIL" ]; then
      DNSSEC_VALID=1
    else
      # NOERROR (validation OFF) or any other non-SERVFAIL rcode => not validating.
      DNSSEC_VALID=0
    fi

    # --- (2) PTR correctness: dig -x 192.168.1.2 must resolve to vulcan. ---
    PTR_ANSWER=$(${dig} +time=3 +tries=1 +short -x 192.168.1.2 @127.0.0.1 2>/dev/null \
      | ${pkgs.coreutils}/bin/head -1) || PTR_ANSWER=""
    if [ -z "$PTR_ANSWER" ]; then
      PTR_OK=0
      ERRORS=$((ERRORS + 1))
    elif [ "$PTR_ANSWER" = "vulcan." ]; then
      PTR_OK=1
    else
      PTR_OK=0
    fi

    TEMP_OUT=${outputFile}.$$
    ${pkgs.coreutils}/bin/cat > "$TEMP_OUT" <<EOF
    # HELP dns_dnssec_validation_active 1 if the local resolver SERVFAILs on dnssec-failed.org (DNSSEC validation active), 0 if it accepts the bad zone (validation OFF) or did not answer
    # TYPE dns_dnssec_validation_active gauge
    dns_dnssec_validation_active $DNSSEC_VALID

    # HELP dns_ptr_correct 1 if the reverse lookup of 192.168.1.2 returns vulcan. (PTR resolution correct), 0 if wrong/missing or no answer
    # TYPE dns_ptr_correct gauge
    dns_ptr_correct $PTR_OK

    # HELP dns_correctness_probe_errors Number of dig probes in the last run that returned no answer (resolver unreachable); distinguishes a wrong record from a dead resolver
    # TYPE dns_correctness_probe_errors gauge
    dns_correctness_probe_errors $ERRORS

    # HELP dns_correctness_run_timestamp_seconds Unix time of the last dns-correctness-exporter run (collector liveness)
    # TYPE dns_correctness_run_timestamp_seconds gauge
    dns_correctness_run_timestamp_seconds $NOW
    EOF

    ${pkgs.coreutils}/bin/mv "$TEMP_OUT" ${outputFile}
    ${pkgs.coreutils}/bin/chmod 644 ${outputFile}
  '';
in
{
  # Prometheus scrape configuration for Technitium DNS metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "technitium_dns";
      static_configs = [
        {
          targets = [ "localhost:9274" ];
          labels = {
            alias = "vulcan-dns";
            role = "dns-server";
            service = "technitium";
          };
        }
      ];
      scrape_interval = "60s";
      scrape_timeout = "10s";
    }
  ];

  # DNS-correctness textfile collector (DNSSEC validation + PTR).
  #
  # Runs as root (matching nodered-safety-exporter.nix / container-health-
  # exporter.nix) and writes a single atomic .prom into the node-exporter
  # textfile dir. The probes are local DNS queries only — no secrets, no PII;
  # the output is four gauges. Alert rules live in
  # modules/monitoring/alerts/dns.yaml.
  systemd.services.dns-correctness-exporter = {
    description = "DNS correctness exporter (DNSSEC validation + PTR) for the local Technitium resolver";
    after = [
      "network.target"
      "technitium-dns-server.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = exporterScript;

      # Hardening (collector only reads DNS and writes one textfile).
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
      ReadWritePaths = [ textfileDir ];
    };
  };

  systemd.timers.dns-correctness-exporter = {
    description = "Timer for the DNS-correctness exporter (DNSSEC + PTR)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
      AccuracySec = "15s";
    };
  };
}
