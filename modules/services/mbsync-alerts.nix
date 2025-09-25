{ config, lib, pkgs, ... }:

{
  # Prometheus alert rules for mbsync monitoring
  services.prometheus.rules = lib.mkIf config.services.prometheus.enable [
    (builtins.toJSON {
      groups = [
        {
          name = "mbsync_alerts";
          interval = "30s";
          rules = [
            # Alert if mbsync hasn't run successfully in the last 2 hours
            {
              alert = "MbsyncSyncStale";
              expr = ''(time() - mbsync_last_success_timestamp) > 7200'';
              for = "5m";
              labels = {
                severity = "warning";
                service = "mbsync";
              };
              annotations = {
                summary = "mbsync hasn't synchronized successfully in over 2 hours";
                description = "The last successful mbsync synchronization was {{ $value | humanizeDuration }} ago. Check the mbsync-assembly service and logs.";
              };
            }

            # Alert if mbsync sync is failing
            {
              alert = "MbsyncSyncFailing";
              expr = ''mbsync_sync_status == 0'';
              for = "15m";
              labels = {
                severity = "critical";
                service = "mbsync";
              };
              annotations = {
                summary = "mbsync synchronization is failing";
                description = "mbsync has been failing for at least 15 minutes. Check /var/log/mbsync/sync.log for errors.";
              };
            }

            # Alert if mbsync service is down
            {
              alert = "MbsyncServiceDown";
              expr = ''up{job="mbsync"} == 0'';
              for = "5m";
              labels = {
                severity = "critical";
                service = "mbsync";
              };
              annotations = {
                summary = "mbsync metrics exporter is down";
                description = "The mbsync metrics exporter has been down for 5 minutes. The service may be crashed.";
              };
            }

            # Alert on rapid decrease in inbox messages (possible deletion issue)
            {
              alert = "MbsyncInboxMessagesDropped";
              expr = ''(mbsync_inbox_messages < (mbsync_inbox_messages offset 1h) * 0.5) and (mbsync_inbox_messages offset 1h) > 10'';
              for = "5m";
              labels = {
                severity = "warning";
                service = "mbsync";
              };
              annotations = {
                summary = "Significant drop in INBOX message count";
                description = "INBOX message count dropped by more than 50% in the last hour (current value: {{ $value }}). This might indicate a sync issue.";
              };
            }

            # Alert if last failure is more recent than last success
            {
              alert = "MbsyncRecentFailure";
              expr = ''mbsync_last_failure_timestamp > mbsync_last_success_timestamp'';
              for = "30m";
              labels = {
                severity = "warning";
                service = "mbsync";
              };
              annotations = {
                summary = "mbsync has recent failures";
                description = "The most recent mbsync attempt failed. Last failure was more recent than last success.";
              };
            }

            # Alert if timer is not running
            {
              alert = "MbsyncTimerInactive";
              expr = ''systemd_unit_state{name="mbsync-assembly.timer"} != 1'';
              for = "10m";
              labels = {
                severity = "warning";
                service = "mbsync";
              };
              annotations = {
                summary = "mbsync timer is not active";
                description = "The mbsync-assembly.timer is not active. Automatic synchronization is disabled.";
              };
            }
          ];
        }
      ];
    })
  ];

  # Add alertmanager configuration for mbsync alerts
  services.prometheus.alertmanager.configuration = lib.mkIf config.services.prometheus.alertmanager.enable {
    route.routes = lib.mkAfter [
      {
        match = { service = "mbsync"; };
        group_by = ["alertname"];
        group_wait = "10s";
        group_interval = "5m";
        repeat_interval = "1h";
        receiver = "mbsync-alerts";
      }
    ];

    receivers = lib.mkAfter [
      {
        name = "mbsync-alerts";
        # Configure your preferred alert destinations here
        # Examples:
        # email_configs = [{ to = "admin@example.com"; }];
        # webhook_configs = [{ url = "http://webhook.example.com/mbsync"; }];
        # For now, just log to journal
        webhook_configs = [{
          url = "http://localhost:9093/log";
          send_resolved = true;
        }];
      }
    ];
  };
}
