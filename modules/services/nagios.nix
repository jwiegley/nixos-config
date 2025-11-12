{ config, lib, pkgs, secrets, nagios, ... }:

let
  # Common helper functions
  common = import ../lib/common.nix { inherit secrets; };

  # Override checkSSLCert to use bind.host instead of bind
  # The default package uses bind which doesn't include the 'host' command
  # We can't use .override because the package doesn't expose bind as a parameter
  # So we wrap it to add bind.host to the PATH
  checkSSLCertFixed = pkgs.symlinkJoin {
    name = "check_ssl_cert-fixed";
    paths = [ pkgs.nagiosPlugins.check_ssl_cert ];
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/check_ssl_cert \
        --prefix PATH : ${pkgs.bind.host}/bin
    '';
  };

  # Check plugin for local backup age monitoring
  checkBackupAge = pkgs.writeShellScript "check_backup_age.sh" ''
    set -euo pipefail

    # Configuration
    BACKUP_NAME="''${1:-}"
    THRESHOLD_SECONDS="''${2:-14400}"  # Default: 4 hours
    BACKUP_BASE_DIR="/tank/Backups/Machines/Vulcan"
    TIMESTAMP_FILE="''${BACKUP_BASE_DIR}/.''${BACKUP_NAME}.latest"

    # Nagios exit codes
    STATE_OK=0
    STATE_CRITICAL=2
    STATE_UNKNOWN=3

    # Check arguments
    if [[ -z "$BACKUP_NAME" ]]; then
      echo "UNKNOWN: Backup name not specified"
      exit "$STATE_UNKNOWN"
    fi

    if ! [[ "$THRESHOLD_SECONDS" =~ ^[0-9]+$ ]]; then
      echo "UNKNOWN: Threshold must be a positive integer"
      exit "$STATE_UNKNOWN"
    fi

    # Check if /tank is mounted
    if ! ${pkgs.util-linux}/bin/mountpoint -q /tank; then
      echo "CRITICAL: /tank is not mounted - backups cannot be checked"
      exit "$STATE_CRITICAL"
    fi

    # Check if timestamp file exists
    if [[ ! -f "$TIMESTAMP_FILE" ]]; then
      echo "CRITICAL: Backup timestamp file not found: $TIMESTAMP_FILE"
      exit "$STATE_CRITICAL"
    fi

    # Get current time and file modification time
    CURRENT_TIME=$(${pkgs.coreutils}/bin/date +%s)
    FILE_TIME=$(${pkgs.coreutils}/bin/stat -c %Y "$TIMESTAMP_FILE" 2>/dev/null || echo 0)

    if [[ "$FILE_TIME" -eq 0 ]]; then
      echo "UNKNOWN: Unable to read timestamp from $TIMESTAMP_FILE"
      exit "$STATE_UNKNOWN"
    fi

    # Calculate age
    AGE_SECONDS=$((CURRENT_TIME - FILE_TIME))
    AGE_MINUTES=$((AGE_SECONDS / 60))
    AGE_HOURS=$((AGE_SECONDS / 3600))

    # Check against threshold
    if [[ $AGE_SECONDS -gt $THRESHOLD_SECONDS ]]; then
      THRESHOLD_HOURS=$((THRESHOLD_SECONDS / 3600))
      if [[ $AGE_HOURS -ge 1 ]]; then
        echo "CRITICAL: Backup '$BACKUP_NAME' is ''${AGE_HOURS}h ''${AGE_MINUTES}m old (threshold: ''${THRESHOLD_HOURS}h)"
      else
        echo "CRITICAL: Backup '$BACKUP_NAME' is ''${AGE_MINUTES}m old (threshold: $((THRESHOLD_SECONDS / 60))m)"
      fi
      exit "$STATE_CRITICAL"
    fi

    # All good
    if [[ $AGE_HOURS -ge 1 ]]; then
      echo "OK: Backup '$BACKUP_NAME' is ''${AGE_HOURS}h ''${AGE_MINUTES}m old"
    else
      echo "OK: Backup '$BACKUP_NAME' is ''${AGE_MINUTES}m old"
    fi
    exit "$STATE_OK"
  '';

  # Check plugin for git workspace sync status
  checkGitWorkspaceSync = pkgs.writeShellScript "check_git_workspace_sync.sh" ''
    set -euo pipefail

    WORKSPACE_DIR="/var/lib/git-workspace-archive"
    STATE_FILE="$WORKSPACE_DIR/.sync-state.json"

    # Nagios exit codes
    STATE_OK=0
    STATE_WARNING=1
    STATE_CRITICAL=2
    STATE_UNKNOWN=3

    # Check if state file exists
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "UNKNOWN: Sync state file not found at $STATE_FILE - service may not have run yet"
      exit "$STATE_UNKNOWN"
    fi

    # Parse JSON using jq
    if ! ${pkgs.jq}/bin/jq . "$STATE_FILE" >/dev/null 2>&1; then
      echo "UNKNOWN: Sync state file is not valid JSON"
      exit "$STATE_UNKNOWN"
    fi

    # Extract metrics
    LAST_RUN=$(${pkgs.jq}/bin/jq -r '.last_run_end' "$STATE_FILE")
    TOTAL_REPOS=$(${pkgs.jq}/bin/jq -r '.total_repos' "$STATE_FILE")
    SUCCESSFUL=$(${pkgs.jq}/bin/jq -r '.successful' "$STATE_FILE")
    FAILED=$(${pkgs.jq}/bin/jq -r '.failed' "$STATE_FILE")
    FAILED_REPOS=$(${pkgs.jq}/bin/jq -r '.failed_repos' "$STATE_FILE")
    DURATION=$(${pkgs.jq}/bin/jq -r '.duration_seconds' "$STATE_FILE")

    # Check if last run is recent (< 26 hours = daily + 2 hour buffer)
    CURRENT_TIME=$(${pkgs.coreutils}/bin/date +%s)
    LAST_RUN_TIME=$(${pkgs.coreutils}/bin/date -d "$LAST_RUN" +%s 2>/dev/null || echo 0)

    if [[ "$LAST_RUN_TIME" -eq 0 ]]; then
      echo "UNKNOWN: Unable to parse last run time: $LAST_RUN"
      exit "$STATE_UNKNOWN"
    fi

    AGE_HOURS=$(( (CURRENT_TIME - LAST_RUN_TIME) / 3600 ))

    if [[ $AGE_HOURS -gt 26 ]]; then
      echo "CRITICAL: Last sync was ''${AGE_HOURS}h ago (expected < 26h)"
      exit "$STATE_CRITICAL"
    fi

    # Check repo count (alert if dropped significantly)
    if [[ "$TOTAL_REPOS" -lt 500 ]]; then
      echo "WARNING: Only $TOTAL_REPOS repos found (expected ~619) - possible config issue"
      exit "$STATE_WARNING"
    fi

    # Check failure count
    if [[ "$FAILED" -ge 10 ]]; then
      echo "CRITICAL: $FAILED/$TOTAL_REPOS repos failed to sync. Failed: $FAILED_REPOS"
      exit "$STATE_CRITICAL"
    elif [[ "$FAILED" -ge 5 ]]; then
      echo "WARNING: $FAILED/$TOTAL_REPOS repos failed to sync. Failed: $FAILED_REPOS"
      exit "$STATE_WARNING"
    elif [[ "$FAILED" -gt 0 ]]; then
      echo "OK: $SUCCESSFUL/$TOTAL_REPOS repos synced successfully, $FAILED minor failures: $FAILED_REPOS"
      exit "$STATE_OK"
    fi

    # All good
    DURATION_MIN=$((DURATION / 60))
    echo "OK: All $TOTAL_REPOS repos synced successfully in ''${DURATION_MIN}m (last run ''${AGE_HOURS}h ago)"
    exit "$STATE_OK"
  '';

  # Check plugin for stale git repositories
  checkGitWorkspaceStale = pkgs.writeShellScript "check_git_workspace_stale.sh" ''
    set -euo pipefail

    WORKSPACE_DIR="/var/lib/git-workspace-archive"
    STALE_DAYS="''${1:-3}"  # Default: 3 days
    STALE_PERCENT_WARN="''${2:-10}"  # Default: warn if > 10% stale
    STALE_PERCENT_CRIT="''${3:-25}"  # Default: critical if > 25% stale

    # Nagios exit codes
    STATE_OK=0
    STATE_WARNING=1
    STATE_CRITICAL=2
    STATE_UNKNOWN=3

    # Check if workspace directory exists
    if [[ ! -d "$WORKSPACE_DIR/github" ]]; then
      echo "UNKNOWN: Workspace directory not found: $WORKSPACE_DIR/github"
      exit "$STATE_UNKNOWN"
    fi

    # Calculate stale threshold in seconds
    STALE_SECONDS=$((STALE_DAYS * 86400))
    CURRENT_TIME=$(${pkgs.coreutils}/bin/date +%s)
    CUTOFF_TIME=$((CURRENT_TIME - STALE_SECONDS))

    # Count total repos and stale repos
    TOTAL_REPOS=0
    STALE_REPOS=0
    STALE_LIST=""

    while IFS= read -r -d ''' fetch_head; do
      TOTAL_REPOS=$((TOTAL_REPOS + 1))
      FETCH_TIME=$(${pkgs.coreutils}/bin/stat -c %Y "$fetch_head" 2>/dev/null || echo 0)

      if [[ "$FETCH_TIME" -lt "$CUTOFF_TIME" && "$FETCH_TIME" -gt 0 ]]; then
        STALE_REPOS=$((STALE_REPOS + 1))
        # Extract repo name from path
        REPO_PATH=$(${pkgs.coreutils}/bin/dirname "$fetch_head")
        REPO_NAME=$(echo "$REPO_PATH" | ${pkgs.gnused}/bin/sed "s|$WORKSPACE_DIR/||" | ${pkgs.gnused}/bin/sed 's|/.git$||')
        AGE_DAYS=$(( (CURRENT_TIME - FETCH_TIME) / 86400 ))

        if [[ $STALE_REPOS -le 10 ]]; then
          # Only list first 10 stale repos to avoid too long output
          STALE_LIST="''${STALE_LIST}$REPO_NAME(''${AGE_DAYS}d), "
        fi
      fi
    done < <(${pkgs.findutils}/bin/find "$WORKSPACE_DIR/github" -name "FETCH_HEAD" -path "*/.git/FETCH_HEAD" -print0 2>/dev/null)

    if [[ "$TOTAL_REPOS" -eq 0 ]]; then
      echo "UNKNOWN: No repositories found in $WORKSPACE_DIR/github"
      exit "$STATE_UNKNOWN"
    fi

    # Calculate percentage
    STALE_PERCENT=$((STALE_REPOS * 100 / TOTAL_REPOS))

    # Trim trailing comma from stale list
    STALE_LIST=$(echo "$STALE_LIST" | ${pkgs.gnused}/bin/sed 's/, $//')
    if [[ $STALE_REPOS -gt 10 ]]; then
      STALE_LIST="''${STALE_LIST}, and $((STALE_REPOS - 10)) more..."
    fi

    # Check thresholds
    if [[ "$STALE_PERCENT" -ge "$STALE_PERCENT_CRIT" ]]; then
      echo "CRITICAL: $STALE_REPOS/$TOTAL_REPOS repos (''${STALE_PERCENT}%) haven't been updated in >''${STALE_DAYS} days: $STALE_LIST"
      exit "$STATE_CRITICAL"
    elif [[ "$STALE_PERCENT" -ge "$STALE_PERCENT_WARN" ]]; then
      echo "WARNING: $STALE_REPOS/$TOTAL_REPOS repos (''${STALE_PERCENT}%) haven't been updated in >''${STALE_DAYS} days: $STALE_LIST"
      exit "$STATE_WARNING"
    elif [[ "$STALE_REPOS" -gt 0 ]]; then
      echo "OK: $STALE_REPOS/$TOTAL_REPOS repos (''${STALE_PERCENT}%) are >''${STALE_DAYS} days old (acceptable): $STALE_LIST"
      exit "$STATE_OK"
    fi

    echo "OK: All $TOTAL_REPOS repos have been updated within the last ''${STALE_DAYS} days"
    exit "$STATE_OK"
  '';

  # Nagios configuration directory
  nagiosCfgDir = "/var/lib/nagios";

  # Helper function to generate systemd service checks
  # Optional 4th parameter: template (defaults to "standard-service")
  mkServiceCheck = serviceName: displayName: servicegroups: template: ''
    define service {
      use                     ${template}
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_systemd_service!${serviceName}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }
  '';

  # Helper function for services that depend on mount points
  # These services use ConditionPathIsMountPoint and need special monitoring
  mkConditionalServiceCheck = serviceName: displayName: mountPoint: servicegroups: ''
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_systemd_service_conditional!${serviceName}!${mountPoint}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }
  '';

  # Helper function to generate timer checks (monitors both timer and associated service)
  mkTimerCheck = timerName: displayName: servicegroups: ''
    define service {
      use                     low-priority-service
      host_name               vulcan
      service_description     ${displayName} (Timer)
      check_command           check_systemd_service!${timerName}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }

    define service {
      use                     low-priority-service
      host_name               vulcan
      service_description     ${displayName} (Service)
      check_command           check_systemd_service!${lib.removeSuffix ".timer" timerName}.service${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }
  '';

  # Helper function for timers whose services depend on mount points
  mkConditionalTimerCheck = timerName: displayName: mountPoint: servicegroups: ''
    define service {
      use                     low-priority-service
      host_name               vulcan
      service_description     ${displayName} (Timer)
      check_command           check_systemd_service!${timerName}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }

    define service {
      use                     low-priority-service
      host_name               vulcan
      service_description     ${displayName} (Service)
      check_command           check_systemd_service_conditional!${lib.removeSuffix ".timer" timerName}.service!${mountPoint}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }
  '';

  # Helper function to generate container checks
  mkContainerCheck = containerName: displayName: servicegroups: ''
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_podman_container!${containerName}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }
  '';

  # Helper function to generate rootless container checks (containers running as specific users)
  mkRootlessContainerCheck = containerName: displayName: runAsUser: servicegroups: ''
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_podman_container_rootless!${containerName}!${runAsUser}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }
  '';

  # Helper function for on-demand services (only alert on failures, not inactive state)
  mkOnDemandServiceCheck = serviceName: displayName: servicegroups: ''
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_systemd_service_ondemand!${serviceName}${if servicegroups != "" then "\n      service_groups          ${servicegroups}" else ""}
    }
  '';

  # Helper function to generate monitored host with ping check and optional parent
  # Usage: mkMonitoredHost { hostname = "router"; address = "192.168.1.1"; alias = "Main Router"; parent = null; pingWarn = "100.0,20%"; pingCrit = "500.0,60%"; }
  mkMonitoredHost = { hostname, address, alias, parent ? null, pingWarn ? "100.0,20%", pingCrit ? "500.0,60%" }: ''
    define host {
      use                     linux-server
      host_name               ${hostname}
      alias                   ${alias}
      address                 ${address}${lib.optionalString (parent != null) "\n      parents                 ${parent}"}
    }

    define service {
      use                     generic-service
      host_name               ${hostname}
      service_description     PING
      check_command           check_ping!${pingWarn}!${pingCrit}
      service_groups          network-hosts
    }
  '';

  # List of monitored hosts with parent relationships for network topology
  # IMPORTANT: Host definitions are now stored in a separate private file: /etc/nixos/nagios-hosts.nix
  # This file is excluded from version control (.gitignore) to keep network topology private
  #
  # The file should contain a Nix list with the following format:
  # [
  #   { hostname = "devicename"; address = "IP"; alias = "Description"; parent = "parent_hostname" or null; }
  #   ...
  # ]
  #
  # Network reachability: parent = null for top-level devices, parent = "hostname" for dependent devices
  # This enables Nagios to distinguish between:
  #   - DOWN: Host itself is unreachable (parent is UP)
  #   - UNREACHABLE: Host is unreachable because parent/network path is down
  #
  # Import from absolute path (required for gitignored files in flakes)
  # Falls back to empty list if file doesn't exist
  monitoredHosts = import (nagios.outPath + "/hosts.nix");

  # Service categories for organized monitoring
  # Critical Infrastructure Services (no mount dependencies)
  criticalServices = [
    { name = "postgresql.service"; display = "PostgreSQL Database"; }
    { name = "nginx.service"; display = "Nginx Web Server"; }
    { name = "dovecot.service"; display = "Dovecot IMAP Server"; }
    { name = "postfix.service"; display = "Postfix Mail Server"; }
    { name = "rspamd.service"; display = "Rspamd Spam Filter"; }
    { name = "radicale.service"; display = "Radicale CalDAV/CardDAV Server"; }
    { name = "vdirsyncer-status.service"; display = "vdirsyncer Status Dashboard"; }
    { name = "step-ca.service"; display = "Step-CA Certificate Authority"; }
    { name = "samba-wsdd.service"; display = "Samba Web Service Discovery"; }
    { name = "technitium-dns-server.service"; display = "Technitium DNS Server"; }
  ];

  # Critical Services that depend on /tank mount
  tankDependentServices = [
    { name = "nextcloud-setup.service"; display = "Nextcloud Setup"; mount = "/tank"; }
    { name = "nextcloud-update-db.service"; display = "Nextcloud Database Update"; mount = "/tank"; }
    { name = "nextcloud-cron.service"; display = "Nextcloud Cron"; mount = "/tank"; }
    { name = "samba-smbd.service"; display = "Samba SMB Daemon"; mount = "/tank"; }
    { name = "samba-nmbd.service"; display = "Samba NetBIOS Name Server"; mount = "/tank"; }
    { name = "samba-winbindd.service"; display = "Samba Winbind Daemon"; mount = "/tank"; }
    { name = "prometheus-zfs-exporter.service"; display = "ZFS Metrics Exporter"; mount = "/tank"; }
    { name = "aria2.service"; display = "aria2 Download Manager"; mount = "/tank"; }
  ];

  # Monitoring Stack Services
  monitoringServices = [
    { name = "prometheus.service"; display = "Prometheus Metrics Server"; }
    { name = "grafana.service"; display = "Grafana Dashboard"; }
    { name = "loki.service"; display = "Loki Log Aggregation"; }
    { name = "promtail.service"; display = "Promtail Log Collector"; }
    { name = "alertmanager.service"; display = "Alertmanager"; }
    { name = "victoriametrics.service"; display = "VictoriaMetrics"; }
    { name = "nagios.service"; display = "Nagios Monitoring"; }
    { name = "critical-services-exporter.service"; display = "Critical Services Exporter"; }
    { name = "dns-query-log-exporter.service"; display = "DNS Query Log Exporter"; }
    { name = "aria2-exporter.service"; display = "aria2 Metrics Exporter"; }
  ];

  # Home Automation Services
  homeAutomationServices = [
    { name = "home-assistant.service"; display = "Home Assistant"; }
    { name = "node-red.service"; display = "Node-RED Automation"; }
  ];

  # Application Services
  applicationServices = [
    { name = "jellyfin.service"; display = "Jellyfin Media Server"; }
    { name = "glance.service"; display = "Glance Dashboard"; }
    { name = "glance-github-extension.service"; display = "Glance GitHub Extension"; }
    { name = "cockpit.service"; display = "Cockpit Web Console"; }
    { name = "ntopng.service"; display = "ntopng Network Monitor"; }
    { name = "copyparty.service"; display = "Copyparty File Server"; }
    { name = "gitea.service"; display = "Gitea Git Server"; }
    { name = "n8n.service"; display = "n8n Workflow Automation"; }
    { name = "redis-gitea.service"; display = "Redis (Gitea)"; }
    { name = "redis-litellm.service"; display = "Redis (LiteLLM)"; }
    { name = "redis-n8n.service"; display = "Redis (n8n)"; }
    { name = "redis-nextcloud.service"; display = "Redis (Nextcloud)"; }
    { name = "redis-ntopng.service"; display = "Redis (ntopng)"; }
    { name = "changedetection.service"; display = "ChangeDetection"; }
  ];

  # Backup Services - Restic (all depend on /tank mount)
  resticBackupServices = [
    { name = "restic-backups-Audio.service"; display = "Restic Backup: Audio"; mount = "/tank"; }
    { name = "restic-backups-Backups.service"; display = "Restic Backup: Backups"; mount = "/tank"; }
    { name = "restic-backups-Databases.service"; display = "Restic Backup: Databases"; mount = "/tank"; }
    { name = "restic-backups-doc.service"; display = "Restic Backup: doc"; mount = "/tank"; }
    { name = "restic-backups-Home.service"; display = "Restic Backup: Home"; mount = "/tank"; }
    { name = "restic-backups-Nextcloud.service"; display = "Restic Backup: Nextcloud"; mount = "/tank"; }
    { name = "restic-backups-Photos.service"; display = "Restic Backup: Photos"; mount = "/tank"; }
    { name = "restic-backups-src.service"; display = "Restic Backup: src"; mount = "/tank"; }
    { name = "restic-backups-Video.service"; display = "Restic Backup: Video"; mount = "/tank"; }
  ];

  # Backup and Maintenance Timers
  maintenanceTimers = [
    { name = "git-workspace-archive.timer"; display = "Git Workspace Archive"; }
    { name = "update-containers.timer"; display = "Container Updates"; }
    { name = "postgresql-backup.timer"; display = "PostgreSQL Backup"; }
    { name = "backup-status-exporter.timer"; display = "Backup Status Exporter"; }
    { name = "certificate-exporter.timer"; display = "Certificate Exporter"; }
    { name = "certificate-validation.timer"; display = "Certificate Validation"; }
    { name = "logwatch.timer"; display = "Logwatch Log Analysis"; }
    { name = "logrotate.timer"; display = "Log Rotation"; }
    { name = "fstrim.timer"; display = "Filesystem Trim"; }
    { name = "podman-prune.timer"; display = "Podman Cleanup"; }
  ];

  # Timers whose services depend on /tank mount
  tankDependentTimers = [
    { name = "restic-check.timer"; display = "Restic Repository Check"; mount = "/tank"; }
    { name = "restic-metrics.timer"; display = "Restic Metrics Collection"; mount = "/tank"; }
  ];

  # Email Sync Timers
  emailTimers = [
    { name = "mbsync-johnw.timer"; display = "Email Sync (johnw)"; }
    { name = "mbsync-assembly.timer"; display = "Email Sync (assembly)"; }
    { name = "mbsync-johnw-health-check.timer"; display = "Email Sync Health Check (johnw)"; }
    { name = "mbsync-assembly-health-check.timer"; display = "Email Sync Health Check (assembly)"; }
    { name = "imapdedup.timer"; display = "IMAP Deduplication"; }
    { name = "rspamd-scan-mailboxes.timer"; display = "Rspamd Mailbox Scanning"; }
    { name = "vdirsyncer.timer"; display = "Contact/Calendar Sync (vdirsyncer)"; }
  ];

  # Certificate Renewal Timers
  certRenewalTimers = [
    { name = "dovecot-cert-renewal.timer"; display = "Dovecot Cert Renewal"; }
    { name = "nginx-cert-renewal.timer"; display = "Nginx Cert Renewal"; }
    { name = "postgresql-cert-renewal.timer"; display = "PostgreSQL Cert Renewal"; }
    { name = "postfix-cert-renewal.timer"; display = "Postfix Cert Renewal"; }
  ];

  # Podman Containers
  # rootless containers (runAs set) run in user namespaces and require special checks
  # root containers (no runAs) run in the root namespace via system services
  # Updated 2025-11-09: Each container now runs under its own dedicated user for security isolation
  containers = [
    { name = "litellm"; display = "LiteLLM API Proxy"; runAs = "litellm"; }
    { name = "metabase"; display = "Metabase BI Platform"; runAs = "metabase"; }
    { name = "mindsdb"; display = "MindsDB AI Platform"; runAs = "mindsdb"; }
    { name = "nocobase"; display = "NocoBase No-Code Platform"; runAs = "nocobase"; }
    { name = "opnsense-exporter"; display = "OPNsense Metrics Exporter"; runAs = "opnsense-exporter"; }
    { name = "paperless-ai"; display = "Paperless-AI Document Processing"; runAs = "paperless-ai"; }
    { name = "speedtest"; display = "Open SpeedTest"; runAs = "openspeedtest"; }
    { name = "silly-tavern"; display = "Silly Tavern"; runAs = "sillytavern"; }
    { name = "teable"; display = "Teable Database Platform"; runAs = "teable"; }
    { name = "technitium-dns-exporter"; display = "Technitium DNS Exporter"; runAs = "technitium-dns-exporter"; }
    { name = "vanna"; display = "Vanna.AI Text-to-SQL"; runAs = "vanna"; }
    { name = "wallabag"; display = "Wallabag Read-Later"; runAs = "wallabag"; }
  ];

  # Container systemd services (for Quadlet-managed containers)
  containerSystemdServices = [
    { name = "container@secure-nginx.service"; display = "Secure Nginx Container"; }
  ];

  # On-demand services (manually started/stopped, only alert on failures)
  onDemandServices = [
    { name = "windows11.service"; display = "Windows 11 Container"; }
  ];

  # Generate all service checks
  allServiceChecks = lib.concatStrings [
    # Critical Infrastructure - check every 2 minutes
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display "critical-infrastructure" "critical-service") criticalServices)

    # Tank-Dependent Services (use conditional check)
    (lib.concatMapStrings (s: mkConditionalServiceCheck s.name s.display s.mount "tank-dependent-services") tankDependentServices)

    # Monitoring Stack - check every 5 minutes
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display "monitoring-stack" "standard-service") monitoringServices)

    # Home Automation - check every 5 minutes
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display "home-automation" "standard-service") homeAutomationServices)

    # Applications - check every 5 minutes
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display "application-services" "standard-service") applicationServices)

    # Restic Backup Services (use conditional check)
    (lib.concatMapStrings (s: mkConditionalServiceCheck s.name s.display s.mount "backup-services") resticBackupServices)

    # Container Services - check every 5 minutes
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display "containers" "standard-service") containerSystemdServices)

    # On-Demand Services - only alert on failures
    (lib.concatMapStrings (s: mkOnDemandServiceCheck s.name s.display "containers") onDemandServices)

    # Maintenance Timers - check every 15 minutes (low priority)
    (lib.concatMapStrings (t: mkTimerCheck t.name t.display "maintenance-timers") maintenanceTimers)

    # Tank-Dependent Timers (use conditional check for services)
    (lib.concatMapStrings (t: mkConditionalTimerCheck t.name t.display t.mount "maintenance-timers") tankDependentTimers)

    # Email Timers - check every 15 minutes
    (lib.concatMapStrings (t: mkTimerCheck t.name t.display "email-services") emailTimers)

    # Certificate Renewal Timers - check every 15 minutes
    (lib.concatMapStrings (t: mkTimerCheck t.name t.display "certificate-renewal") certRenewalTimers)

    # Podman Containers - check every 5 minutes
    # Use appropriate check based on whether container is rootless (has runAs user)
    (lib.concatMapStrings (c:
      if c ? runAs then
        mkRootlessContainerCheck c.name c.display c.runAs "containers"
      else
        mkContainerCheck c.name c.display "containers"
    ) containers)
  ];

  # Nagios object configuration
  nagiosObjectDefs = pkgs.writeText "nagios-objects.cfg" ''
    ###############################################################################
    # NAGIOS OBJECT DEFINITIONS
    ###############################################################################

    ###############################################################################
    # CONTACTS
    ###############################################################################

    define contact {
      contact_name                    nagiosadmin
      alias                           Nagios Admin
      service_notification_period     24x7
      host_notification_period        24x7
      service_notification_options    u,c,r
      host_notification_options       d,u,r
      service_notification_commands   notify-service-by-email
      host_notification_commands      notify-host-by-email
      email                           johnw@vulcan.lan
    }

    define contactgroup {
      contactgroup_name               admins
      alias                           Nagios Administrators
      members                         nagiosadmin
    }

    ###############################################################################
    # TIME PERIODS
    ###############################################################################

    define timeperiod {
      timeperiod_name 24x7
      alias           24 Hours A Day, 7 Days A Week
      sunday          00:00-24:00
      monday          00:00-24:00
      tuesday         00:00-24:00
      wednesday       00:00-24:00
      thursday        00:00-24:00
      friday          00:00-24:00
      saturday        00:00-24:00
    }

    define timeperiod {
      timeperiod_name workhours
      alias           Normal Work Hours
      monday          09:00-17:00
      tuesday         09:00-17:00
      wednesday       09:00-17:00
      thursday        09:00-17:00
      friday          09:00-17:00
    }

    ###############################################################################
    # COMMANDS
    ###############################################################################

    # Notification commands
    define command {
      command_name    notify-host-by-email
      command_line    ${pkgs.mailutils}/bin/mail -s "** $NOTIFICATIONTYPE$ Host Alert: $HOSTNAME$ is $HOSTSTATE$ **" $CONTACTEMAIL$
    }

    define command {
      command_name    notify-service-by-email
      command_line    ${pkgs.mailutils}/bin/mail -s "** $NOTIFICATIONTYPE$ Service Alert: $HOSTALIAS$/$SERVICEDESC$ is $SERVICESTATE$ **" $CONTACTEMAIL$
    }

    # Host check commands
    define command {
      command_name    check-host-alive
      command_line    ${pkgs.monitoring-plugins}/bin/check_ping -H $HOSTADDRESS$ -w 3000.0,80% -c 5000.0,100% -p 5
    }

    define command {
      command_name    check_ping
      command_line    ${pkgs.monitoring-plugins}/bin/check_ping -H $HOSTADDRESS$ -w $ARG1$ -c $ARG2$
    }

    # Service check commands
    define command {
      command_name    check_local_disk
      command_line    ${pkgs.monitoring-plugins}/bin/check_disk -w $ARG1$ -c $ARG2$ -p $ARG3$
    }

    define command {
      command_name    check_local_load
      command_line    ${pkgs.monitoring-plugins}/bin/check_load -w $ARG1$ -c $ARG2$
    }

    define command {
      command_name    check_local_procs
      command_line    ${pkgs.monitoring-plugins}/bin/check_procs -w $ARG1$ -c $ARG2$ -s $ARG3$
    }

    define command {
      command_name    check_local_users
      command_line    ${pkgs.monitoring-plugins}/bin/check_users -w $ARG1$ -c $ARG2$
    }

    define command {
      command_name    check_local_swap
      command_line    ${pkgs.monitoring-plugins}/bin/check_swap -w $ARG1$ -c $ARG2$
    }

    define command {
      command_name    check_tcp
      command_line    ${pkgs.monitoring-plugins}/bin/check_tcp -H $HOSTADDRESS$ -p $ARG1$ $ARG2$
    }

    define command {
      command_name    check_http
      command_line    ${pkgs.monitoring-plugins}/bin/check_http -H $HOSTADDRESS$ $ARG1$
    }

    define command {
      command_name    check_https
      command_line    ${pkgs.monitoring-plugins}/bin/check_http -H $HOSTADDRESS$ -S $ARG1$
    }

    define command {
      command_name    check_ssh
      command_line    ${pkgs.monitoring-plugins}/bin/check_ssh $ARG1$ $HOSTADDRESS$
    }

    define command {
      command_name    check_imap
      command_line    ${pkgs.monitoring-plugins}/bin/check_imap -H $HOSTADDRESS$ -p $ARG1$
    }

    define command {
      command_name    check_imaps
      command_line    ${pkgs.monitoring-plugins}/bin/check_imap -H $HOSTADDRESS$ -p $ARG1$ -S
    }

    define command {
      command_name    check_smtp
      command_line    ${pkgs.monitoring-plugins}/bin/check_smtp -H $HOSTADDRESS$ -p $ARG1$
    }

    define command {
      command_name    check_smtps
      command_line    ${pkgs.monitoring-plugins}/bin/check_smtp -H $HOSTADDRESS$ -p $ARG1$ -S
    }

    define command {
      command_name    check_dns
      command_line    ${pkgs.monitoring-plugins}/bin/check_dns -H $ARG1$ -s $HOSTADDRESS$
    }

    define command {
      command_name    check_ssl_cert
      command_line    ${checkSSLCertFixed}/bin/check_ssl_cert -H $ARG1$ -p 443 --warning 30 --critical 15 --ignore-sct -r /etc/ssl/certs/vulcan-ca.crt
    }

    define command {
      command_name    check_ssl_cert_external
      command_line    ${checkSSLCertFixed}/bin/check_ssl_cert -H $ARG1$ -p 443 --warning 30 --critical 15 --ignore-sct
    }

    define command {
      command_name    check_systemd_service
      command_line    ${pkgs.nagiosPlugins.check_systemd}/bin/check_systemd -u $ARG1$ -w 600 -c 900
    }

    define command {
      command_name    check_systemd_service_ondemand
      command_line    ${pkgs.writeShellScript "check_systemd_ondemand.sh" ''
        #!/usr/bin/env bash
        SERVICE="$1"

        # Get service state information
        ACTIVE_STATE=$(${pkgs.systemd}/bin/systemctl show -p ActiveState --value "$SERVICE")
        SUB_STATE=$(${pkgs.systemd}/bin/systemctl show -p SubState --value "$SERVICE")
        RESULT=$(${pkgs.systemd}/bin/systemctl show -p Result --value "$SERVICE")

        # For on-demand services:
        # - inactive/dead is OK (manual stop)
        # - active/running is OK (manual start)
        # - failed is CRITICAL (unexpected failure)
        # - activating is OK (starting up)
        # - deactivating is OK (shutting down)

        if [ "$ACTIVE_STATE" = "failed" ]; then
          echo "CRITICAL: $SERVICE has failed - Result: $RESULT"
          exit 2
        elif [ "$ACTIVE_STATE" = "active" ]; then
          echo "OK: $SERVICE is active and running"
          exit 0
        elif [ "$ACTIVE_STATE" = "inactive" ] && [ "$SUB_STATE" = "dead" ]; then
          if [ "$RESULT" = "success" ]; then
            echo "OK: $SERVICE is inactive (manual stop or not started)"
            exit 0
          else
            echo "WARNING: $SERVICE is inactive but last run result was: $RESULT"
            exit 1
          fi
        elif [ "$ACTIVE_STATE" = "activating" ] || [ "$ACTIVE_STATE" = "deactivating" ]; then
          echo "OK: $SERVICE is $ACTIVE_STATE"
          exit 0
        else
          echo "WARNING: $SERVICE is in unexpected state: $ACTIVE_STATE/$SUB_STATE"
          exit 1
        fi
      ''} $ARG1$
    }

    define command {
      command_name    check_systemd_service_conditional
      command_line    ${pkgs.writeShellScript "check_systemd_conditional.sh" ''
        #!/usr/bin/env bash
        SERVICE="$1"
        MOUNTPOINT="$2"

        # Check if mount point is actually mounted
        if ${pkgs.util-linux}/bin/mountpoint -q "$MOUNTPOINT"; then
          # Mount is available - service MUST be active or have succeeded
          ACTIVE_STATE=$(${pkgs.systemd}/bin/systemctl show -p ActiveState --value "$SERVICE")
          SUB_STATE=$(${pkgs.systemd}/bin/systemctl show -p SubState --value "$SERVICE")
          RESULT=$(${pkgs.systemd}/bin/systemctl show -p Result --value "$SERVICE")
          CONDITION_RESULT=$(${pkgs.systemd}/bin/systemctl show -p ConditionResult --value "$SERVICE")

          # For oneshot services: inactive+dead with Result=success and ConditionResult=yes is OK
          # For running services: active+running is OK
          if [ "$ACTIVE_STATE" = "active" ] && [ "$RESULT" = "success" ]; then
            echo "OK: $SERVICE is active (mount $MOUNTPOINT available)"
            exit 0
          elif [ "$ACTIVE_STATE" = "inactive" ] && [ "$SUB_STATE" = "dead" ] && [ "$RESULT" = "success" ] && [ "$CONDITION_RESULT" = "yes" ]; then
            echo "OK: $SERVICE completed successfully (mount $MOUNTPOINT available)"
            exit 0
          elif [ "$CONDITION_RESULT" = "no" ]; then
            echo "CRITICAL: $SERVICE condition not met but $MOUNTPOINT IS mounted - service should be running"
            exit 2
          else
            echo "CRITICAL: $SERVICE is $ACTIVE_STATE/$SUB_STATE with result $RESULT (mount $MOUNTPOINT available)"
            exit 2
          fi
        else
          # Mount not available - service being inactive is expected
          # Note: ConditionResult may still show "yes" if it was evaluated when mount was available
          # So we only check ActiveState, not ConditionResult
          ACTIVE_STATE=$(${pkgs.systemd}/bin/systemctl show -p ActiveState --value "$SERVICE")

          if [ "$ACTIVE_STATE" = "inactive" ]; then
            echo "OK: $SERVICE inactive because $MOUNTPOINT not mounted (expected)"
            exit 0
          elif [ "$ACTIVE_STATE" = "failed" ]; then
            echo "CRITICAL: $SERVICE is failed even though $MOUNTPOINT not mounted"
            exit 2
          else
            echo "WARNING: $SERVICE is $ACTIVE_STATE but $MOUNTPOINT not mounted"
            exit 1
          fi
        fi
      ''} $ARG1$ $ARG2$
    }

    define command {
      command_name    check_postgres
      command_line    ${pkgs.monitoring-plugins}/bin/check_pgsql -H $HOSTADDRESS$ -d $ARG1$
    }

    define command {
      command_name    check_podman_container
      command_line    ${pkgs.writeShellScript "check_podman_container.sh" ''
        #!/usr/bin/env bash
        CONTAINER_NAME="$1"

        # Check if container exists (use sudo to access root-level containers)
        # Use setuid wrapper from /run/wrappers/bin/sudo, not nix store (which lacks setuid bit)
        if ! /run/wrappers/bin/sudo ${pkgs.podman}/bin/podman container exists "$CONTAINER_NAME"; then
          echo "CRITICAL: Container $CONTAINER_NAME does not exist"
          exit 2
        fi

        # Get container status (use sudo to access root-level containers)
        STATUS=$(/run/wrappers/bin/sudo ${pkgs.podman}/bin/podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)

        if [ "$STATUS" = "running" ]; then
          echo "OK: Container $CONTAINER_NAME is running"
          exit 0
        elif [ "$STATUS" = "exited" ]; then
          echo "CRITICAL: Container $CONTAINER_NAME has exited"
          exit 2
        else
          echo "WARNING: Container $CONTAINER_NAME is in state: $STATUS"
          exit 1
        fi
      ''} $ARG1$
    }

    define command {
      command_name    check_podman_container_rootless
      command_line    ${pkgs.writeShellScript "check_podman_container_rootless.sh" ''
        #!/usr/bin/env bash
        CONTAINER_NAME="$1"
        RUN_AS_USER="$2"

        # Check if container exists (run as specific user to access user-namespaced containers)
        # Use setuid wrapper from /run/wrappers/bin/sudo, not nix store (which lacks setuid bit)
        if ! /run/wrappers/bin/sudo -u "$RUN_AS_USER" ${pkgs.podman}/bin/podman container exists "$CONTAINER_NAME"; then
          echo "CRITICAL: Container $CONTAINER_NAME does not exist (user: $RUN_AS_USER)"
          exit 2
        fi

        # Get container status (run as specific user)
        STATUS=$(/run/wrappers/bin/sudo -u "$RUN_AS_USER" ${pkgs.podman}/bin/podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)

        if [ "$STATUS" = "running" ]; then
          echo "OK: Container $CONTAINER_NAME is running (user: $RUN_AS_USER)"
          exit 0
        elif [ "$STATUS" = "exited" ]; then
          echo "CRITICAL: Container $CONTAINER_NAME has exited (user: $RUN_AS_USER)"
          exit 2
        else
          echo "WARNING: Container $CONTAINER_NAME is in state: $STATUS (user: $RUN_AS_USER)"
          exit 1
        fi
      ''} $ARG1$ $ARG2$
    }

    define command {
      command_name    check_zfs_pool
      command_line    ${pkgs.nagiosPlugins.check_zfs}/bin/check_zfs --nosudo $ARG1$
    }

    define command {
      command_name    check_homeassistant_integrations
      command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -s -w $ARG2$ -c $ARG3$
    }

    define command {
      command_name    check_homeassistant_specific_integration
      command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -s -w $ARG2$ -c $ARG3$ -i $ARG4$
    }

    define command {
      command_name    check_homeassistant_integration_status
      command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -I -i $ARG2$
    }

    define command {
      command_name    check_backup_age
      command_line    ${checkBackupAge} $ARG1$ $ARG2$
    }

    define command {
      command_name    check_git_workspace_sync
      command_line    ${checkGitWorkspaceSync}
    }

    define command {
      command_name    check_git_workspace_stale
      command_line    ${checkGitWorkspaceStale} $ARG1$ $ARG2$ $ARG3$
    }

    ###############################################################################
    # HOSTS
    ###############################################################################

    define host {
      use                     linux-server
      host_name               vulcan
      alias                   Vulcan NixOS Server
      address                 127.0.0.1
      max_check_attempts      5
      check_period            24x7
      notification_interval   30
      notification_period     24x7
      contact_groups          admins
    }

    ###############################################################################
    # MONITORED HOSTS (from monitoredHosts list)
    ###############################################################################

    ${lib.concatMapStrings mkMonitoredHost monitoredHosts}

    ###############################################################################
    # HOST GROUPS
    ###############################################################################

    define hostgroup {
      hostgroup_name  linux-servers
      alias           Linux Servers
      members         vulcan
    }

    ###############################################################################
    # SERVICE GROUPS
    ###############################################################################

    define servicegroup {
      servicegroup_name  critical-infrastructure
      alias              Critical Infrastructure Services
    }

    define servicegroup {
      servicegroup_name  tank-dependent-services
      alias              Services Requiring /tank Mount
    }

    define servicegroup {
      servicegroup_name  monitoring-stack
      alias              Monitoring and Observability Services
    }

    define servicegroup {
      servicegroup_name  home-automation
      alias              Home Automation Services
    }

    define servicegroup {
      servicegroup_name  application-services
      alias              Application Services
    }

    define servicegroup {
      servicegroup_name  backup-services
      alias              Backup Services
    }

    define servicegroup {
      servicegroup_name  local-backups
      alias              Local System Backups
    }

    define servicegroup {
      servicegroup_name  maintenance-timers
      alias              Maintenance and Cleanup Timers
    }

    define servicegroup {
      servicegroup_name  email-services
      alias              Email Sync Services
    }

    define servicegroup {
      servicegroup_name  certificate-renewal
      alias              Certificate Renewal Timers
    }

    define servicegroup {
      servicegroup_name  containers
      alias              Container Services
    }

    define servicegroup {
      servicegroup_name  system-resources
      alias              System Resource Monitoring
    }

    define servicegroup {
      servicegroup_name  network-connectivity
      alias              Network Connectivity Checks
    }

    define servicegroup {
      servicegroup_name  protocol-checks
      alias              Protocol-Level Checks (IMAP, SMTP, DNS)
    }

    define servicegroup {
      servicegroup_name  ssl-certificates
      alias              SSL Certificate Monitoring
    }

    define servicegroup {
      servicegroup_name  home-assistant-integrations
      alias              Home Assistant Integration Monitoring
    }

    define servicegroup {
      servicegroup_name  network-hosts
      alias              Network Host Monitoring (PING)
    }

    ###############################################################################
    # SERVICES - SYSTEM RESOURCES
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Root Partition
      check_command           check_local_disk!20%!10%!/
      service_groups          system-resources
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Tank ZFS Pool
      check_command           check_zfs_pool!tank
      service_groups          system-resources
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Current Load
      check_command           check_local_load!15.0,10.0,5.0!30.0,25.0,20.0
      service_groups          system-resources
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Total Processes
      check_command           check_local_procs!250!400!RSZDT
      service_groups          system-resources
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Current Users
      check_command           check_local_users!20!50
      service_groups          system-resources
    }

    ###############################################################################
    # SERVICES - NETWORK CONNECTIVITY
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     SSH
      check_command           check_ssh
      service_groups          network-connectivity
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     PostgreSQL Connection
      check_command           check_tcp!5432
      service_groups          network-connectivity
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Nginx HTTP
      check_command           check_tcp!80
      service_groups          network-connectivity
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Nginx HTTPS
      check_command           check_tcp!443
      service_groups          network-connectivity
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Prometheus Port
      check_command           check_tcp!9090
      service_groups          network-connectivity
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Grafana Port
      check_command           check_tcp!3000
      service_groups          network-connectivity
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Home Assistant HTTP
      check_command           check_tcp!8123
      service_groups          network-connectivity
    }

    ###############################################################################
    # SERVICES - PROTOCOL CHECKS (IMAP, SMTP, DNS)
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     IMAP (Port 143)
      check_command           check_imap!143
      service_groups          protocol-checks
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     IMAPS (Port 993)
      check_command           check_imaps!993
      service_groups          protocol-checks
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     SMTP (Port 587)
      check_command           check_smtp!587
      service_groups          protocol-checks
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     DNS Resolver
      check_command           check_dns!vulcan.lan
      service_groups          protocol-checks
    }

    ###############################################################################
    # SERVICES - SSL CERTIFICATE CHECKS
    # Using daily-service template (check once per day instead of every 10 minutes)
    ###############################################################################

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: alertmanager.vulcan.lan
      check_command           check_ssl_cert!alertmanager.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: changes.vulcan.lan
      check_command           check_ssl_cert!changes.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: cockpit.vulcan.lan
      check_command           check_ssl_cert!cockpit.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: data.newartisans.com
      check_command           check_ssl_cert_external!data.newartisans.com
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: dns.vulcan.lan
      check_command           check_ssl_cert!dns.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: gitea.vulcan.lan
      check_command           check_ssl_cert!gitea.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: glance.vulcan.lan
      check_command           check_ssl_cert!glance.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: glances.vulcan.lan
      check_command           check_ssl_cert!glances.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: grafana.vulcan.lan
      check_command           check_ssl_cert!grafana.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: hass.vulcan.lan
      check_command           check_ssl_cert!hass.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: jellyfin.vulcan.lan
      check_command           check_ssl_cert!jellyfin.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: loki.vulcan.lan
      check_command           check_ssl_cert!loki.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: nagios.vulcan.lan
      check_command           check_ssl_cert!nagios.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: jupyter.vulcan.lan
      check_command           check_ssl_cert!jupyter.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: n8n.vulcan.lan
      check_command           check_ssl_cert!n8n.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: nextcloud.vulcan.lan
      check_command           check_ssl_cert!nextcloud.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: nodered.vulcan.lan
      check_command           check_ssl_cert!nodered.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: ntopng.vulcan.lan
      check_command           check_ssl_cert!ntopng.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: postgres.vulcan.lan
      check_command           check_ssl_cert!postgres.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: promtail.vulcan.lan
      check_command           check_ssl_cert!promtail.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: prometheus.vulcan.lan
      check_command           check_ssl_cert!prometheus.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: litellm.vulcan.lan
      check_command           check_ssl_cert!litellm.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: llama-swap.vulcan.lan
      check_command           check_ssl_cert!llama-swap.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: metabase.vulcan.lan
      check_command           check_ssl_cert!metabase.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: monica.vulcan.lan
      check_command           check_ssl_cert!monica.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: mindsdb.vulcan.lan
      check_command           check_ssl_cert!mindsdb.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: nocobase.vulcan.lan
      check_command           check_ssl_cert!nocobase.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: silly-tavern.vulcan.lan
      check_command           check_ssl_cert!silly-tavern.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: speedtest.vulcan.lan
      check_command           check_ssl_cert!speedtest.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: vdirsyncer.vulcan.lan
      check_command           check_ssl_cert!vdirsyncer.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: victoriametrics.vulcan.lan
      check_command           check_ssl_cert!victoriametrics.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: vanna.vulcan.lan
      check_command           check_ssl_cert!vanna.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: vulcan.lan
      check_command           check_ssl_cert!vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: wallabag.vulcan.lan
      check_command           check_ssl_cert!wallabag.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: budget.vulcan.lan
      check_command           check_ssl_cert!budget.vulcan.lan
      service_groups          ssl-certificates
    }

    define service {
      use                     daily-service
      host_name               vulcan
      service_description     SSL Cert: windows.vulcan.lan
      check_command           check_ssl_cert!windows.vulcan.lan
      service_groups          ssl-certificates
    }

    ###############################################################################
    # SERVICES - LOCAL BACKUPS
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Local Backup: /etc
      check_command           check_backup_age!etc!14400
      check_interval          15
      service_groups          local-backups
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Local Backup: /home
      check_command           check_backup_age!home!14400
      check_interval          15
      service_groups          local-backups
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Local Backup: /var
      check_command           check_backup_age!var!14400
      check_interval          15
      service_groups          local-backups
    }

    ###############################################################################
    # SERVICES - GIT WORKSPACE ARCHIVE
    ###############################################################################

    define service {
      use                     standard-service
      host_name               vulcan
      service_description     Git Workspace Sync Status
      check_command           check_git_workspace_sync
      check_interval          10
      service_groups          backup-services
    }

    define service {
      use                     standard-service
      host_name               vulcan
      service_description     Git Workspace Stale Repositories
      check_command           check_git_workspace_stale!3!10!25
      check_interval          60
      service_groups          backup-services
    }

    ###############################################################################
    # SERVICES - HOME ASSISTANT
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Home Assistant - Integration Status
      check_command           check_homeassistant_integration_status!127.0.0.1:8123!august,nest,ring,enphase_envoy,flume,miele,lg_thinq,cast,withings,webostv,homekit,nws
      check_interval          5
      max_check_attempts      2
      service_groups          home-assistant-integrations
    }

    ###############################################################################
    # AUTO-GENERATED SERVICE CHECKS
    # Services, Timers, and Containers monitored via systemd/podman
    ###############################################################################

    ${allServiceChecks}

    ###############################################################################
    # SERVICE TEMPLATES
    ###############################################################################

    define service {
      name                    generic-service
      active_checks_enabled   1
      passive_checks_enabled  1
      parallelize_check       1
      obsess_over_service     1
      check_freshness         0
      notifications_enabled   1
      event_handler_enabled   1
      flap_detection_enabled  1
      process_perf_data       1
      retain_status_information       1
      retain_nonstatus_information    1
      is_volatile             0
      check_period            24x7
      max_check_attempts      3
      check_interval          10
      retry_interval          2
      contact_groups          admins
      notification_options    u,c,r
      notification_interval   60
      notification_period     24x7
      register                0
    }

    # Critical services - check every 2 minutes
    define service {
      use                     generic-service
      name                    critical-service
      check_interval          2
      retry_interval          1
      register                0
    }

    # Standard services - check every 5 minutes
    define service {
      use                     generic-service
      name                    standard-service
      check_interval          5
      retry_interval          2
      register                0
    }

    # Low priority services - check every 15 minutes
    define service {
      use                     generic-service
      name                    low-priority-service
      check_interval          15
      retry_interval          5
      register                0
    }

    # Daily checks - SSL certificates and similar
    define service {
      use                     generic-service
      name                    daily-service
      check_interval          1440
      retry_interval          60
      max_check_attempts      2
      notification_interval   1440
      register                0
    }

    ###############################################################################
    # HOST TEMPLATES
    ###############################################################################

    define host {
      name                    linux-server
      use                     generic-host
      check_period            24x7
      check_interval          5
      retry_interval          1
      max_check_attempts      10
      check_command           check-host-alive
      notification_period     24x7
      notification_interval   120
      notification_options    d,u,r
      contact_groups          admins
      register                0
    }

    define host {
      name                    generic-host
      notifications_enabled   1
      event_handler_enabled   1
      flap_detection_enabled  1
      process_perf_data       1
      retain_status_information       1
      retain_nonstatus_information    1
      notification_period     24x7
      register                0
    }
  '';

  # Custom CGI configuration file with full authorization for nagiosadmin
  nagiosCGICfgFile = pkgs.writeText "nagios.cgi.conf" ''
    # Main configuration file
    main_config_file=/etc/nagios.cfg

    # Physical HTML path
    physical_html_path=${pkgs.nagios}/share

    # URL path
    url_html_path=/nagios

    # Enable authentication
    use_authentication=1
    use_ssl_authentication=0

    # Default user (empty = require auth)
    default_user_name=

    # Authorization settings - grant nagiosadmin full access to everything
    authorized_for_system_information=nagiosadmin
    authorized_for_configuration_information=nagiosadmin
    authorized_for_system_commands=nagiosadmin
    authorized_for_all_services=nagiosadmin
    authorized_for_all_hosts=nagiosadmin
    authorized_for_all_service_commands=nagiosadmin
    authorized_for_all_host_commands=nagiosadmin
    authorized_for_read_only=

    # Refresh rates (in seconds)
    refresh_rate=90
    host_status_refresh_rate=30
    service_status_refresh_rate=30

    # Lock file
    lock_file=/var/lib/nagios/nagios.lock

    # Enable pending states
    show_all_services_host_is_authorized_for=1

    # Result limit (0 = no limit)
    result_limit=100

    # Escape HTML tags
    escape_html_tags=1
  '';

in
{
  # Enable Nagios monitoring service
  services.nagios = {
    enable = true;

    # Use custom object definitions
    objectDefs = [ nagiosObjectDefs ];

    # Add monitoring plugins to PATH
    plugins = with pkgs; [
      monitoring-plugins
      nagiosPlugins.check_systemd
      nagiosPlugins.check_zfs
      podman
      coreutils
      gnugrep
      gnused
      file
      curl
      openssl
      perl
      bind.host  # for host command (DNS lookup)
      inetutils  # for hostname
      bc  # calculator for check_ssl_cert
      gawk  # required by check_ssl_cert for certificate parsing
      jq  # required by check_git_workspace_sync for JSON parsing
      findutils  # required by check_git_workspace_stale for find command
    ];

    # Validate configuration at build time
    validateConfig = true;

    # Use custom CGI configuration with authorization
    cgiConfigFile = nagiosCGICfgFile;

    # Extra configuration for nagios.cfg
    extraConfig = {
      # Log settings
      log_file = "/var/log/nagios/nagios.log";
      log_rotation_method = "d";
      log_archive_path = "/var/log/nagios/archives";

      # Performance data settings (for Prometheus exporter)
      process_performance_data = "1";
      service_perfdata_file = "/var/lib/nagios/service-perfdata";
      service_perfdata_file_template = "[SERVICEPERFDATA]\\t$TIMET$\\t$HOSTNAME$\\t$SERVICEDESC$\\t$SERVICEEXECUTIONTIME$\\t$SERVICELATENCY$\\t$SERVICEOUTPUT$\\t$SERVICEPERFDATA$";
      service_perfdata_file_mode = "a";
      service_perfdata_file_processing_interval = "60";

      host_perfdata_file = "/var/lib/nagios/host-perfdata";
      host_perfdata_file_template = "[HOSTPERFDATA]\\t$TIMET$\\t$HOSTNAME$\\t$HOSTEXECUTIONTIME$\\t$HOSTOUTPUT$\\t$HOSTPERFDATA$";
      host_perfdata_file_mode = "a";
      host_perfdata_file_processing_interval = "60";

      # Status retention
      retain_state_information = "1";
      state_retention_file = "/var/lib/nagios/retention.dat";
      retention_update_interval = "60";

      # Check settings
      enable_notifications = "1";
      execute_service_checks = "1";
      accept_passive_service_checks = "1";
      execute_host_checks = "1";
      accept_passive_host_checks = "1";

      # Performance tuning
      # Enable large installation optimizations for 280+ monitored services
      use_large_installation_tweaks = "1";
      # Disable environment macros to reduce CPU/memory overhead by 15-20%
      # Macros are passed via command line instead
      enable_environment_macros = "0";

      # ARM64 race condition workaround
      # Reduce to single worker process to avoid race conditions on ARM64 architecture
      # The check_workers directive controls how many worker processes Nagios spawns
      # Setting it to 1 eliminates inter-process race conditions that cause SEGV on ARM64
      check_workers = "1";
      # Increase concurrent checks to maximize single worker throughput
      max_concurrent_checks = "40";
      # Optimize result processing frequency (seconds between reaper runs)
      check_result_reaper_frequency = "10";
      # Balanced processing time to avoid latency buildup
      max_check_result_reaper_time = "15";

      # External commands
      check_external_commands = "1";
      command_file = "/var/lib/nagios/rw/nagios.cmd";
    };

    # Enable web interface (we'll proxy via nginx)
    enableWebInterface = true;
  };

  # SOPS secrets for Nagios
  sops.secrets = {
    "nagios-admin-password" = {
      sopsFile = common.secretsPath;
      owner = "nagios";
      group = "nagios";
      mode = "0400";
      restartUnits = [ "nagios.service" ];
    };
  };

  # Create htpasswd file for Nagios web interface
  systemd.services.nagios-htpasswd = {
    description = "Generate Nagios htpasswd file";
    wantedBy = [ "nagios.service" "nginx.service" ];
    before = [ "nagios.service" "nginx.service" ];
    after = [ "sops-nix.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      HTPASSWD_DIR="/var/lib/nagios"
      HTPASSWD_FILE="$HTPASSWD_DIR/htpasswd"

      # Ensure directory exists
      mkdir -p "$HTPASSWD_DIR"

      PASSWORD=$(cat ${config.sops.secrets."nagios-admin-password".path})

      # Create htpasswd file with bcrypt encryption
      echo "nagiosadmin:$(${pkgs.apacheHttpd}/bin/htpasswd -nbB nagiosadmin "$PASSWORD" | cut -d: -f2)" > "$HTPASSWD_FILE"

      # Set proper permissions - nginx group so nginx can read for basic auth
      chown nagios:nginx "$HTPASSWD_FILE"
      chmod 640 "$HTPASSWD_FILE"
    '';
  };

  # Nginx reverse proxy for Nagios web interface
  services.nginx.virtualHosts."nagios.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/nagios.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/nagios.vulcan.lan.key";

    # Basic auth for Nagios web interface
    basicAuthFile = "/var/lib/nagios/htpasswd";

    locations = {
      "/" = {
        root = "${pkgs.nagios}/share";
        index = "index.php index.html";
      };

      "/nagios/" = {
        alias = "${pkgs.nagios}/share/";
        index = "index.php index.html";
      };

      # CGI scripts - handle both /nagios/cgi-bin/*.cgi and /cgi-bin/*.cgi paths
      "~ ^/(nagios/)?cgi-bin/(.+\\.cgi)$" = {
        extraConfig = ''
          include ${pkgs.nginx}/conf/fastcgi_params;
          fastcgi_param AUTH_USER $remote_user;
          fastcgi_param REMOTE_USER $remote_user;
          fastcgi_param DOCUMENT_ROOT ${pkgs.nagios}/bin;
          fastcgi_param SCRIPT_FILENAME ${pkgs.nagios}/bin/$2;
          fastcgi_param SCRIPT_NAME $uri;
          fastcgi_param NAGIOS_CGI_CONFIG ${nagiosCGICfgFile};
          fastcgi_pass unix:/run/fcgiwrap-nagios.sock;
        '';
      };

      "~ \\.php$" = {
        root = "${pkgs.nagios}/share";
        extraConfig = ''
          include ${pkgs.nginx}/conf/fastcgi_params;
          fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
          fastcgi_pass unix:/run/phpfpm/nagios.sock;
        '';
      };
    };
  };

  # PHP-FPM pool for Nagios web interface
  services.phpfpm.pools.nagios = {
    user = "nagios";
    group = "nagios";

    settings = {
      "listen.owner" = "nginx";
      "listen.group" = "nginx";
      "listen.mode" = "0660";

      "pm" = "dynamic";
      "pm.max_children" = 5;
      "pm.start_servers" = 2;
      "pm.min_spare_servers" = 1;
      "pm.max_spare_servers" = 3;
    };
  };

  # Enable fcgiwrap instance for Nagios CGI scripts
  services.fcgiwrap.instances.nagios = {
    process = {
      user = "nagios";
      group = "nagios";
    };
    socket = {
      type = "unix";
      mode = "0660";
      user = "nagios";
      group = "nginx";
    };
  };

  # Certificate generation for Nagios web interface
  systemd.services.nagios-certificate = {
    description = "Generate Nagios TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [ pkgs.openssl pkgs.step-cli ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/nagios.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/nagios.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # Create self-signed certificate as fallback
      # User should generate proper certificate using step-ca
      echo "Creating temporary self-signed certificate for nagios.vulcan.lan"
      echo "Please generate a proper certificate using step-ca:"
      echo "  step ca certificate nagios.vulcan.lan $CERT_FILE $KEY_FILE \\"
      echo "    --ca-url https://localhost:8443 \\"
      echo "    --root /var/lib/step-ca/certs/root_ca.crt"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=nagios.vulcan.lan" \
        -addext "subjectAltName=DNS:nagios.vulcan.lan"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown -R nginx:nginx "$CERT_DIR"

      echo "Certificate generated successfully"
    '';
  };


  # Ensure Nagios starts after required services
  systemd.services.nagios = {
    after = [ "network.target" "postgresql.service" "nagios-rw-directory.service" ];
    wants = [ "postgresql.service" ];
    requires = [ "nagios-rw-directory.service" ];
  };

  # Ensure nginx user is in nagios group for CGI command access
  users.users.nginx.extraGroups = [ "nagios" ];

  # Ensure nagios user is in podman group for container monitoring
  # and johnw group for accessing git-workspace-archive
  users.users.nagios.extraGroups = [ "podman" "johnw" ];

  # Create command file directory with proper permissions
  systemd.services.nagios-rw-directory = {
    description = "Create Nagios command file directory";
    wantedBy = [ "nagios.service" ];
    before = [ "nagios.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      RW_DIR="/var/lib/nagios/rw"

      # Create directory if it doesn't exist
      mkdir -p "$RW_DIR"

      # Set ownership to nagios user and group
      chown nagios:nagios "$RW_DIR"

      # Set permissions: 2770 (setgid, rwx for owner/group, no access for others)
      # This allows both nagios daemon and web server to access the directory
      chmod 2770 "$RW_DIR"

      echo "Command file directory created with proper permissions"
    '';
  };

  # Create tmpfs mounts for Nagios volatile data (performance optimization)
  # This reduces disk I/O by keeping frequently-written files in RAM
  systemd.tmpfiles.rules = [
    # Spool directory for check results
    "d /run/nagios 0755 nagios nagios -"
    "d /run/nagios/spool 0755 nagios nagios -"
    "d /run/nagios/spool/checkresults 0755 nagios nagios -"

    # Allow nagios user to traverse /tank/Backups to check backup timestamps
    # Mode 0711 allows owner (johnw) full access, group and others can traverse (execute)
    # This enables nagios (member of johnw group) to access specific files like
    # /tank/Backups/Machines/Vulcan/.etc.latest without being able to list directory contents
    "z /tank/Backups 0711 johnw johnw -"
  ];

  # Ensure tmpfiles setup runs after ZFS mounts
  # Use 'wants' instead of 'requires' to avoid blocking during configuration switches
  # when ZFS mount units aren't available yet
  systemd.services.systemd-tmpfiles-resetup = {
    after = [ "tank-Backups.mount" ];
    wants = [ "tank-Backups.mount" ];
  };

  # Bind mount /run/nagios to /var/lib/nagios/spool for compatibility
  fileSystems."/var/lib/nagios/spool" = {
    device = "/run/nagios/spool";
    fsType = "none";
    options = [ "bind" ];
  };

  # Grant nagios user sudo access to podman for container monitoring
  # Note: ZFS monitoring uses --nosudo flag since /dev/zfs is world-readable/writable
  security.sudo.extraRules = [
    # Allow nagios to run podman as root (for root-level containers)
    {
      users = [ "nagios" ];
      commands = [{
        command = "${pkgs.podman}/bin/podman";
        options = [ "NOPASSWD" ];
      }];
    }
    # Allow nagios to run podman as container-db (for database-backed rootless containers)
    {
      users = [ "nagios" ];
      runAs = "container-db";
      commands = [{
        command = "${pkgs.podman}/bin/podman";
        options = [ "NOPASSWD" ];
      }];
    }
    # Allow nagios to run podman as container-monitor (for monitoring rootless containers)
    {
      users = [ "nagios" ];
      runAs = "container-monitor";
      commands = [{
        command = "${pkgs.podman}/bin/podman";
        options = [ "NOPASSWD" ];
      }];
    }
    # Allow nagios to run podman as container-misc (for miscellaneous rootless containers)
    {
      users = [ "nagios" ];
      runAs = "container-misc";
      commands = [{
        command = "${pkgs.podman}/bin/podman";
        options = [ "NOPASSWD" ];
      }];
    }
    # Allow nagios to run podman as container-web (for web application rootless containers)
    {
      users = [ "nagios" ];
      runAs = "container-web";
      commands = [{
        command = "${pkgs.podman}/bin/podman";
        options = [ "NOPASSWD" ];
      }];
    }
  ];

  # Enable daily email health reports
  services.nagios-daily-report = {
    enable = true;
    toEmail = "johnw@vulcan.lan";
    fromEmail = "nagios@vulcan.lan";
    schedule = "08:00";  # Send daily at 8:00 AM
  };
}
