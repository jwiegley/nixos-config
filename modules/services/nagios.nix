{ config, lib, pkgs, secrets, ... }:

let
  # Common helper functions
  common = import ../lib/common.nix { inherit secrets; };

  # Nagios configuration directory
  nagiosCfgDir = "/var/lib/nagios";

  # Helper function to generate systemd service checks
  mkServiceCheck = serviceName: displayName: ''
    define service {
      use                     generic-service
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_systemd_service!${serviceName}
    }
  '';

  # Helper function for services that depend on mount points
  # These services use ConditionPathIsMountPoint and need special monitoring
  mkConditionalServiceCheck = serviceName: displayName: mountPoint: ''
    define service {
      use                     generic-service
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_systemd_service_conditional!${serviceName}!${mountPoint}
    }
  '';

  # Helper function to generate timer checks (monitors both timer and associated service)
  mkTimerCheck = timerName: displayName: ''
    define service {
      use                     generic-service
      host_name               vulcan
      service_description     ${displayName} (Timer)
      check_command           check_systemd_service!${timerName}
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     ${displayName} (Service)
      check_command           check_systemd_service!${lib.removeSuffix ".timer" timerName}.service
    }
  '';

  # Helper function for timers whose services depend on mount points
  mkConditionalTimerCheck = timerName: displayName: mountPoint: ''
    define service {
      use                     generic-service
      host_name               vulcan
      service_description     ${displayName} (Timer)
      check_command           check_systemd_service!${timerName}
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     ${displayName} (Service)
      check_command           check_systemd_service_conditional!${lib.removeSuffix ".timer" timerName}.service!${mountPoint}
    }
  '';

  # Helper function to generate container checks
  mkContainerCheck = containerName: displayName: ''
    define service {
      use                     generic-service
      host_name               vulcan
      service_description     ${displayName}
      check_command           check_podman_container!${containerName}
    }
  '';

  # Service categories for organized monitoring
  # Critical Infrastructure Services (no mount dependencies)
  criticalServices = [
    { name = "postgresql.service"; display = "PostgreSQL Database"; }
    { name = "nginx.service"; display = "Nginx Web Server"; }
    { name = "dovecot.service"; display = "Dovecot IMAP Server"; }
    { name = "postfix.service"; display = "Postfix Mail Server"; }
    { name = "step-ca.service"; display = "Step-CA Certificate Authority"; }
    { name = "samba-wsdd.service"; display = "Samba Web Service Discovery"; }
    { name = "technitium-dns-server.service"; display = "Technitium DNS Server"; }
  ];

  # Critical Services that depend on /tank mount
  tankDependentServices = [
    { name = "nextcloud-setup.service"; display = "Nextcloud Setup"; mount = "/tank"; }
    { name = "nextcloud-update-db.service"; display = "Nextcloud Database Update"; mount = "/tank"; }
    { name = "nextcloud-cron.service"; display = "Nextcloud Cron"; mount = "/tank"; }
    { name = "samba.service"; display = "Samba Service"; mount = "/tank"; }
    { name = "samba-smbd.service"; display = "Samba SMB Daemon"; mount = "/tank"; }
    { name = "samba-nmbd.service"; display = "Samba NetBIOS Name Server"; mount = "/tank"; }
    { name = "samba-winbindd.service"; display = "Samba Winbind Daemon"; mount = "/tank"; }
    { name = "prometheus-zfs-exporter.service"; display = "ZFS Metrics Exporter"; mount = "/tank"; }
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
    { name = "redis-litellm.service"; display = "Redis (LiteLLM)"; }
    { name = "redis-nextcloud.service"; display = "Redis (Nextcloud)"; }
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
  ];

  # Certificate Renewal Timers
  certRenewalTimers = [
    { name = "dovecot-cert-renewal.timer"; display = "Dovecot Cert Renewal"; }
    { name = "nginx-cert-renewal.timer"; display = "Nginx Cert Renewal"; }
    { name = "postgresql-cert-renewal.timer"; display = "PostgreSQL Cert Renewal"; }
    { name = "postfix-cert-renewal.timer"; display = "Postfix Cert Renewal"; }
  ];

  # Podman Containers
  containers = [
    { name = "litellm"; display = "LiteLLM API Proxy"; }
    { name = "opnsense-exporter"; display = "OPNsense Metrics Exporter"; }
    { name = "speedtest"; display = "Open SpeedTest"; }
    { name = "silly-tavern"; display = "Silly Tavern"; }
    { name = "technitium-dns-exporter"; display = "Technitium DNS Exporter"; }
    { name = "wallabag"; display = "Wallabag Read-Later"; }
  ];

  # Container systemd services (for Quadlet-managed containers)
  containerSystemdServices = [
    { name = "container@secure-nginx.service"; display = "Secure Nginx Container"; }
  ];

  # Generate all service checks
  allServiceChecks = lib.concatStrings [
    # Critical Infrastructure
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display) criticalServices)

    # Tank-Dependent Services (use conditional check)
    (lib.concatMapStrings (s: mkConditionalServiceCheck s.name s.display s.mount) tankDependentServices)

    # Monitoring Stack
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display) monitoringServices)

    # Home Automation
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display) homeAutomationServices)

    # Applications
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display) applicationServices)

    # Restic Backup Services (use conditional check)
    (lib.concatMapStrings (s: mkConditionalServiceCheck s.name s.display s.mount) resticBackupServices)

    # Container Services
    (lib.concatMapStrings (s: mkServiceCheck s.name s.display) containerSystemdServices)

    # Maintenance Timers
    (lib.concatMapStrings (t: mkTimerCheck t.name t.display) maintenanceTimers)

    # Tank-Dependent Timers (use conditional check for services)
    (lib.concatMapStrings (t: mkConditionalTimerCheck t.name t.display t.mount) tankDependentTimers)

    # Email Timers
    (lib.concatMapStrings (t: mkTimerCheck t.name t.display) emailTimers)

    # Certificate Renewal Timers
    (lib.concatMapStrings (t: mkTimerCheck t.name t.display) certRenewalTimers)

    # Podman Containers
    (lib.concatMapStrings (c: mkContainerCheck c.name c.display) containers)
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
      service_notification_options    w,u,c,r
      host_notification_options       d,u,r
      service_notification_commands   notify-service-by-email
      host_notification_commands      notify-host-by-email
      email                           johnw@localhost
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
      command_name    check_systemd_service
      command_line    ${pkgs.check_systemd}/bin/check_systemd -u $ARG1$
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
      command_name    check_zfs_pool
      command_line    ${pkgs.check_zfs}/bin/check_zfs -p $ARG1$
    }

    define command {
      command_name    check_homeassistant_integrations
      command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -s -w $ARG2$ -c $ARG3$
    }

    define command {
      command_name    check_homeassistant_specific_integration
      command_line    /run/current-system/sw/bin/check_homeassistant_integrations_wrapper -H $ARG1$ -s -w $ARG2$ -c $ARG3$ -i $ARG4$
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
    # HOST GROUPS
    ###############################################################################

    define hostgroup {
      hostgroup_name  linux-servers
      alias           Linux Servers
      members         vulcan
    }

    ###############################################################################
    # SERVICES - SYSTEM RESOURCES
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Root Partition
      check_command           check_local_disk!20%!10%!/
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Tank ZFS Pool
      check_command           check_zfs_pool!tank
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Current Load
      check_command           check_local_load!15.0,10.0,5.0!30.0,25.0,20.0
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Total Processes
      check_command           check_local_procs!250!400!RSZDT
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Current Users
      check_command           check_local_users!20!50
    }

    ###############################################################################
    # SERVICES - NETWORK CONNECTIVITY
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     SSH
      check_command           check_ssh
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     PostgreSQL Connection
      check_command           check_tcp!5432
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Nginx HTTP
      check_command           check_tcp!80
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Nginx HTTPS
      check_command           check_tcp!443
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Prometheus Port
      check_command           check_tcp!9090
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Grafana Port
      check_command           check_tcp!3000
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Home Assistant HTTP
      check_command           check_tcp!8123
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Home Assistant - All Integrations
      check_command           check_homeassistant_integrations!hass.vulcan.lan!5!10
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
      notification_options    w,u,c,r
      notification_interval   60
      notification_period     24x7
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
      check_systemd
      check_zfs
      podman
      coreutils
      gnugrep
      gnused
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
      use_large_installation_tweaks = "0";
      enable_environment_macros = "1";

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
  users.users.nagios.extraGroups = [ "podman" ];

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

  # Add monitoring check script
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-nagios" ''
      echo "=== Nagios Status ==="
      systemctl is-active nagios && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== Nagios Process Info ==="
      systemctl status nagios --no-pager | head -20

      echo ""
      echo "=== Recent Nagios Logs ==="
      tail -n 20 /var/log/nagios/nagios.log 2>/dev/null || echo "No logs available"

      echo ""
      echo "=== Web Interface Access ==="
      ${pkgs.curl}/bin/curl -ks -o /dev/null -w "HTTP Status: %{http_code}\n" https://nagios.vulcan.lan/ || \
        echo "Note: HTTPS test requires valid DNS or /etc/hosts entry for nagios.vulcan.lan"

      echo ""
      echo "=== Prometheus Metrics ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9267/metrics | head -20

      echo ""
      echo "=== Certificate Status ==="
      if [ -f /var/lib/nginx-certs/nagios.vulcan.lan.crt ]; then
        ${pkgs.openssl}/bin/openssl x509 -in /var/lib/nginx-certs/nagios.vulcan.lan.crt -noout -dates
      else
        echo "Certificate not yet generated"
      fi

      echo ""
      echo "=== Current Service Status ==="
      if [ -f /var/lib/nagios/status.dat ]; then
        echo "Status file exists ($(wc -l < /var/lib/nagios/status.dat) lines)"
        grep -c "servicestatus {" /var/lib/nagios/status.dat 2>/dev/null && echo " services monitored" || true
      else
        echo "Status file not found"
      fi
    '')
  ];


  # Grant nagios user sudo access to podman for container monitoring
  security.sudo.extraRules = [{
    users = [ "nagios" ];
    commands = [{
      command = "${pkgs.podman}/bin/podman";
      options = [ "NOPASSWD" ];
    }];
  }];
}
