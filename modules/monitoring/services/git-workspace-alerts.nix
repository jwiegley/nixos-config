{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define git-workspace monitoring rules as a separate file
  gitWorkspaceRulesFile = pkgs.writeText "git-workspace-alerts.yml" ''
    groups:
    - name: git_workspace_alerts
      interval: 60s
      rules:
      # Alert if metric collection is failing
      - alert: GitWorkspaceMetricsCollectionFailed
        expr: git_workspace_scrape_success == 0
        for: 10m
        labels:
          severity: warning
          service: git-workspace-archive
        annotations:
          summary: "Git workspace metrics collection failed"
          description: "The Prometheus exporter for git workspace archive is failing to collect metrics. Check the service with 'systemctl status git-workspace-metrics.service' and logs with 'journalctl -u git-workspace-metrics.service -f'"

      # Alert if sync hasn't run recently (>26 hours)
      - alert: GitWorkspaceSyncStale
        expr: (time() - git_workspace_last_sync_timestamp_seconds) > 93600
        for: 5m
        labels:
          severity: critical
          service: git-workspace-archive
        annotations:
          summary: "Git workspace sync hasn't run in over 26 hours"
          description: "The git-workspace-archive service hasn't completed a sync in {{ $value | humanizeDuration }}. Expected to run daily. Check timer with 'systemctl status git-workspace-archive.timer' and service with 'systemctl status git-workspace-archive.service'"

      # Alert if repository count dropped significantly
      - alert: GitWorkspaceRepoCountDropped
        expr: git_workspace_repos_total < 500
        for: 10m
        labels:
          severity: warning
          service: git-workspace-archive
        annotations:
          summary: "Git workspace repository count is unusually low"
          description: "Only {{ $value }} repositories are configured (expected ~619). This may indicate a configuration issue or workspace.toml corruption. Check /var/lib/git-workspace-archive/workspace.toml"

      # Alert if multiple repos failed to sync (WARNING threshold)
      - alert: GitWorkspaceMultipleReposFailed
        expr: git_workspace_repos_failed >= 5 and git_workspace_repos_failed < 10
        for: 5m
        labels:
          severity: warning
          service: git-workspace-archive
        annotations:
          summary: "Multiple git repositories failed to sync"
          description: "{{ $value }} out of {{ query \"git_workspace_repos_total\" | first | value }} repositories failed to sync. Check state file at /var/lib/git-workspace-archive/.sync-state.json and logs at /var/lib/git-workspace-archive/sync.log for details on which repos failed."

      # Alert if many repos failed to sync (CRITICAL threshold)
      - alert: GitWorkspaceManyReposFailed
        expr: git_workspace_repos_failed >= 10
        for: 5m
        labels:
          severity: critical
          service: git-workspace-archive
        annotations:
          summary: "Many git repositories failed to sync"
          description: "{{ $value }} out of {{ query \"git_workspace_repos_total\" | first | value }} repositories failed to sync. This indicates a serious problem. Check logs with 'journalctl -u git-workspace-archive.service -f' and verify GitHub token with 'ls -la /run/secrets/github-token'"

      # Alert if sync is taking unusually long (>30 minutes)
      - alert: GitWorkspaceSyncSlow
        expr: git_workspace_sync_duration_seconds > 1800
        for: 5m
        labels:
          severity: warning
          service: git-workspace-archive
        annotations:
          summary: "Git workspace sync is taking unusually long"
          description: "The last sync took {{ $value | humanizeDuration }} to complete (over 30 minutes). This may indicate network issues, GitHub API rate limiting, or repository problems. Check logs with 'journalctl -u git-workspace-archive.service'"

      # Alert if sync is taking extremely long (>60 minutes)
      - alert: GitWorkspaceSyncVerySlow
        expr: git_workspace_sync_duration_seconds > 3600
        for: 5m
        labels:
          severity: critical
          service: git-workspace-archive
        annotations:
          summary: "Git workspace sync is extremely slow"
          description: "The last sync took {{ $value | humanizeDuration }} to complete (over 60 minutes). This is abnormally slow and requires investigation. Check for network issues or hanging git processes."

      # Alert if too many repos are stale (>10% haven't updated in 3+ days) - WARNING
      - alert: GitWorkspaceManyStaleRepos
        expr: (git_workspace_stale_repos_total / git_workspace_repos_total) > 0.10 and (git_workspace_stale_repos_total / git_workspace_repos_total) < 0.25
        for: 1h
        labels:
          severity: warning
          service: git-workspace-archive
        annotations:
          summary: "Many git repositories are stale"
          description: "{{ $value | humanizePercentage }} of repositories ({{ query \"git_workspace_stale_repos_total\" | first | value }}/{{ query \"git_workspace_repos_total\" | first | value }}) haven't been updated in over 3 days. This may indicate inactive upstream repositories or sync issues. Check Nagios for detailed list of stale repos."

      # Alert if critical number of repos are stale (>25%) - CRITICAL
      - alert: GitWorkspaceCriticallyManyStaleRepos
        expr: (git_workspace_stale_repos_total / git_workspace_repos_total) >= 0.25
        for: 30m
        labels:
          severity: critical
          service: git-workspace-archive
        annotations:
          summary: "Critical number of git repositories are stale"
          description: "{{ $value | humanizePercentage }} of repositories ({{ query \"git_workspace_stale_repos_total\" | first | value }}/{{ query \"git_workspace_repos_total\" | first | value }}) haven't been updated in over 3 days. This indicates a widespread sync problem. Check if the service is running properly and verify network/GitHub connectivity."

      # Alert if specific critical repos are stale (>7 days old)
      - alert: GitWorkspaceImportantRepoStale
        expr: git_workspace_repo_age_seconds{repository=~"github/jwiegley/.*"} > 604800
        for: 1h
        labels:
          severity: warning
          service: git-workspace-archive
          repository: "{{ $labels.repository }}"
        annotations:
          summary: "Important repository {{ $labels.repository }} is stale"
          description: "Repository {{ $labels.repository }} hasn't been updated in {{ $value | humanizeDuration }} (over 7 days). This is unusual for a frequently-updated repository. Verify the repository still exists on GitHub and check for sync errors."

      # Alert if service is running but state file wasn't created
      - alert: GitWorkspaceNoStateFile
        expr: absent(git_workspace_last_sync_timestamp_seconds) or git_workspace_last_sync_timestamp_seconds == 0
        for: 2h
        labels:
          severity: warning
          service: git-workspace-archive
        annotations:
          summary: "Git workspace state file is missing or empty"
          description: "The sync state file at /var/lib/git-workspace-archive/.sync-state.json is missing or contains no timestamp. This indicates the service may not be running properly or hasn't completed its first sync. Check service status with 'systemctl status git-workspace-archive.service'"

      # Alert if success rate is declining (based on failed count over time)
      - alert: GitWorkspaceSuccessRateDeclining
        expr: rate(git_workspace_repos_failed[6h]) > 0.01
        for: 1h
        labels:
          severity: info
          service: git-workspace-archive
        annotations:
          summary: "Git workspace sync success rate is declining"
          description: "The number of failed repository syncs has been increasing over the past 6 hours. This may indicate a developing issue with GitHub connectivity, API rate limits, or repository problems. Monitor for escalation."

      # Alert if high scrape duration (collection taking too long)
      - alert: GitWorkspaceMetricCollectionSlow
        expr: git_workspace_scrape_duration_seconds > 180
        for: 10m
        labels:
          severity: info
          service: git-workspace-archive
        annotations:
          summary: "Git workspace metrics collection is slow"
          description: "Collecting metrics is taking {{ $value | humanizeDuration }} (over 3 minutes). With 621 repositories, this may indicate disk I/O issues or slow filesystem operations on /var/lib/git-workspace-archive."
  '';
in
{
  # Prometheus alert rules for git-workspace-archive monitoring
  services.prometheus.ruleFiles = lib.mkIf config.services.prometheus.enable [
    gitWorkspaceRulesFile
  ];
}
