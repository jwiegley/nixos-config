{ config, lib, pkgs, ... }:

let
  # Alert rules directory
  alertRulesDir = ../monitoring/alerts;

  # Load all alert rules from YAML files
  alertRuleFiles = builtins.map (file: "${alertRulesDir}/${file}") [
    "system.yaml"
    "systemd.yaml"
    "database.yaml"
    "storage.yaml"
    "certificates.yaml"
    "chainweb.yaml"
    "network.yaml"
  ];
in
{
  # Phase 1: Basic monitoring foundation with node_exporter

  services = {
    # Prometheus node exporter for system metrics
    prometheus.exporters = {
      node = {
        enable = true;
        port = 9100;

        # Enable additional collectors
        enabledCollectors = [
          "systemd"
          "processes"
          "logind"
          "textfile"
        ];

        # Disable collectors that might have security implications
        disabledCollectors = [
          "wifi"
        ];

        extraFlags = [
          "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker)($|/)"
          "--collector.netclass.ignored-devices=^(lo|podman[0-9]|br-|veth).*"
          "--collector.textfile.directory=/var/lib/prometheus-node-exporter-textfiles"
        ];
      };

      # PostgreSQL exporter
      postgres = {
        enable = true;
        port = 9187;
        runAsLocalSuperUser = true;
      };

      # Systemd exporter for service status
      systemd = {
        enable = true;
        port = 9558;
      };

      # Postfix exporter
      postfix = {
        enable = true;
        port = 9154;
        # Postfix log file path - adjust if different
        logfilePath = "/var/log/postfix.log";
      };

      # ZFS exporter
      zfs = {
        enable = true;
        port = 9134;
        # Monitor all pools (default behavior when pools is not specified)
      };

      # Restic exporter - DISABLED in favor of textfile collector approach
      # The textfile collector supports multiple repositories via a custom script
      # See the restic-metrics systemd service below
    };

    # Basic Prometheus server (Phase 1 - local monitoring only)
    prometheus = {
      enable = true;
      port = 9090;

      # Only listen on localhost for now
      listenAddress = "127.0.0.1";

      # Enable admin API for administrative operations
      extraFlags = [
        "--web.enable-admin-api"
      ];

      # Global configuration
      globalConfig = {
        scrape_interval = "15s";
        evaluation_interval = "15s";
        external_labels = {
          monitor = "vulcan";
          environment = "production";
        };
      };

      # Load alert rules from external YAML files
      ruleFiles = alertRuleFiles ++ (lib.optional
        (builtins.pathExists ../monitoring/alerts/custom.yaml)
        ../monitoring/alerts/custom.yaml
      );

      # Scrape configurations
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ];
            labels = {
              alias = "vulcan";
            };
          }];
        }
        {
          job_name = "postgres";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.postgres.port}" ];
          }];
        }
        {
          job_name = "systemd";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.systemd.port}" ];
          }];
        }
        {
          job_name = "postfix";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.postfix.port}" ];
          }];
        }
        {
          job_name = "zfs";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.zfs.port}" ];
          }];
        }
        {
          job_name = "dovecot";
          static_configs = [{
            targets = [ "localhost:${toString config.services.prometheus.exporters.dovecot.port}" ];
          }];
        }
        # Blackbox exporter scrape configurations
      ] ++ (lib.optionals config.services.prometheus.exporters.blackbox.enable [
        # ICMP monitoring for all configured hosts
        {
          job_name = "blackbox_icmp";
          metrics_path = "/probe";
          params = {
            module = [ "icmp_ping" ];
          };
          static_configs = [{
            targets = [
              "vulcan.lan"                        # 192.168.1.2
              "hera.lan"                          # 192.168.1.4
              "clio.lan"                          # 192.168.1.5

              # "adt-home-security.lan"             # 192.168.3.118
              "asus-bq16-pro-ap.lan"              # 192.168.3.2
              "asus-bq16-pro-node.lan"            # 192.168.3.3
              "asus-rt-ax88u.lan"                 # 192.168.3.8
              # "august-lock-front-door.lan"        # 192.168.3.12
              # "august-lock-garage-door.lan"       # 192.168.3.14
              # "august-lock-side-door.lan"         # 192.168.3.173
              "b-hyve-sprinkler.lan"              # 192.168.3.89
              "dreamebot-vacuum.lan"              # 192.168.3.195
              "enphase-solar-inverter.lan"        # 192.168.3.26
              "flume-water-meter.lan"             # 192.168.3.183
              "google-home-hub.lan"               # 192.168.3.106
              "hera-wifi.lan"                     # 192.168.3.6
              "hubspace-porch-light.lan"          # 192.168.3.178
              "miele-dishwasher.lan"              # 192.168.3.98
              "myq-garage-door.lan"               # 192.168.3.99
              # "nest-downstairs.lan"               # 192.168.3.57
              # "nest-family-room.lan"              # 192.168.3.83
              # "nest-upstairs.lan"                 # 192.168.3.161
              "pentair-intellicenter.lan"         # 192.168.3.115
              "pentair-intelliflo.lan"            # 192.168.3.23
              "ring-chime-kitchen.lan"            # 192.168.3.163
              "ring-chime-office.lan"             # 192.168.3.88
              # "ring-doorbell.lan"                 # 192.168.3.185
              "tesla-wall-connector.lan"          # 192.168.3.119
              # "traeger-grill.lan"                 # 192.168.3.196

              "athena.lan"                        # 192.168.20.2

              "TL-WPA8630.lan"                    # 192.168.30.49

              "9.9.9.9"
              "149.112.112.112"
              "1.1.1.1"
              "1.0.0.1"
              "208.67.222.222"
              "208.67.220.220"

              "google.com"
              "cloudflare.com"
              "amazon.com"
              "github.com"

              "web.mit.edu"
              "www.berkeley.edu"
              "ucsd.edu"
              "twin-cities.umn.edu"
              "osuosl.org"
            ];
          }];
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
            }
            # Add host group labels based on target
            {
              source_labels = [ "__param_target" ];
              target_label = "host_group";
              regex = "(192\\.168\\..*)|(127\\.0\\.0\\.1)|(localhost)";
              replacement = "local";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "host_group";
              regex = "(8\\.8\\.[48]\\.[48])|(1\\.[01]\\.0\\.[01])|(208\\.67\\.222\\.222)";
              replacement = "dns";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "host_group";
              regex = ".+\\.(com|org|net|edu)";
              replacement = "backbone";
            }
          ];
          scrape_interval = "30s";
          scrape_timeout = "10s";
        }

        # HTTP monitoring for web services
        {
          job_name = "blackbox_http";
          metrics_path = "/probe";
          params = {
            module = [ "http_2xx" ];
          };
          static_configs = [{
            targets = [
              "http://google.com"
              "http://github.com"
              "http://cloudflare.com"
            ];
          }];
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
            }
            {
              target_label = "probe_type";
              replacement = "http";
            }
          ];
          scrape_interval = "60s";
          scrape_timeout = "15s";
        }

        # HTTPS monitoring for public web services
        {
          job_name = "blackbox_https";
          metrics_path = "/probe";
          params = {
            module = [ "https_2xx" ];
          };
          static_configs = [{
            targets = [
              "https://google.com"
              "https://github.com"
              "https://cloudflare.com"
              "https://prometheus.io"
              "https://grafana.com"
            ];
          }];
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
            }
            {
              target_label = "probe_type";
              replacement = "https";
            }
          ];
          scrape_interval = "60s";
          scrape_timeout = "15s";
        }

        # HTTPS monitoring for local services with step-ca certificates
        {
          job_name = "blackbox_https_local";
          metrics_path = "/probe";
          params = {
            module = [ "https_2xx_local" ];
          };
          static_configs = [{
            targets = [
              "https://homepage.vulcan.lan"
              "https://glance.vulcan.lan"
              "https://grafana.vulcan.lan"
              "https://jellyfin.vulcan.lan"
              "https://litellm.vulcan.lan"
              "https://postgres.vulcan.lan"
              "https://prometheus.vulcan.lan"
              "https://silly-tavern.vulcan.lan"
              "https://wallabag.vulcan.lan"
              "https://dns.vulcan.lan"
            ];
          }];
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
            }
            {
              target_label = "probe_type";
              replacement = "https_local";
            }
          ];
          scrape_interval = "60s";
          scrape_timeout = "15s";
        }

        # DNS query monitoring
        {
          job_name = "blackbox_dns";
          metrics_path = "/probe";
          params = {
            module = [ "dns_query" ];
          };
          static_configs = [{
            targets = [
              "192.168.1.1"
              "192.168.1.2"
              "9.9.9.9"
              "149.112.112.112"
              "1.1.1.1"
              "1.0.0.1"
              "208.67.222.222"
              "208.67.220.220"
            ];
          }];
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
            }
            {
              target_label = "probe_type";
              replacement = "dns";
            }
          ];
          scrape_interval = "60s";
          scrape_timeout = "10s";
        }
      ])

      # Dynamically generate scrape configs for all chainweb nodes
      ++ (lib.mapAttrsToList (name: nodeCfg: {
        job_name = "chainweb_${name}";
        static_configs = [{
          targets = [ "localhost:${toString nodeCfg.port}" ];
          labels = {
            node = name;
            blockchain = "kadena";
            instance = name;
          };
        }];
        scrape_interval = "30s";  # Scrape more frequently for blockchain metrics
      }) (config.services.chainweb-exporters.nodes or {}));

      # Alertmanager configuration
      alertmanagers = lib.mkIf (config.services.prometheus.alertmanager.enable or false) [
        {
          static_configs = [{
            targets = [ "localhost:9093" ];
          }];
        }
      ];
    };
  };

  # Open firewall for Prometheus exporters (only localhost access for now)
  networking.firewall = {
    interfaces."lo" = {
      allowedTCPPorts = [
        config.services.prometheus.exporters.node.port
        config.services.prometheus.exporters.postgres.port
        config.services.prometheus.exporters.systemd.port
        config.services.prometheus.exporters.postfix.port
        config.services.prometheus.exporters.zfs.port
        config.services.prometheus.port
      ] ++ lib.optionals config.services.prometheus.exporters.blackbox.enable [
        config.services.prometheus.exporters.blackbox.port
      ];
    };
  };

  # Create a script to check monitoring health
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-monitoring" ''
      echo "=== Node Exporter Status ==="
      curl -s localhost:9100/metrics | head -5
      echo ""
      echo "=== Prometheus Targets ==="
      curl -s localhost:9090/api/v1/targets | ${pkgs.jq}/bin/jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
      echo ""
      echo "=== Active Alerts ==="
      curl -s localhost:9090/api/v1/alerts | ${pkgs.jq}/bin/jq '.data.alerts[] | {alertname: .labels.alertname, state: .state}'
      echo ""
      if systemctl is-active prometheus-blackbox-exporter >/dev/null 2>&1; then
        echo "=== Blackbox Exporter Status ==="
        echo "Service: Active"
        echo "Sample ICMP test (8.8.8.8):"
        timeout 5 curl -s 'http://localhost:9115/probe?module=icmp_ping&target=8.8.8.8' | \
          grep -E '(probe_success|probe_duration_seconds)' | head -2
      else
        echo "=== Blackbox Exporter Status ==="
        echo "Service: Inactive"
      fi
    '')

    (writeShellScriptBin "reload-prometheus" ''
      echo "Reloading Prometheus configuration..."
      ${pkgs.systemd}/bin/systemctl reload prometheus
      echo "Prometheus configuration reloaded"
    '')

    (writeShellScriptBin "validate-alerts" ''
      echo "Validating Prometheus alert rules..."
      for file in ${toString alertRuleFiles}; do
        echo "Checking $file..."
        ${pkgs.prometheus}/bin/promtool check rules "$file" || exit 1
      done
      echo "All alert rules are valid"
    '')

    (writeShellScriptBin "collect-restic-metrics" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Output file for Prometheus textfile collector
      OUTPUT_FILE="/var/lib/prometheus-node-exporter-textfiles/restic.prom"
      TEMP_FILE="$OUTPUT_FILE.$$"

      # Base S3 repository URL
      S3_BASE="s3:s3.us-west-001.backblazeb2.com"

      # List of repositories to monitor (matching backup names)
      REPOSITORIES=(
        "Audio"
        "Backups"
        "Databases"
        "Home"
        "Nasim"
        "Photos"
        "Video"
        "doc"
        "src"
      )

      # Source AWS credentials
      if [ -f /run/secrets/aws-keys ]; then
        source /run/secrets/aws-keys
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
      fi

      # Source restic password
      if [ -f /run/secrets/restic-password ]; then
        export RESTIC_PASSWORD=$(cat /run/secrets/restic-password)
      fi

      # Start writing metrics
      cat > "$TEMP_FILE" <<'HEADER'
      # HELP restic_check_success Whether the last restic check was successful (1 = success, 0 = failure)
      # TYPE restic_check_success gauge
      # HELP restic_snapshots_total Total number of snapshots in the repository
      # TYPE restic_snapshots_total gauge
      # HELP restic_repo_size_bytes Total size of the repository (raw data) in bytes
      # TYPE restic_repo_size_bytes gauge
      # HELP restic_repo_files_total Total number of files in the repository
      # TYPE restic_repo_files_total gauge
      # HELP restic_restore_size_bytes Total size of files if restored
      # TYPE restic_restore_size_bytes gauge
      # HELP restic_unique_files_total Total number of unique files (by contents)
      # TYPE restic_unique_files_total gauge
      # HELP restic_unique_size_bytes Total size of unique file contents
      # TYPE restic_unique_size_bytes gauge
      # HELP restic_last_snapshot_timestamp_seconds Timestamp of the most recent snapshot
      # TYPE restic_last_snapshot_timestamp_seconds gauge
      # HELP restic_last_check_timestamp_seconds Timestamp of the last check operation
      # TYPE restic_last_check_timestamp_seconds gauge
      # HELP restic_scrape_duration_seconds Time taken to collect metrics for this repository
      # TYPE restic_scrape_duration_seconds gauge
      HEADER

      # Check each repository
      for repo in "''${REPOSITORIES[@]}"; do
        START_TIME=$(date +%s)
        echo "Checking repository: $repo" >&2

        # Map repository name to bucket name (Backups uses Backups-Misc)
        case "$repo" in
          "Backups")
            BUCKET="Backups-Misc"
            ;;
          *)
            BUCKET="$repo"
            ;;
        esac

        REPO_URL="$S3_BASE/jwiegley-$BUCKET"
        CHECK_SUCCESS=0
        SNAPSHOT_COUNT=0
        REPO_SIZE=0
        REPO_FILES=0
        RESTORE_SIZE=0
        UNIQUE_FILES=0
        UNIQUE_SIZE=0
        LAST_SNAPSHOT_TIME=0
        TIMESTAMP=$(date +%s)

        # Try to collect comprehensive stats
        if SNAPSHOTS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" snapshots --json 2>/dev/null); then
          # Check if we got valid JSON
          if echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq -e . >/dev/null 2>&1; then
            CHECK_SUCCESS=1

            # Count snapshots
            SNAPSHOT_COUNT=$(echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq 'length // 0')

            # Get latest snapshot timestamp
            if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
              # Get the latest timestamp string and convert to epoch using date command
              LATEST_TIME_STR=$(echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq -r 'map(.time) | sort | last // empty')
              if [ -n "$LATEST_TIME_STR" ]; then
                LAST_SNAPSHOT_TIME=$(${pkgs.coreutils}/bin/date -d "$LATEST_TIME_STR" +%s 2>/dev/null || echo "0")
              fi
            fi

            # Get raw data stats (total repository size)
            if RAW_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode raw-data --json 2>/dev/null); then
              REPO_SIZE=$(echo "$RAW_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
              REPO_FILES=$(echo "$RAW_STATS" | ${pkgs.jq}/bin/jq -r '.total_file_count // 0')
            fi

            # Get restore size stats (size if all files were restored)
            if RESTORE_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode restore-size --json 2>/dev/null); then
              RESTORE_SIZE=$(echo "$RESTORE_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
            fi

            # Get unique files stats (deduplication info)
            if UNIQUE_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode files-by-contents --json 2>/dev/null); then
              UNIQUE_FILES=$(echo "$UNIQUE_STATS" | ${pkgs.jq}/bin/jq -r '.total_file_count // 0')
              UNIQUE_SIZE=$(echo "$UNIQUE_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
            fi
          else
            echo "Failed to parse snapshots JSON for repository: $repo" >&2
          fi
        else
          echo "Failed to list snapshots for repository: $repo" >&2
        fi

        # Calculate scrape duration
        END_TIME=$(date +%s)
        SCRAPE_DURATION=$((END_TIME - START_TIME))

        # Write all metrics for this repository
        cat >> "$TEMP_FILE" <<EOF
      restic_check_success{repository="$repo"} $CHECK_SUCCESS
      restic_snapshots_total{repository="$repo"} $SNAPSHOT_COUNT
      restic_repo_size_bytes{repository="$repo"} $REPO_SIZE
      restic_repo_files_total{repository="$repo"} $REPO_FILES
      restic_restore_size_bytes{repository="$repo"} $RESTORE_SIZE
      restic_unique_files_total{repository="$repo"} $UNIQUE_FILES
      restic_unique_size_bytes{repository="$repo"} $UNIQUE_SIZE
      restic_last_snapshot_timestamp_seconds{repository="$repo"} $LAST_SNAPSHOT_TIME
      restic_last_check_timestamp_seconds{repository="$repo"} $TIMESTAMP
      restic_scrape_duration_seconds{repository="$repo"} $SCRAPE_DURATION
      EOF
      done

      # Atomically move the temp file to the output file
      mv "$TEMP_FILE" "$OUTPUT_FILE"
      chmod 644 "$OUTPUT_FILE"

      echo "Restic metrics collection complete" >&2
    '')
  ];

  # Fix exporter startup issues - ensure they start after network is ready
  systemd.services = {
    "prometheus-node-exporter" = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    "prometheus-postgres-exporter" = {
      wants = [ "network-online.target" "postgresql.service" ];
      after = [ "network-online.target" "postgresql.service" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    "prometheus-systemd-exporter" = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    "prometheus-postfix-exporter" = {
      wants = [ "network-online.target" "postfix.service" ];
      after = [ "network-online.target" "postfix.service" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    "prometheus-zfs-exporter" = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "zfs.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };
  };

  # Restic metrics collection for multiple repositories
  # Create directory for textfile collector
  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus-node-exporter-textfiles 0755 root root -"
  ];

  # Systemd service to collect restic metrics
  systemd.services.restic-metrics = {
    description = "Collect Restic Repository Metrics";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.writeShellScript "collect-restic-metrics-inline" ''
        #!/usr/bin/env bash
        set -euo pipefail

        OUTPUT_FILE="/var/lib/prometheus-node-exporter-textfiles/restic.prom"
        TEMP_FILE="$OUTPUT_FILE.$$"
        S3_BASE="s3:s3.us-west-001.backblazeb2.com"

        REPOSITORIES=(
          "Audio"
          "Backups"
          "Databases"
          "Home"
          "Nasim"
          "Photos"
          "Video"
          "doc"
          "src"
        )

        if [ -f /run/secrets/aws-keys ]; then
          source /run/secrets/aws-keys
          export AWS_ACCESS_KEY_ID
          export AWS_SECRET_ACCESS_KEY
        fi

        if [ -f /run/secrets/restic-password ]; then
          export RESTIC_PASSWORD=$(cat /run/secrets/restic-password)
        fi

        cat > "$TEMP_FILE" <<'HEADER'
# HELP restic_check_success Whether the last restic check was successful (1 = success, 0 = failure)
# TYPE restic_check_success gauge
# HELP restic_snapshots_total Total number of snapshots in the repository
# TYPE restic_snapshots_total gauge
# HELP restic_repo_size_bytes Total size of the repository (raw data) in bytes
# TYPE restic_repo_size_bytes gauge
# HELP restic_repo_files_total Total number of files in the repository
# TYPE restic_repo_files_total gauge
# HELP restic_restore_size_bytes Total size of files if restored
# TYPE restic_restore_size_bytes gauge
# HELP restic_unique_files_total Total number of unique files (by contents)
# TYPE restic_unique_files_total gauge
# HELP restic_unique_size_bytes Total size of unique file contents
# TYPE restic_unique_size_bytes gauge
# HELP restic_last_snapshot_timestamp_seconds Timestamp of the most recent snapshot
# TYPE restic_last_snapshot_timestamp_seconds gauge
# HELP restic_last_check_timestamp_seconds Timestamp of the last check operation
# TYPE restic_last_check_timestamp_seconds gauge
# HELP restic_scrape_duration_seconds Time taken to collect metrics for this repository
# TYPE restic_scrape_duration_seconds gauge
HEADER

        for repo in "''${REPOSITORIES[@]}"; do
          START_TIME=$(date +%s)
          echo "Checking repository: $repo" >&2

          # Map repository name to bucket name (Backups uses Backups-Misc)
          case "$repo" in
            "Backups")
              BUCKET="Backups-Misc"
              ;;
            *)
              BUCKET="$repo"
              ;;
          esac

          REPO_URL="$S3_BASE/jwiegley-$BUCKET"
          CHECK_SUCCESS=0
          SNAPSHOT_COUNT=0
          REPO_SIZE=0
          REPO_FILES=0
          RESTORE_SIZE=0
          UNIQUE_FILES=0
          UNIQUE_SIZE=0
          LAST_SNAPSHOT_TIME=0
          TIMESTAMP=$(date +%s)

          # Try to collect comprehensive stats
          if SNAPSHOTS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" snapshots --json 2>/dev/null); then
            # Check if we got valid JSON
            if echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq -e . >/dev/null 2>&1; then
              CHECK_SUCCESS=1

              # Count snapshots
              SNAPSHOT_COUNT=$(echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq 'length // 0')

              # Get latest snapshot timestamp
              if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
                # Get the latest timestamp string and convert to epoch using date command
                LATEST_TIME_STR=$(echo "$SNAPSHOTS" | ${pkgs.jq}/bin/jq -r 'map(.time) | sort | last // empty')
                if [ -n "$LATEST_TIME_STR" ]; then
                  LAST_SNAPSHOT_TIME=$(${pkgs.coreutils}/bin/date -d "$LATEST_TIME_STR" +%s 2>/dev/null || echo "0")
                fi
              fi

              # Get raw data stats (total repository size)
              if RAW_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode raw-data --json 2>/dev/null); then
                REPO_SIZE=$(echo "$RAW_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
                REPO_FILES=$(echo "$RAW_STATS" | ${pkgs.jq}/bin/jq -r '.total_file_count // 0')
              fi

              # Get restore size stats (size if all files were restored)
              if RESTORE_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode restore-size --json 2>/dev/null); then
                RESTORE_SIZE=$(echo "$RESTORE_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
              fi

              # Get unique files stats (deduplication info)
              if UNIQUE_STATS=$(${pkgs.restic}/bin/restic -r "$REPO_URL" stats --mode files-by-contents --json 2>/dev/null); then
                UNIQUE_FILES=$(echo "$UNIQUE_STATS" | ${pkgs.jq}/bin/jq -r '.total_file_count // 0')
                UNIQUE_SIZE=$(echo "$UNIQUE_STATS" | ${pkgs.jq}/bin/jq -r '.total_size // 0')
              fi
            else
              echo "Failed to parse snapshots JSON for repository: $repo" >&2
            fi
          else
            echo "Failed to list snapshots for repository: $repo" >&2
          fi

          # Calculate scrape duration
          END_TIME=$(date +%s)
          SCRAPE_DURATION=$((END_TIME - START_TIME))

          # Write all metrics for this repository
          cat >> "$TEMP_FILE" <<EOF
restic_check_success{repository="$repo"} $CHECK_SUCCESS
restic_snapshots_total{repository="$repo"} $SNAPSHOT_COUNT
restic_repo_size_bytes{repository="$repo"} $REPO_SIZE
restic_repo_files_total{repository="$repo"} $REPO_FILES
restic_restore_size_bytes{repository="$repo"} $RESTORE_SIZE
restic_unique_files_total{repository="$repo"} $UNIQUE_FILES
restic_unique_size_bytes{repository="$repo"} $UNIQUE_SIZE
restic_last_snapshot_timestamp_seconds{repository="$repo"} $LAST_SNAPSHOT_TIME
restic_last_check_timestamp_seconds{repository="$repo"} $TIMESTAMP
restic_scrape_duration_seconds{repository="$repo"} $SCRAPE_DURATION
EOF
        done

        mv "$TEMP_FILE" "$OUTPUT_FILE"
        chmod 644 "$OUTPUT_FILE"
        echo "Restic metrics collection complete" >&2
      ''}'";
      User = "root";
      Group = "root";
      # Increase timeout since checking multiple repositories can take time
      TimeoutSec = "30m";
    };
  };

  # Systemd timer to periodically collect restic metrics
  systemd.timers.restic-metrics = {
    description = "Timer for Restic Repository Metrics Collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";       # Run 5 minutes after boot
      OnUnitActiveSec = "6h";   # Run every 6 hours
      Persistent = true;        # Run missed timers on boot
    };
  };

  # Documentation
  environment.etc."prometheus/README.md" = {
    text = ''
      # Prometheus Monitoring Configuration

      ## Alert Rules
      Alert rules are stored in `/etc/nixos/modules/monitoring/alerts/`:
      - system.yaml: System-level alerts (CPU, memory, disk)
      - systemd.yaml: Systemd service health and state alerts
      - database.yaml: Database-specific alerts
      - storage.yaml: Storage and backup alerts
      - certificates.yaml: Certificate expiration alerts
      - custom.yaml: Custom site-specific alerts (optional)

      ## Useful Commands
      - `check-monitoring`: Check status of monitoring stack
      - `validate-alerts`: Validate alert rule syntax
      - `reload-prometheus`: Reload Prometheus configuration

      ## Adding Custom Alerts
      Create `/etc/nixos/modules/monitoring/alerts/custom.yaml` with your custom rules.
      The file will be automatically loaded if it exists.

      ## Metrics Endpoints
      - Prometheus: http://localhost:9090
      - Node Exporter: http://localhost:9100/metrics
        - Includes textfile collector for custom metrics (restic, etc.)
      - PostgreSQL Exporter: http://localhost:9187/metrics
      - Systemd Exporter: http://localhost:9558/metrics
      - Dovecot Exporter: http://localhost:9166/metrics
      - Postfix Exporter: http://localhost:9154/metrics
      - ZFS Exporter: http://localhost:9134/metrics
      - Blackbox Exporter: http://localhost:9115/metrics
      - Chainweb: http://localhost:9101/metrics

      ## Restic Monitoring
      Restic metrics are collected via textfile collector for all repositories:
      Audio, Backups, Databases, Home, Nasim, Photos, Video, doc, src

      Metrics are updated every 6 hours via systemd timer.
      To manually refresh: systemctl start restic-metrics.service
    '';
    mode = "0644";
  };

  # Nginx reverse proxy configuration for Prometheus UI
  services.nginx.virtualHosts."prometheus.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/prometheus.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/prometheus.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
      recommendedProxySettings = true;
    };
  };
}
