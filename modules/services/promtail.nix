{ config, lib, pkgs, ... }:

{
  # Promtail log shipping agent for Loki
  services.promtail = {
    enable = true;

    configuration = {
      # Server configuration for Promtail's own metrics endpoint
      server = {
        http_listen_address = "127.0.0.1";
        http_listen_port = 9080;
        grpc_listen_address = "127.0.0.1";
        grpc_listen_port = 0; # Disable gRPC
      };

      # Position file to track what has been read
      positions = {
        filename = "/var/lib/promtail/positions.yaml";
      };

      # Loki client configuration
      clients = [
        {
          url = "http://localhost:3100/loki/api/v1/push";
          batchwait = "1s";
          batchsize = 1048576; # 1MB

          # Tenant ID (not needed for single-tenant Loki)
          # tenant_id = "default";

          # Timeout and retry settings
          timeout = "10s";

          # TLS configuration (not needed for localhost)
          # tls_config = {
          #   insecure_skip_verify = false;
          # };
        }
      ];

      # Scrape configurations for different log sources
      scrape_configs = [
        # Systemd journal logs
        {
          job_name = "systemd-journal";
          journal = {
            json = true;
            max_age = "5m";  # Only read last 5 minutes to prevent overwhelming Loki
            labels = {
              job = "systemd-journal";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__hostname" ];
              target_label = "hostname";
            }
            {
              source_labels = [ "__journal_priority" ];
              target_label = "priority";
            }
            {
              source_labels = [ "__journal_syslog_identifier" ];
              target_label = "syslog_identifier";
            }
            {
              # Drop audit logs - they generate 100+ logs/sec
              source_labels = [ "__journal_syslog_identifier" ];
              regex = "audit";
              action = "drop";
            }
          ];
        }

        # Nginx access logs
        {
          job_name = "nginx-access";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "nginx-access";
                host = "vulcan";
                __path__ = "/var/log/nginx/access.log";
              };
            }
          ];
          pipeline_stages = [
            {
              regex = {
                expression = ''^(?P<remote_addr>\S+) - (?P<remote_user>\S+) \[(?P<timestamp>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) (?P<protocol>\S+)" (?P<status>\d+) (?P<body_bytes_sent>\d+) "(?P<http_referer>[^"]*)" "(?P<http_user_agent>[^"]*)"'';
              };
            }
            {
              labels = {
                status = "";
                method = "";
                path = "";
              };
            }
            {
              timestamp = {
                source = "timestamp";
                format = "02/Jan/2006:15:04:05 -0700";
              };
            }
          ];
        }

        # Nginx error logs
        {
          job_name = "nginx-error";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "nginx-error";
                host = "vulcan";
                __path__ = "/var/log/nginx/error.log";
              };
            }
          ];
          pipeline_stages = [
            {
              regex = {
                expression = ''^(?P<timestamp>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[(?P<level>\w+)\] (?P<pid>\d+)#(?P<tid>\d+): (?P<message>.*)$'';
              };
            }
            {
              labels = {
                level = "";
              };
            }
            {
              timestamp = {
                source = "timestamp";
                format = "2006/01/02 15:04:05";
              };
            }
          ];
        }

        # PostgreSQL logs
        {
          job_name = "postgresql";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "postgresql";
                host = "vulcan";
                __path__ = "/var/log/postgresql/*.log";
              };
            }
          ];
          pipeline_stages = [
            {
              multiline = {
                firstline = ''^(\d{4}-\d{2}-\d{2}|\d{2}/\d{2}/\d{4})'';
                max_wait_time = "3s";
              };
            }
            {
              regex = {
                expression = ''^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \w+) \[(?P<pid>\d+)\] (?P<level>\w+): (?P<message>.*)$'';
              };
            }
            {
              labels = {
                level = "";
              };
            }
          ];
        }

        # Dovecot mail logs
        {
          job_name = "dovecot";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "dovecot";
                host = "vulcan";
                service = "mail";
                __path__ = "/var/log/dovecot/*.log";
              };
            }
          ];
          pipeline_stages = [
            {
              regex = {
                expression = ''^(?P<timestamp>\w+ \d+ \d{2}:\d{2}:\d{2}) (?P<service>\S+): (?P<level>\w+): (?P<message>.*)$'';
              };
            }
            {
              labels = {
                service = "";
                level = "";
              };
            }
            {
              timestamp = {
                source = "timestamp";
                format = "Jan 02 15:04:05";
                # Adjust year since syslog format doesn't include it
                location = "America/Los_Angeles";
              };
            }
          ];
        }

        # Postfix mail logs
        {
          job_name = "postfix";
          journal = {
            json = true;
            max_age = "5m";  # Only read last 5 minutes
            labels = {
              job = "postfix";
              host = "vulcan";
            };
            # No matches filter - will use relabel_configs to filter
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              # Keep only postfix related services
              source_labels = [ "__journal__systemd_unit" ];
              regex = "(postfix.*\\.service)";
              action = "keep";
            }
            {
              source_labels = [ "__journal_syslog_identifier" ];
              target_label = "component";
            }
          ];
        }

        # Docker container logs (if Docker is enabled)
        {
          job_name = "docker";
          docker_sd_configs = [
            {
              host = "unix:///var/run/docker.sock";
              refresh_interval = "30s";
            }
          ];
          relabel_configs = [
            {
              source_labels = [ "__meta_docker_container_name" ];
              target_label = "container";
              regex = "^/(.*)$";
              replacement = "$1";
            }
            {
              source_labels = [ "__meta_docker_container_label_com_docker_compose_service" ];
              target_label = "service";
            }
            {
              source_labels = [ "__meta_docker_container_label_com_docker_compose_project" ];
              target_label = "project";
            }
          ];
        }

        # Restic backup logs
        {
          job_name = "restic-backups";
          journal = {
            json = true;
            max_age = "5m";  # Only read last 5 minutes
            labels = {
              job = "restic";
              host = "vulcan";
            };
            # No matches filter - will get all journal entries
            # Filtering will be done via relabel_configs
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              # Only keep restic backup services
              source_labels = [ "__journal__systemd_unit" ];
              regex = "restic-backups-.*\\.service";
              action = "keep";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "backup_set";
              regex = "restic-backups-(.*)\\.service";
              replacement = "$1";
            }
          ];
        }

        # Nextcloud logs (if present)
        {
          job_name = "nextcloud";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "nextcloud";
                host = "vulcan";
                __path__ = "/var/lib/nextcloud/data/nextcloud.log";
              };
            }
          ];
          pipeline_stages = [
            {
              json = {
                expressions = {
                  time = "time";
                  level = "level";
                  message = "message";
                  app = "app";
                  method = "method";
                  url = "url";
                  user = "user";
                };
              };
            }
            {
              labels = {
                level = "";
                app = "";
                user = "";
              };
            }
            {
              timestamp = {
                source = "time";
                format = "RFC3339";
              };
            }
          ];
        }

        # Jellyfin logs (if present)
        {
          job_name = "jellyfin";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "jellyfin";
                host = "vulcan";
                __path__ = "/var/lib/jellyfin/log/*.log";
              };
            }
          ];
          pipeline_stages = [
            {
              regex = {
                expression = ''^(?P<timestamp>\[\d{2}:\d{2}:\d{2}\]) \[(?P<level>\w+)\] (?P<component>[^:]+): (?P<message>.*)$'';
              };
            }
            {
              labels = {
                level = "";
                component = "";
              };
            }
          ];
        }
      ];
    };
  };

  # Ensure Promtail user has access to journal
  users.users.promtail = {
    extraGroups = [ "systemd-journal" "nginx" "docker" ];
  };

  # Create necessary directories
  systemd.tmpfiles.rules = [
    "d /var/lib/promtail 0755 promtail promtail -"
    "f /var/lib/promtail/positions.yaml 0644 promtail promtail -"
  ];

  # Ensure Promtail starts after Loki
  systemd.services.promtail = {
    after = [ "loki.service" "network-online.target" ];
    wants = [ "loki.service" "network-online.target" ];

    # Restart on failure with delay
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # Helper script to test Promtail configuration
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-promtail" ''
      echo "=== Promtail Service Status ==="
      systemctl is-active promtail && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== Promtail Targets ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9080/targets | ${pkgs.jq}/bin/jq . || echo "API not responding"

      echo ""
      echo "=== Promtail Metrics ==="
      ${pkgs.curl}/bin/curl -s http://localhost:9080/metrics | grep -E "promtail_sent_entries_total|promtail_dropped_entries_total" | head -10

      echo ""
      echo "=== Position File ==="
      if [ -f /var/lib/promtail/positions.yaml ]; then
        echo "Positions tracked:"
        cat /var/lib/promtail/positions.yaml | head -20
      else
        echo "No position file found"
      fi

      echo ""
      echo "=== Recent Logs ==="
      journalctl -u promtail -n 10 --no-pager
    '')

    # Script to test log ingestion
    (writeShellScriptBin "test-loki-ingestion" ''
      echo "Sending test log to systemd journal..."
      echo "TEST: Loki ingestion test at $(date)" | systemd-cat -t loki-test -p info

      echo "Waiting 5 seconds for ingestion..."
      sleep 5

      echo "Querying Loki for test log..."
      ${pkgs.grafana-loki}/bin/logcli \
        --addr="http://localhost:3100" \
        query '{job="systemd-journal", syslog_identifier="loki-test"}' \
        --limit=5 \
        --since=1m
    '')
  ];
}