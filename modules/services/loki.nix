{ config, lib, pkgs, ... }:

{
  # Loki log aggregation service - Minimal monolithic configuration
  services.loki = {
    enable = true;

    # Minimal configuration based on official loki-local-config.yaml
    configuration = {
      # Authentication disabled for local-only access
      auth_enabled = false;

      # Server configuration
      server = {
        http_listen_port = 3100;
        grpc_listen_port = 9096;
        log_level = "info";
        grpc_server_max_concurrent_streams = 1000;
      };

      # Common configuration - minimal for single-instance
      common = {
        instance_addr = "127.0.0.1";
        path_prefix = "/var/lib/loki";
        storage = {
          filesystem = {
            chunks_directory = "/var/lib/loki/chunks";
            rules_directory = "/var/lib/loki/rules";
          };
        };
        replication_factor = 1;
        ring = {
          kvstore = {
            store = "inmemory";
          };
        };
      };

      # Schema configuration - using TSDB (required for Loki 3.x)
      schema_config = {
        configs = [
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
      };

      # Query range configuration with cache
      query_range = {
        results_cache = {
          cache = {
            embedded_cache = {
              enabled = true;
              max_size_mb = 100;
            };
          };
        };
      };

      # Limits configuration - keep essential limits
      limits_config = {
        reject_old_samples = true;
        reject_old_samples_max_age = "168h"; # 7 days
        ingestion_rate_mb = 10;
        ingestion_burst_size_mb = 20;
        split_queries_by_interval = "24h"; # Important for preventing timeouts
        retention_period = "720h"; # 30 days
        max_streams_per_user = 10000;
        max_global_streams_per_user = 10000;
        volume_enabled = true;  # Enable volume API for Grafana Logs section
      };

      # Compactor configuration for managing retention
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        retention_delete_worker_count = 150;
        delete_request_store = "filesystem";
      };

      # Ruler configuration for recording rules and alerts (optional)
      ruler = {
        alertmanager_url = "http://localhost:${toString config.services.prometheus.alertmanager.port}";
      };

      # Frontend configuration with encoding
      frontend = {
        encoding = "protobuf";
      };
    };
  };

  # Ensure Loki data directory has proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0755 loki loki -"
    "d /var/lib/loki/chunks 0755 loki loki -"
    "d /var/lib/loki/rules 0755 loki loki -"
    "d /var/lib/loki/tsdb-shipper-active 0755 loki loki -"
    "d /var/lib/loki/tsdb-shipper-cache 0755 loki loki -"
    "d /var/lib/loki/compactor 0755 loki loki -"
    "d /tmp/loki 0755 loki loki -"
    "d /tmp/loki/rules 0755 loki loki -"

    # Deploy Loki alert rules (fake tenant for single-tenant mode)
    "d /var/lib/loki/rules/fake 0755 loki loki -"
    "L+ /var/lib/loki/rules/fake/dns-query-exporter.yaml - - - - /etc/nixos/modules/monitoring/loki-rules/dns-query-exporter.yaml"
  ];

  # Nginx reverse proxy configuration for Loki (optional external access)
  services.nginx.virtualHosts."loki.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/loki.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/loki.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:3100/";
      proxyWebsockets = true;

      extraConfig = ''
        # Authentication can be added here if needed
        # auth_basic "Loki Access";
        # auth_basic_user_file /etc/nginx/loki.htpasswd;

        # Increase timeouts for Loki
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        # Increase buffer sizes for large log queries
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
      '';
    };
  };

  # Prometheus scrape configuration for Loki metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "loki";
      static_configs = [{
        targets = [ "localhost:${toString config.services.loki.configuration.server.http_listen_port}" ];
      }];
      scrape_interval = "15s";
    }
  ];

  # Monitoring and health check script
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-loki" ''
      echo "=== Loki Service Status ==="
      systemctl is-active loki && echo "Service: Active" || echo "Service: Inactive"

      echo ""
      echo "=== Loki API Health ==="
      ${pkgs.curl}/bin/curl -s http://localhost:3100/ready | ${pkgs.jq}/bin/jq . || echo "API not responding"

      echo ""
      echo "=== Loki Metrics ==="
      ${pkgs.curl}/bin/curl -s http://localhost:3100/metrics | head -20

      echo ""
      echo "=== Storage Usage ==="
      du -sh /var/lib/loki/* 2>/dev/null | head -10

      echo ""
      echo "=== Recent Logs ==="
      journalctl -u loki -n 10 --no-pager
    '')

    # LogCLI tool for querying Loki from command line
    (writeShellScriptBin "logcli-local" ''
      ${pkgs.grafana-loki}/bin/logcli \
        --addr="http://localhost:3100" \
        "$@"
    '')
  ];

  # Ensure Loki starts after network is available
  systemd.services.loki = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}