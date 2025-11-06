{ config, lib, pkgs, ... }:

let
  # Define JupyterLab monitoring rules as a separate file
  jupyterLabRulesFile = pkgs.writeText "jupyterlab-alerts.yml" ''
    groups:
    - name: jupyterlab_alerts
      interval: 60s
      rules:
      # Alert if JupyterLab systemd service is down
      - alert: JupyterLabServiceDown
        expr: systemd_unit_state{name="jupyterlab.service",state="active"} == 0
        for: 2m
        labels:
          severity: critical
          service: jupyterlab
        annotations:
          summary: "JupyterLab service is down"
          description: "The JupyterLab service is not running. Check service status with 'systemctl status jupyterlab.service' and logs with 'journalctl -u jupyterlab.service -f'"

      # Alert if JupyterLab systemd service is failed
      - alert: JupyterLabServiceFailed
        expr: systemd_unit_state{name="jupyterlab.service",state="failed"} == 1
        for: 1m
        labels:
          severity: critical
          service: jupyterlab
        annotations:
          summary: "JupyterLab service has failed"
          description: "The JupyterLab service is in failed state. Check logs immediately with 'journalctl -u jupyterlab.service -n 100'"

      # Alert if JupyterLab HTTPS endpoint is not responding
      - alert: JupyterLabHttpsDown
        expr: probe_success{job="blackbox-https",instance="https://jupyter.vulcan.lan"} == 0
        for: 2m
        labels:
          severity: critical
          service: jupyterlab
        annotations:
          summary: "JupyterLab HTTPS endpoint is down"
          description: "JupyterLab is not responding to HTTPS requests at https://jupyter.vulcan.lan. Check nginx configuration and JupyterLab service status."

      # Alert if JupyterLab SSL certificate is expiring soon
      - alert: JupyterLabCertificateExpiringSoon
        expr: probe_ssl_earliest_cert_expiry{job="blackbox-https",instance="https://jupyter.vulcan.lan"} - time() < 86400 * 7
        for: 1h
        labels:
          severity: warning
          service: jupyterlab
        annotations:
          summary: "JupyterLab SSL certificate expiring soon"
          description: "JupyterLab SSL certificate will expire in {{ $value | humanizeDuration }}. Run certificate renewal: '/etc/nixos/certs/renew-nginx-certs.sh'"

      # Alert if JupyterLab SSL certificate has expired
      - alert: JupyterLabCertificateExpired
        expr: probe_ssl_earliest_cert_expiry{job="blackbox-https",instance="https://jupyter.vulcan.lan"} - time() < 0
        for: 5m
        labels:
          severity: critical
          service: jupyterlab
        annotations:
          summary: "JupyterLab SSL certificate has expired"
          description: "JupyterLab SSL certificate has expired. Renew immediately: '/etc/nixos/certs/renew-nginx-certs.sh'"

      # Alert if JupyterLab HTTP response time is slow
      - alert: JupyterLabSlowResponses
        expr: probe_http_duration_seconds{job="blackbox-https",instance="https://jupyter.vulcan.lan"} > 5
        for: 5m
        labels:
          severity: warning
          service: jupyterlab
        annotations:
          summary: "JupyterLab is responding slowly"
          description: "JupyterLab HTTP response time is {{ $value | humanizeDuration }} (over 5 seconds). Check system resources and service logs."

      # Alert if JupyterLab service restarts frequently
      - alert: JupyterLabFrequentRestarts
        expr: rate(systemd_unit_start_time_seconds{name="jupyterlab.service"}[30m]) > 0.05
        for: 10m
        labels:
          severity: warning
          service: jupyterlab
        annotations:
          summary: "JupyterLab is restarting frequently"
          description: "JupyterLab has restarted {{ $value | humanize }} times in the last 30 minutes. Check logs for errors: 'journalctl -u jupyterlab.service -n 200'"

      # Alert if JupyterLab memory usage is very high (if process metrics available)
      - alert: JupyterLabHighMemoryUsage
        expr: sum(process_resident_memory_bytes{systemd_unit="jupyterlab.service"}) > 7516192768
        for: 15m
        labels:
          severity: warning
          service: jupyterlab
        annotations:
          summary: "JupyterLab memory usage is high"
          description: "JupyterLab is using {{ $value | humanize1024 }}B of memory (over 7GB out of 8GB limit). Consider investigating memory-intensive notebooks or kernel issues."

      # Alert if SageMath kernel installation failed
      - alert: JupyterLabKernelIssue
        expr: systemd_unit_state{name="jupyterlab.service",state="activating"} == 1
        for: 5m
        labels:
          severity: warning
          service: jupyterlab
        annotations:
          summary: "JupyterLab is stuck activating"
          description: "JupyterLab service has been in 'activating' state for over 5 minutes. This may indicate kernel installation issues. Check logs: 'journalctl -u jupyterlab.service -f'"
  '';
in
{
  # Prometheus alert rules for JupyterLab monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ jupyterLabRulesFile ];
}
