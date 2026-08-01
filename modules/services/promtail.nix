{
  config,
  lib,
  pkgs,
  ...
}:

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
        grpc_listen_port = 0; # 0 = pick a free ephemeral port, NOT "off" — the gRPC server still listens (on 127.0.0.1)
      };

      # Position file to track what has been read
      positions = {
        filename = "/var/lib/promtail/positions.yaml";
        sync_period = "10s"; # How often to update positions
        ignore_invalid_yaml = true; # Don't crash on corrupted positions
      };

      # Loki client configuration
      clients = [
        {
          url = "http://localhost:3100/loki/api/v1/push";
          batchwait = "2s"; # Increased from 1s to reduce CPU overhead
          batchsize = 2097152; # Increased to 2MB for more efficient batching
          timeout = "10s";
        }
      ];

      # Scrape configurations for different log sources
      scrape_configs = [
        # Systemd journal logs - CONSOLIDATED config for all journal-based sources
        # This single scraper replaces 15+ individual journal scrapers for better performance
        {
          job_name = "systemd-journal";
          journal = {
            json = true;
            max_age = "5m"; # Only read last 5 minutes to prevent overwhelming Loki
            labels = {
              job = "systemd-journal";
              host = "vulcan";
            };
          };
          relabel_configs = [
            # Extract basic labels from journal
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
              source_labels = [ "__journal__comm" ];
              target_label = "process";
            }

            # Extract service_type for major service categories
            # This consolidates the filtering logic from individual scrapers
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(postfix).*\\.service";
              replacement = "mail";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(restic-backups-.*)\\service";
              replacement = "backup";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(step-ca|technitium-dns-server)\\.service";
              replacement = "infrastructure";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(grafana|loki|prometheus.*|alertmanager)\\.service";
              replacement = "monitoring";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(pgadmin|redis-.*)\\.service";
              replacement = "database";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(glance.*|wallabag)\\.service";
              replacement = "application";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(container@.*|opnsense-.*)\\.service";
              replacement = "container";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(zfs-zed|bolt)\\.service";
              replacement = "system";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "(sshd|polkit)\\.service";
              replacement = "auth";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "service_type";
              regex = "phpfpm-(.*)\\.service";
              replacement = "webapp";
            }

            # Extract instance name for services with multiple instances (e.g., redis-loki, redis-gitea)
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "instance";
              regex = "redis-(.*)\\.service";
              replacement = "$1";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "backup_set";
              regex = "restic-backups-(.*)\\.service";
              replacement = "$1";
            }
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "container";
              regex = "container@(.*)\\.service";
              replacement = "$1";
            }

            # Extract component from postfix, glance
            {
              source_labels = [ "__journal_syslog_identifier" ];
              target_label = "component";
              regex = "(postfix/.*)";
              replacement = "$1";
            }

            # Drop audit logs - they generate 100+ logs/sec
            {
              source_labels = [ "__journal_syslog_identifier" ];
              regex = "audit";
              action = "drop";
            }

            # Drop low-priority logs (5=notice, 6=info, 7=debug)
            # Keep only 0-4 (emerg, alert, crit, err, warning)
            # This reduces log volume by 99%+ while preserving critical events
            {
              source_labels = [ "__journal_priority" ];
              regex = "[5-7]";
              action = "drop";
            }
          ];
        }

        # SSH authentication journal scrape (security monitoring)
        # The consolidated systemd-journal scrape above DROPS priority 5-7
        # (notice/info/debug), which silently discards sshd auth events
        # (Failed password / Invalid user / Accepted ... all log at info).
        # This dedicated scrape ingests the SAME journal but KEEPS ONLY the
        # sshd.service unit (relabel action=keep) and has NO priority-drop
        # stage, so auth events reach Loki under job="sshd".
        {
          job_name = "sshd";
          journal = {
            json = true;
            max_age = "5m"; # Match the main journal scrape window
            labels = {
              job = "sshd";
              host = "vulcan";
            };
          };
          relabel_configs = [
            # Keep ONLY sshd.service lines so nothing else is duplicated
            # into Loki by this second journal reader.
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "sshd\\.service";
              action = "keep";
            }
            # Carry over the same descriptive labels as the main scrape
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
              source_labels = [ "__journal__comm" ];
              target_label = "process";
            }
          ];
        }

        # Home Assistant + Node-RED journal scrape (application error visibility).
        #
        # Added 2026-07-29. Both services log EVERYTHING at priority 6 (info) because they
        # write plain text to stdout with no "<N>" syslog prefix, so the consolidated
        # systemd-journal scrape above -- which drops priority 5-7 -- discarded 100% of their
        # output including every traceback. Measured over 3 days before this change:
        #   home-assistant  12,276 of 12,279 lines at priority 6, containing ~1,046
        #                   error-shaped lines (Error/Traceback/Exception/failed)
        #   node-red        144 of 145 at priority 6, 5 error-shaped
        # None of it reached Loki. That is why the HA climate.set_temperature TypeError
        # (28 failures over 3.2 days, setpoints silently never applied) and the 17-day-dead
        # mail_and_packages integration were invisible to every log-based rule.
        #
        # matter-server is deliberately NOT included: it logs at priority 3, so it already
        # passes the consolidated scrape. Re-measured over the full journal: 27,494 of 27,662
        # lines at priority 3 (99.4%). An earlier version of this comment said 12,197 of 12,281,
        # which was a narrower window -- the load-bearing conclusion is unchanged.
        #
        # Same shape as the sshd and postgres scrapes above: same journal, action=keep on the
        # units of interest, and NO priority-drop stage.
        {
          job_name = "ha-nodered";
          journal = {
            json = true;
            max_age = "5m"; # Match the main journal scrape window
            labels = {
              job = "ha-nodered";
              host = "vulcan";
            };
          };
          relabel_configs = [
            # Keep ONLY these two units so nothing else is duplicated into Loki.
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "(home-assistant|node-red)\\.service";
              action = "keep";
            }
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
              source_labels = [ "__journal__comm" ];
              target_label = "process";
            }
          ];
        }

        # PostgreSQL authentication journal scrape (security monitoring)
        # postgresql.service logs to the journal (StandardOutput=journal,
        # StandardError=inherit), but its stderr lines carry NO sd-daemon
        # "<N>" priority prefix, so even FATAL auth failures land at the unit
        # default priority 6 (info). The consolidated systemd-journal scrape
        # above DROPS priority 5-7, so postgres auth events never reach Loki
        # (verified 2026-06-10: 0 postgres lines at priority <=4 in the journal,
        # 0 {job="postgresql"} streams in Loki). This dedicated scrape ingests
        # the SAME journal but KEEPS ONLY postgresql.service (relabel
        # action=keep) and has NO priority-drop stage, so auth events reach Loki
        # under job="postgresql". Mirrors the job="sshd" scrape exactly.
        {
          job_name = "postgresql";
          journal = {
            json = true;
            max_age = "5m"; # Match the main journal scrape window
            labels = {
              job = "postgresql";
              host = "vulcan";
            };
          };
          relabel_configs = [
            # Keep ONLY postgresql.service lines so nothing else is duplicated
            # into Loki by this journal reader.
            {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "postgresql\\.service";
              action = "keep";
            }
            # Carry over the same descriptive labels as the main scrape
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
              source_labels = [ "__journal__comm" ];
              target_label = "process";
            }
          ];
        }

        # Agent microVM egress journal scrape (security monitoring)
        # The openclaw/hermes microVM firewall modules emit netfilter LOG lines
        # ("openclaw-egress: ..." on every NEW outbound conn, and
        # "hermes-egress-rejected: ..." when Hermes tries to leave its 443/53
        # allowlist). Those LOG lines come from the kernel at --log-level info
        # (priority 6), which the consolidated systemd-journal scrape above
        # DROPS (priority 5-7), so the egress audit log NEVER reaches Loki
        # (verified 2026-06-10: 163 openclaw-egress lines/24h in the kernel
        # journal, 0 streams in Loki). Same failure mode as the sshd/postgresql
        # priority-drop fixes. This dedicated scrape ingests the SAME journal,
        # KEEPS ONLY kernel-transport lines, and has NO priority-drop stage.
        # Kernel lines carry no _SYSTEMD_UNIT, so we can't relabel-keep on a
        # unit like the sshd block does; instead we keep on __journal__transport
        # == kernel and then drop everything that isn't one of our two egress
        # prefixes in a pipeline match stage (promtail relabel can't match the
        # MESSAGE body). Only the egress_kind label is promoted (no SRC/DST IP
        # becomes a Loki label -> no cardinality blowup, no IP in alert labels).
        {
          job_name = "vm-egress";
          journal = {
            json = true;
            max_age = "5m"; # Match the main journal scrape window
            labels = {
              job = "vm-egress";
              host = "vulcan";
            };
          };
          relabel_configs = [
            # Keep ONLY kernel-transport lines (the netfilter LOG target emits
            # via the kernel ring buffer; no unit, syslog identifier "kernel").
            {
              source_labels = [ "__journal__transport" ];
              regex = "kernel";
              action = "keep";
            }
            # Carry over the same descriptive labels as the other scrapes.
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
          ];
          pipeline_stages = [
            # Drop every kernel line that is NOT one of our two egress prefixes
            # (this is the bulk of the kernel ring buffer). promtail relabel
            # cannot match the MESSAGE body, so this prefix filter lives here.
            {
              match = {
                selector = ''{job="vm-egress"} !~ "openclaw-egress:|hermes-egress-rejected:"'';
                action = "drop";
              };
            }
            # Tag the source VM so alerts can label by egress_kind without
            # parsing SRC/DST IPs into Loki labels.
            {
              regex = {
                expression = "(?P<egress_kind>openclaw-egress|hermes-egress-rejected)";
              };
            }
            {
              labels = {
                egress_kind = "";
              };
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

        # PostgreSQL logs — the file-based scrape of /var/log/postgresql/*.log
        # was removed on 2025-10-22 ("promtail: Remove hardcoded job
        # configurations"). Postgres now reaches Loki via the journal-based
        # job_name = "postgresql" scrape defined above.

        # Dovecot mail logs — the file-based scrape of /var/log/dovecot/*.log
        # was removed in the same 2025-10-22 commit and never replaced. Dovecot
        # lines only reach Loki through the consolidated systemd-journal scrape,
        # i.e. priority 0-4 only.

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
                expression = "^(?P<message>.*)$";
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
                expression = "^(?P<message>.*)$";
              };
            }
          ];
        }
        {
          job_name = "mbsync-bia";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "mbsync";
                host = "vulcan";
                user = "bia";
                __path__ = "/var/log/mbsync-bia/*.log";
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
                expression = "^(?P<message>.*)$";
              };
            }
          ];
        }
        {
          job_name = "mbsync-rbcca";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "mbsync";
                host = "vulcan";
                user = "rbcca";
                __path__ = "/var/log/mbsync-rbcca/*.log";
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
                expression = "^(?P<message>.*)$";
              };
            }
          ];
        }

        # Audit logs — the dedicated /var/log/audit/audit.log scrape (which had
        # its own rate limiter) was removed on 2025-10-22 along with the other
        # hardcoded jobs. Audit lines are NOT shipped to Loki at all today: the
        # consolidated journal scrape above explicitly drops
        # syslog_identifier="audit" (100+ logs/sec).

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

        # Gitea logs
        {
          job_name = "gitea";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "gitea";
                host = "vulcan";
                __path__ = "/var/lib/gitea/log/gitea.log";
              };
            }
          ];
        }

        # Fetchmail logs
        {
          job_name = "fetchmail";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "fetchmail";
                host = "vulcan";
                __path__ = "/var/log/fetchmail-*/fetchmail.log";
              };
            }
          ];
        }

        # Nagios monitoring logs
        {
          job_name = "nagios";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "nagios";
                host = "vulcan";
                __path__ = "/var/log/nagios/nagios.log";
              };
            }
          ];
        }

        # ZFS replication logs
        {
          job_name = "zfs-replication";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "zfs-replication";
                host = "vulcan";
                __path__ = "/var/log/zfs-replication*.log";
              };
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
      "podman" # For Podman/Docker socket access
      "jellyfin" # For Jellyfin logs
      "gitea" # For Gitea logs
      "wheel" # For audit logs
      "adm" # For sudo logs
    ];
  };

  # Create necessary directories
  systemd.tmpfiles.rules = [
    "d /var/lib/promtail 0755 promtail promtail -"
    "f /var/lib/promtail/positions.yaml 0644 promtail promtail -"
  ];

  # Ensure Promtail starts after Loki
  systemd.services.promtail = {
    after = [
      "loki.service"
      "network-online.target"
    ];
    wants = [
      "loki.service"
      "network-online.target"
    ];

    # Restart on failure with delay
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";

      # Resource limits to prevent runaway usage
      # After consolidation, Promtail should use ~100-150MB (was 250MB with redundant scrapers)
      MemoryMax = "512M"; # Hard limit - kill if exceeded
      MemoryHigh = "384M"; # Start throttling at 384MB
      CPUQuota = "50%"; # Limit to 50% of one core
      TasksMax = 256; # Limit number of threads/goroutines
    };
  };

  # Nginx reverse proxy configuration for Promtail web UI
  services.nginx.virtualHosts."promtail.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/promtail.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/promtail.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.promtail.configuration.server.http_listen_port}";
      recommendedProxySettings = true;
    };
  };

  # Prometheus scrape configuration for Promtail metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "promtail";
      static_configs = [
        {
          targets = [
            "localhost:${toString config.services.promtail.configuration.server.http_listen_port}"
          ];
        }
      ];
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
