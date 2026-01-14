{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define mbsync monitoring rules as a separate file
  mbsyncRulesFile = pkgs.writeText "mbsync-alerts.yml" ''
    groups:
    - name: mbsync_alerts
      interval: 60s
      rules:
      # Alert if assembly mbsync hasn't synced successfully in 48 hours
      - alert: MbsyncAssemblyNotSyncing
        expr: (time() - mbsync_assembly_last_success_timestamp) > 172800
        for: 5m
        labels:
          severity: warning
          service: mbsync
          user: assembly
        annotations:
          summary: "mbsync for assembly user hasn't synced in {{ $value | humanizeDuration }}"
          description: "The mbsync service for assembly user hasn't successfully synced email in over 48 hours. Last successful sync was {{ $value | humanizeDuration }} ago."

      # Alert if johnw mbsync hasn't synced successfully in 48 hours
      - alert: MbsyncJohnwNotSyncing
        expr: (time() - mbsync_johnw_last_success_timestamp) > 172800
        for: 5m
        labels:
          severity: warning
          service: mbsync
          user: johnw
        annotations:
          summary: "mbsync for johnw user hasn't synced in {{ $value | humanizeDuration }}"
          description: "The mbsync service for johnw user hasn't successfully synced email in over 48 hours. Last successful sync was {{ $value | humanizeDuration }} ago."

      # Alert if assembly mbsync is continuously failing
      - alert: MbsyncAssemblyFailing
        expr: mbsync_assembly_sync_status == 0
        for: 1h
        labels:
          severity: critical
          service: mbsync
          user: assembly
        annotations:
          summary: "mbsync for assembly user is failing"
          description: "The mbsync service for assembly user has been failing for over an hour. Check logs at /var/log/mbsync-assembly/sync.log"

      # Alert if johnw mbsync is continuously failing
      - alert: MbsyncJohnwFailing
        expr: mbsync_johnw_sync_status == 0
        for: 1h
        labels:
          severity: critical
          service: mbsync
          user: johnw
        annotations:
          summary: "mbsync for johnw user is failing"
          description: "The mbsync service for johnw user has been failing for over an hour. Check logs at /var/log/mbsync-johnw/sync.log"

      # Alert if assembly inbox messages drop significantly (potential data loss)
      - alert: MbsyncAssemblyInboxMessagesDropped
        expr: (mbsync_assembly_inbox_messages < (mbsync_assembly_inbox_messages offset 1h) * 0.9) and (mbsync_assembly_inbox_messages offset 1h) > 100
        for: 5m
        labels:
          severity: warning
          service: mbsync
          user: assembly
        annotations:
          summary: "Significant drop in assembly inbox messages"
          description: "Assembly inbox messages dropped by more than 10% (from {{ with query \"mbsync_assembly_inbox_messages offset 1h\" }}{{ . | first | value }}{{ end }} to {{ $value }})"

      # Alert if johnw inbox messages drop significantly (potential data loss)
      - alert: MbsyncJohnwInboxMessagesDropped
        expr: (mbsync_johnw_inbox_messages < (mbsync_johnw_inbox_messages offset 1h) * 0.9) and (mbsync_johnw_inbox_messages offset 1h) > 100
        for: 5m
        labels:
          severity: warning
          service: mbsync
          user: johnw
        annotations:
          summary: "Significant drop in johnw inbox messages"
          description: "Johnw inbox messages dropped by more than 10% (from {{ with query \"mbsync_johnw_inbox_messages offset 1h\" }}{{ . | first | value }}{{ end }} to {{ $value }})"
  '';
in
{
  # Prometheus alert rules for mbsync monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [ mbsyncRulesFile ];
}
