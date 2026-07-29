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
        # job label changed. Nothing else watches jupyter's served cert: the generic
        # SSLCertificate* rules select job="blackbox_https", which is google.com only.
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
      #  2. metric probe_http_duration_seconds -> probe_duration_seconds. The former has
      #     zero series on this host under any job.
      #  3. threshold 5s -> 1s. A 5s threshold was UNREACHABLE while the endpoint works:
      #     the 30-day maximum probe_duration_seconds with probe_success==1 is 0.26s for
      #     jupyter (0.20s for aria), and the blackbox module's own timeout is 10s, so the
      #     only way to exceed 5s was a probe already failing -- which JupyterLabHttpsDown
      #     covers. Live duration is ~0.02s, so 1s is ~40x headroom over normal.
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
      #   HONEST COVERAGE NOTE: an OOM kill here is only PARTIALLY covered. jupyterlab
      #   runs OOMPolicy=stop with Restart=on-failure and RestartSec=10s, so its `failed`
      #   window after an OOM is roughly 10s -- BELOW SystemdServiceFailed's for=60. A
      #   single OOM-and-restart would therefore go unpaged; only a restart LOOP trips
      #   ServiceRestartLooping. Do not record this as covered. Closing it properly needs
      #   the per-cgroup exporter tracked as M-92.

      # JupyterLabKernelIssue deleted 2026-07-28: strict subset of the host-wide
      #   ServiceStuckActivating rule, and its own expr referenced the nonexistent
      #   `systemd_unit_state`.
  '';
in
{
  # Prometheus alert rules for JupyterLab monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ jupyterLabRulesFile ];
}
