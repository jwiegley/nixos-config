{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define JupyterLab monitoring rules as a separate file
  jupyterLabRulesFile = pkgs.writeText "jupyterlab-alerts.yml" ''
    groups:
    - name: jupyterlab_alerts
      interval: 60s
      rules:
      # Alert if JupyterLab systemd service is down
      #
      # 2026-07-28: metric repaired from `systemd_unit_state` to
      # `node_systemd_unit_state`. The former does not exist on this host (0 series
      # TSDB-wide); node-exporter's systemd collector publishes the latter (~3055
      # series). Before this fix all 9 rules in this group were incapable of firing.
      - alert: JupyterLabServiceDown
        expr: node_systemd_unit_state{name="jupyterlab.service",state="active"} == 0
        for: 2m
        labels:
          severity: critical
          service: jupyterlab
        annotations:
          summary: "JupyterLab service is down"
          description: "The JupyterLab service is not running. Check service status with 'systemctl status jupyterlab.service' and logs with 'journalctl -u jupyterlab.service -f'"

      # JupyterLabServiceFailed deleted 2026-07-28: strict subset of the host-wide
      #   SystemdServiceFailed rule (node_systemd_unit_state{state="failed"} == 1,
      #   for=60), whose selector was verified to include jupyterlab.service. Its own
      #   expr referenced the nonexistent `systemd_unit_state` and could never fire.

      # Alert if JupyterLab HTTPS endpoint is not responding
      #
      # 2026-07-28: job label repaired from "blackbox-https" (hyphen) to
      # "blackbox_https_local". The hyphenated job has never existed --
      # count(last_over_time(probe_success{job="blackbox-https"}[30d])) is empty -- and
      # the underscore job `blackbox_https` is a DIFFERENT job carrying only
      # https://google.com, so a naive hyphen-to-underscore swap would have left this
      # rule equally dead. jupyter is one of the 41 targets under blackbox_https_local.
      # Backtested: this expr would have fired on the real 2026-07-03 18:00-18:48 UTC
      # outage (~48 contiguous minutes of probe_success==0 at a 1m scrape interval),
      # and has 0 breach samples in the last 7 days.
      - alert: JupyterLabHttpsDown
        expr: probe_success{job="blackbox_https_local",instance="https://jupyter.vulcan.lan"} == 0
        for: 2m
        labels:
          severity: critical
          service: jupyterlab
        annotations:
          summary: "JupyterLab HTTPS endpoint is down"
          description: "JupyterLab is not responding to HTTPS requests at https://jupyter.vulcan.lan. Check nginx configuration and JupyterLab service status."

      # Alert if JupyterLab SSL certificate is expiring soon
      - alert: JupyterLabCertificateExpiringSoon
        # Job label repaired 2026-07-28 (see JupyterLabHttpsDown above). The
        # `- time()` form is already CORRECT here: probe_ssl_earliest_cert_expiry is an
        # absolute Unix epoch (verified live), so do NOT add a second `- time()` -- that
        # would yield expiry - 2*time(), go hugely negative, and fire forever. Only the
        # job label changed.
        # CORRECTED 2026-07-28: an earlier version claimed "nothing else watches jupyter's
        # served cert". FALSE. The file-based cert-exporter already tracks it --
        # certificate_days_until_expiry{name="jupyter.vulcan.lan",type="nginx"} = 337 --
        # and several fleet rules carry NO label selector at all, so they already match it
        # at both 30d and 7d (certificates/CertificateExpiringSoon,
        # certificate_alerts/CertificateExpiringSoon, certificate_alerts/
        # CertificateExpiryCritical, plus CertificateExpired and friends; note
        # certificate_alerts is currently loaded TWICE, so each counts double).
        # This rule is still worth keeping, but for a NARROWER reason than "nothing else
        # covers it": the cert-exporter reads the file ON DISK while this probes the cert
        # actually SERVED on the wire, so it is the only thing that catches
        # renewed-but-nginx-not-reloaded divergence. It IS otherwise redundant with the
        # existing 7d rule. (The generic SSLCertificate* probe rules are a separate matter
        # -- those select job="blackbox_https", which carries only google.com.)
        expr: probe_ssl_earliest_cert_expiry{job="blackbox_https_local",instance="https://jupyter.vulcan.lan"} - time() < 86400 * 7
        for: 1h
        labels:
          severity: warning
          service: jupyterlab
        annotations:
          summary: "JupyterLab SSL certificate expiring soon"
          description: "JupyterLab SSL certificate will expire in {{ $value | humanizeDuration }}. Run certificate renewal: '/etc/nixos/certs/renew-nginx-certs.sh'"

      # Alert if JupyterLab SSL certificate has expired
      - alert: JupyterLabCertificateExpired
        # Job label repaired 2026-07-28. Deliberately overlaps
        # JupyterLabCertificateExpiringSoon: any cert satisfying `< 0` also satisfies
        # `< 86400*7`, so an expired cert pages twice. Kept because that warn+crit
        # laddering is the established pattern here (SSLCertificateExpiringSoon +
        # SSLCertificateExpiringCritical, ShlinkSSLCertificateExpiring,
        # StockTraderCertificateExpiringSoon all coexist the same way).
        expr: probe_ssl_earliest_cert_expiry{job="blackbox_https_local",instance="https://jupyter.vulcan.lan"} - time() < 0
        for: 5m
        labels:
          severity: critical
          service: jupyterlab
        annotations:
          summary: "JupyterLab SSL certificate has expired"
          description: "JupyterLab SSL certificate has expired. Renew immediately: '/etc/nixos/certs/renew-nginx-certs.sh'"

      # Alert if JupyterLab HTTP response time is slow
      #
      # 2026-07-28, three separate defects fixed here:
      #  1. job label "blackbox-https" -> "blackbox_https_local" (see above).
      #  2. metric probe_http_duration_seconds -> probe_duration_seconds. CORRECTED
      #     2026-07-28: an earlier version of this comment claimed the old metric had
      #     "zero series on this host under any job". That was FALSE -- it has 205 series
      #     under blackbox_https_local alone (and exists under 9 other jobs), including
      #     jupyter. The actual defect is that blackbox publishes it PER PHASE: jupyter
      #     carries 5 series labelled phase=resolve|connect|tls|processing|transfer, so
      #     `probe_http_duration_seconds > 5` compared each phase INDEPENDENTLY and
      #     {{ $value }} would have reported a single phase rather than total response
      #     time. Fixing it in place would have required `sum by (instance) (...)`;
      #     probe_duration_seconds (total probe wall time) is the simpler correct signal.
      #  3. threshold 5s -> 1s. 5s was effectively unreachable on total probe time: the
      #     30-day maximum probe_duration_seconds with probe_success==1 is 0.2606s for
      #     jupyter (0.2032s for aria), so only an already-failing probe could exceed 5s
      #     -- and JupyterLabHttpsDown covers that. Headroom at 1s is 3.8x over the
      #     30-day MAXIMUM (0.2606s) and ~40x over the ~0.025s typical; quote the former,
      #     since the maximum is what determines false-fire risk. The threshold is
      #     genuinely reachable rather than merely quieter: summed per-phase HTTP duration
      #     for this instance peaked at 1.7999s within the same 30-day window.
      # The `and probe_success == 1` guard is what makes this a LATENCY rule rather than a
      # duplicate outage rule: without it, a timing-out probe reports a large duration and
      # would double-page alongside JupyterLabHttpsDown.
      - alert: JupyterLabSlowResponses
        expr: probe_duration_seconds{job="blackbox_https_local",instance="https://jupyter.vulcan.lan"} > 1 and probe_success{job="blackbox_https_local",instance="https://jupyter.vulcan.lan"} == 1
        for: 5m
        labels:
          severity: warning
          service: jupyterlab
        annotations:
          summary: "JupyterLab is responding slowly"
          description: "JupyterLab HTTP response time is {{ $value | humanizeDuration }} (over 1 second, against a ~0.02s normal). Check system resources and service logs."

      # JupyterLabFrequentRestarts deleted 2026-07-28: strict subset of the host-wide
      #   ServiceRestartLooping rule (group systemd_service_health,
      #   increase(node_systemd_service_restart_total{...}[30m]) > 3, for=300), whose
      #   selector was verified to include jupyterlab.service. Its own expr applied
      #   rate() to a TIMESTAMP gauge (systemd_unit_start_time_seconds), which is
      #   meaningless even had the metric existed -- and it does not.

      # JupyterLabHighMemoryUsage deleted 2026-07-28: no per-unit or per-cgroup memory
      #   metric exists on this host to re-point it to. The `systemd_unit` label has 0
      #   series TSDB-wide, there is no cgroup collector and no process-exporter, and
      #   process_resident_memory_bytes carries no jupyterlab series. A census of
      #   {__name__=~".*memory.*(current|high|max).*"} yields only
      #   process_virtual_memory_max_bytes, microvm_memory_current_bytes,
      #   redis_memory_max_bytes and grafana_*.
      #   COVERAGE NOTE, corrected 2026-07-28. An earlier version of this comment claimed
      #   "a single OOM-and-restart would go unpaged". That was FALSE and would have
      #   misled the next reader into building something already present: the live
      #   fleet rule KernelOOMKill (`increase(node_vmstat_oom_kill[15m]) > 0`, for=0,
      #   health=ok) pages on ANY kernel or memcg OOM, and jupyterlab has
      #   MemoryMax=8G so exceeding it is a memcg OOM, which the kernel counts in
      #   /proc/vmstat oom_kill. What is genuinely missing is narrower than claimed:
      #     - ATTRIBUTION: node_vmstat_oom_kill is host-scoped with no unit label, so the
      #       page says "something was OOM-killed", not "jupyterlab was".
      #     - PRE-OOM EARLY WARNING: nothing fires as the unit APPROACHES its limit.
      #   Only those two gaps justify M-92; scope it accordingly rather than on a
      #   nonexistent missing page.
      #   The mechanism in that earlier comment was also wrong in a load-bearing way. With
      #   Restart=on-failure systemd routes the unit through auto-restart, so it transits
      #   `activating`, NOT a ~10s `failed` window. Measured over 30 days:
      #   max_over_time(node_systemd_unit_state{name="jupyterlab.service",state="failed"})
      #   = 0 -- never once observed failed -- while the same query for state="activating"
      #   = 1. So raising RestartSec above 60s would NOT make SystemdServiceFailed catch
      #   this, which is exactly the wrong conclusion the old wording invited.

      # JupyterLabKernelIssue deleted 2026-07-28: its own expr referenced the nonexistent
      #   `systemd_unit_state` and so could never fire. The host-wide
      #   ServiceStuckActivating rule takes over, and jupyterlab.service is confirmed
      #   inside its selector (it is not in that rule's seven-unit exclusion list).
      #   DISCLOSED DWELL REGRESSION: "strict subset" is true of the SELECTOR but NOT of
      #   the dwell -- ServiceStuckActivating is for=900 (15m) against this rule's former
      #   for=300 (5m), so a hung SageMath kernel install is now detected 10 minutes
      #   later. Accepted as a deliberate trade (one host-wide rule beats nine per-service
      #   ones), but recorded rather than glossed: if the 5m latency ever matters for
      #   kernel installs specifically, the fix is a per-service rule with the CORRECT
      #   metric, not a resurrection of this one.
      #   For contrast, the other two deletions carry no such regression:
      #   SystemdServiceFailed's for=60 EQUALS the deleted child's 1m, and
      #   ServiceRestartLooping's for=300 is FASTER than the child's 600.
  '';
in
{
  # Prometheus alert rules for JupyterLab monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ jupyterLabRulesFile ];
}
