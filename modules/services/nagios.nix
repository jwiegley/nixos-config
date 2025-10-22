{ config, lib, pkgs, secrets, ... }:

let
  # Common helper functions
  common = import ../lib/common.nix { inherit secrets; };

  # Nagios configuration directory
  nagiosCfgDir = "/var/lib/nagios";

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
      command_name    check_postgres
      command_line    ${pkgs.monitoring-plugins}/bin/check_pgsql -H $HOSTADDRESS$ -d $ARG1$
    }

    define command {
      command_name    check_podman_container
      command_line    ${pkgs.writeShellScript "check_podman_container.sh" ''
        #!/usr/bin/env bash
        CONTAINER_NAME="$1"

        # Check if container exists
        if ! ${pkgs.podman}/bin/podman container exists "$CONTAINER_NAME"; then
          echo "CRITICAL: Container $CONTAINER_NAME does not exist"
          exit 2
        fi

        # Get container status
        STATUS=$(${pkgs.podman}/bin/podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)

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

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Swap Usage
      check_command           check_local_swap!20!10
    }

    ###############################################################################
    # SERVICES - CRITICAL SYSTEM SERVICES
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
      service_description     PostgreSQL Service
      check_command           check_systemd_service!postgresql.service
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
      service_description     Nginx Service
      check_command           check_systemd_service!nginx.service
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
      service_description     Dovecot IMAP
      check_command           check_systemd_service!dovecot.service
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Postfix
      check_command           check_systemd_service!postfix.service
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Step-CA
      check_command           check_systemd_service!step-ca.service
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Samba
      check_command           check_systemd_service!smbd.service
    }

    ###############################################################################
    # SERVICES - MONITORING STACK
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Prometheus
      check_command           check_systemd_service!prometheus.service
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
      service_description     Grafana
      check_command           check_systemd_service!grafana.service
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
      service_description     Loki
      check_command           check_systemd_service!loki.service
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Promtail
      check_command           check_systemd_service!promtail.service
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Alertmanager
      check_command           check_systemd_service!alertmanager.service
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     VictoriaMetrics
      check_command           check_systemd_service!victoriametrics.service
    }

    ###############################################################################
    # SERVICES - HOME AUTOMATION
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Home Assistant
      check_command           check_systemd_service!home-assistant.service
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Home Assistant HTTP
      check_command           check_tcp!8123
    }

    ###############################################################################
    # SERVICES - PODMAN CONTAINERS
    ###############################################################################

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     LiteLLM Container
      check_command           check_podman_container!litellm
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     OPNsense Exporter Container
      check_command           check_podman_container!opnsense-exporter
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Open SpeedTest Container
      check_command           check_podman_container!speedtest
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Silly Tavern Container
      check_command           check_podman_container!silly-tavern
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Technitium DNS Exporter Container
      check_command           check_podman_container!technitium-dns-exporter
    }

    define service {
      use                     generic-service
      host_name               vulcan
      service_description     Wallabag Container
      check_command           check_podman_container!wallabag
    }

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

  # Nagios Prometheus exporter for metrics integration
  systemd.services.nagios-prometheus-exporter = {
    description = "Nagios Prometheus Exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "nagios.service" ];
    wants = [ "nagios.service" ];

    serviceConfig = {
      Type = "simple";
      User = "nagios";
      Group = "nagios";
      Restart = "always";
      RestartSec = 10;

      # Simple exporter that reads Nagios status data
      ExecStart = let
        exporterScript = pkgs.writeShellScript "nagios-exporter.sh" ''
          #!/usr/bin/env bash

          # Simple HTTP server that exports Nagios status as Prometheus metrics
          PORT=9267

          # Create named pipe for HTTP server
          FIFO="/tmp/nagios-exporter-$$.fifo"
          trap "rm -f $FIFO" EXIT
          mkfifo $FIFO

          echo "Nagios Prometheus Exporter listening on port $PORT"

          while true; do
            # Read HTTP request
            cat $FIFO | ${pkgs.netcat}/bin/nc -l -p $PORT > >(
              # Parse status.dat and generate Prometheus metrics
              echo "HTTP/1.1 200 OK"
              echo "Content-Type: text/plain"
              echo ""

              # Service status metrics
              echo "# HELP nagios_service_status Current status of Nagios services (0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN)"
              echo "# TYPE nagios_service_status gauge"

              if [ -f /var/lib/nagios/status.dat ]; then
                ${pkgs.gawk}/bin/awk '
                  /servicestatus {/ { in_service=1; service=""; host=""; state="" }
                  in_service && /host_name=/ { host=$0; gsub(/.*host_name=/, "", host) }
                  in_service && /service_description=/ { service=$0; gsub(/.*service_description=/, "", service) }
                  in_service && /current_state=/ { state=$0; gsub(/.*current_state=/, "", state) }
                  in_service && /}/ {
                    if (host && service && state != "") {
                      print "nagios_service_status{host=\"" host "\",service=\"" service "\"} " state
                    }
                    in_service=0
                  }
                ' /var/lib/nagios/status.dat
              fi

              # Host status metrics
              echo "# HELP nagios_host_status Current status of Nagios hosts (0=UP, 1=DOWN, 2=UNREACHABLE)"
              echo "# TYPE nagios_host_status gauge"

              if [ -f /var/lib/nagios/status.dat ]; then
                ${pkgs.gawk}/bin/awk '
                  /hoststatus {/ { in_host=1; host=""; state="" }
                  in_host && /host_name=/ { host=$0; gsub(/.*host_name=/, "", host) }
                  in_host && /current_state=/ { state=$0; gsub(/.*current_state=/, "", state) }
                  in_host && /}/ {
                    if (host && state != "") {
                      print "nagios_host_status{host=\"" host "\"} " state
                    }
                    in_host=0
                  }
                ' /var/lib/nagios/status.dat
              fi

              # Nagios process metrics
              echo "# HELP nagios_up Whether Nagios is running (1=up, 0=down)"
              echo "# TYPE nagios_up gauge"
              if systemctl is-active nagios.service > /dev/null 2>&1; then
                echo "nagios_up 1"
              else
                echo "nagios_up 0"
              fi

            ) > $FIFO
          done
        '';
      in "${exporterScript}";
    };
  };

  # Add Nagios exporter to Prometheus scrape configs
  services.prometheus.scrapeConfigs = [
    {
      job_name = "nagios";
      static_configs = [{
        targets = [ "localhost:9267" ];
      }];
      scrape_interval = "30s";
    }
  ];

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

  # Allow Nagios exporter port on localhost
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 9267 ];
}
