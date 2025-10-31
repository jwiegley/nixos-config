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
          timeout = "10s";
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
            {
              # Drop low-priority logs (5=notice, 6=info, 7=debug)
              # Keep only 0-4 (emerg, alert, crit, err, warning)
              # This reduces log volume by 99%+ while preserving critical events
              source_labels = [ "__journal_priority" ];
              regex = "[5-7]";
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

        # Dovecot mail logs

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

        # Jellyfin logs
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

        # mbsync logs for mail synchronization
        {
          job_name = "mbsync";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "mbsync";
                host = "vulcan";
                user = "johnw";
                __path__ = "/var/log/mbsync-johnw/*.log";
              };
            }
          ];
          pipeline_stages = [
            {
              multiline = {
                firstline = ''^(\d{4}-\d{2}-\d{2}|\w+\s+\d+)'';
                max_wait_time = "3s";
              };
            }
            {
              regex = {
                expression = ''^(?P<message>.*)$'';
              };
            }
          ];
        }
        {
          job_name = "mbsync-assembly";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "mbsync";
                host = "vulcan";
                user = "assembly";
                __path__ = "/var/log/mbsync-assembly/*.log";
              };
            }
          ];
          pipeline_stages = [
            {
              multiline = {
                firstline = ''^(\d{4}-\d{2}-\d{2}|\w+\s+\d+)'';
                max_wait_time = "3s";
              };
            }
            {
              regex = {
                expression = ''^(?P<message>.*)$'';
              };
            }
          ];
        }

        # Audit logs (separate from journal to allow specific handling)

        # Backup failure logs
        {
          job_name = "backup-failures";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "backup-failures";
                host = "vulcan";
                __path__ = "/var/log/backup-failures.log";
              };
            }
          ];
        }

        # sudo logs
        {
          job_name = "sudo";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "sudo";
                host = "vulcan";
                __path__ = "/var/log/sudo.log";
              };
            }
          ];
          pipeline_stages = [
            {
              regex = {
                expression = ''^(?P<timestamp>\w+\s+\d+\s+\d{2}:\d{2}:\d{2})\s+(?P<hostname>\S+)\s+sudo:\s+(?P<user>\S+)\s+:\s+(?P<message>.*)$'';
              };
            }
            {
              labels = {
                user = "";
              };
            }
            {
              timestamp = {
                source = "timestamp";
                format = "Jan 02 15:04:05";
                location = "America/Los_Angeles";
              };
            }
          ];
        }

        # Step-CA certificate authority logs from journal
        {
          job_name = "step-ca";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "step-ca";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "step-ca\\.service";
              action = "keep";
            }
          ];
        }

        # Technitium DNS Server logs from journal
        {
          job_name = "technitium-dns";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "technitium-dns";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "technitium-dns-server\\.service";
              action = "keep";
            }
          ];
        }

        # Grafana logs from journal
        {
          job_name = "grafana";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "grafana";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "grafana\\.service";
              action = "keep";
            }
          ];
        }

        # Prometheus and exporters logs from journal
        {
          job_name = "prometheus-stack";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "prometheus-stack";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "(prometheus.*\\.service|alertmanager\\.service)";
              action = "keep";
            }
            {
              # Extract service name for better categorization
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service";
              regex = "(prometheus|alertmanager|.*-exporter).*";
              replacement = "$1";
            }
          ];
        }

        # Loki logs from journal
        {
          job_name = "loki";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "loki";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "loki\\.service";
              action = "keep";
            }
          ];
        }

        # PGAdmin logs from journal
        {
          job_name = "pgadmin";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "pgadmin";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "pgadmin\\.service";
              action = "keep";
            }
          ];
        }

        # Redis instances logs from journal
        {
          job_name = "redis";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "redis";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "redis-.*\\.service";
              action = "keep";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "instance";
              regex = "redis-(.*)\\.service";
              replacement = "$1";
            }
          ];
        }

        # Glance dashboard and GitHub extension logs from journal
        {
          job_name = "glance";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "glance";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "glance.*\\.service";
              action = "keep";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "component";
              regex = "glance(-(.*))?.*";
              replacement = "$2";
            }
          ];
        }

        # Container logs for services running in Podman
        {
          job_name = "podman-containers";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "podman-containers";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "(silly-tavern|wallabag|litellm|opnsense-exporter|opnsense-api-transformer)\\.service";
              action = "keep";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "container";
              regex = "(.*)\\.service";
              replacement = "$1";
            }
            {
              source_labels = [ "__journal__comm" ];
              target_label = "process";
            }
          ];
        }

        # Secure nginx container logs from journal
        {
          job_name = "secure-nginx";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "secure-nginx";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "container@secure-nginx\\.service";
              action = "keep";
            }
          ];
        }

        # ZFS Event Daemon logs from journal
        {
          job_name = "zfs-zed";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "zfs-zed";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "zfs-zed\\.service";
              action = "keep";
            }
          ];
        }

        # Bolt thunderbolt daemon logs from journal
        {
          job_name = "bolt";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "bolt";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "bolt\\.service";
              action = "keep";
            }
          ];
        }

        # System authentication logs from journal
        {
          job_name = "auth";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "auth";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "(sshd|polkit)\\.service";
              action = "keep";
            }
            {
              source_labels = [ "__journal_priority" ];
              target_label = "priority";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service";
              regex = "(.*)\\.service";
              replacement = "$1";
            }
          ];
        }

        # PHPFPM Nextcloud logs from journal
        {
          job_name = "phpfpm-nextcloud";
          journal = {
            json = true;
            max_age = "5m";
            labels = {
              job = "phpfpm-nextcloud";
              host = "vulcan";
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "phpfpm-nextcloud\\.service";
              action = "keep";
            }
          ];
        }
      ];
    };
  };

  # Ensure Promtail user has access to journal and log files
  users.users.promtail = {
    extraGroups = [
      "systemd-journal"
      "nginx"
      "podman"    # For Podman/Docker socket access
      "jellyfin"  # For Jellyfin logs
      "wheel"     # For audit logs
      "adm"       # For sudo logs
    ];
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

  # Nginx reverse proxy configuration for Promtail web UI
  services.nginx.virtualHosts."promtail.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/promtail.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/promtail.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.promtail.configuration.server.http_listen_port}";
      recommendedProxySettings = true;
    };
  };

  # Prometheus scrape configuration for Promtail metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "promtail";
      static_configs = [{
        targets = [ "localhost:${toString config.services.promtail.configuration.server.http_listen_port}" ];
      }];
      scrape_interval = "30s";
    }
  ];

  # Helper script to test Promtail configuration
  environment.systemPackages = with pkgs; [
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
