{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Prefetched Grafana community dashboards (reproducible, available offline)
  grafanaDashboards = {
    "node-exporter-full.json" = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/1860/revisions/latest/download";
      sha256 = "0yjcsqm9js676s299ccnpgpsrr0n82w58p18281wkdb14vc3pr11";
      name = "node-exporter-full.json";
    };
    "node-exporter-11074.json" = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/11074/revisions/latest/download";
      sha256 = "0r8hpmxxzn6nsbg2i3q79pnidxcdgga9v65dxfbhfglvxqll0gw9";
      name = "node-exporter-11074.json";
    };
    "postgresql.json" = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/9628/revisions/latest/download";
      sha256 = "1iwwqglszdl3wmsl86z9fjd8wlp019aq9hsz4pgxxjjv0qsaq6sj";
      name = "postgresql.json";
    };
    "loki-promtail.json" = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/10880/revisions/latest/download";
      sha256 = "0rknq2ax0j9r6gk5bf4p1xxbs0r4vjwdi74gn6nvfa1g0qxs8126";
      name = "loki-promtail.json";
    };
    "logs-app.json" = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/13639/revisions/latest/download";
      sha256 = "101lai075g45sspbnik2drdqinzmgv1yfq6888s520q8ia959m6r";
      name = "logs-app.json";
    };
    "immich.json" = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/22555/revisions/latest/download";
      sha256 = "1yl967jmjgf4a2vrmxr83iaa9pllcd0r2cxhqby6qxlggy6dqvwj";
      name = "immich.json";
    };
    "qdrant.json" = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/24074/revisions/latest/download";
      sha256 = "0skw1vzi5cmq74w7qq6zkarcrpdxxjki33agjhqvhi4pq2gnmg0p";
      name = "qdrant.json";
    };
  };

  # Local dashboards from the NixOS config repo
  localDashboards = {
    "dns-query-logs.json" = ../../modules/storage/dns-query-logs-dashboard.json;
    "home-assistant.json" = ../monitoring/dashboards/home-assistant.json;
    "systemd-services-enhanced.json" = ../monitoring/dashboards/systemd-services-enhanced.json;
    "mac-studio-power.json" = ../monitoring/dashboards/mac-studio-power.json;
    "copyparty.json" = ../monitoring/dashboards/copyparty.json;
    "atd-dashboard.json" = ../monitoring/grafana-dashboards/atd-dashboard.json;
  };

  # Combined derivation containing all dashboards
  dashboardDir = pkgs.runCommand "grafana-dashboards" { } ''
    mkdir -p $out
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: src: "cp ${src} $out/${name}") grafanaDashboards
    )}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: src: "cp ${src} $out/${name}") localDashboards
    )}
  '';
in
{
  # Grafana visualization server for Prometheus metrics
  services.grafana = {
    enable = true;

    # Bind only to localhost - nginx will proxy
    settings = {
      server = {
        # Only listen on localhost
        http_addr = "127.0.0.1";
        http_port = 3000;

        # Configure for reverse proxy
        domain = "grafana.vulcan.lan";
        root_url = "https://grafana.vulcan.lan";
        serve_from_sub_path = false;

        # Security headers
        enable_gzip = true;
      };

      # Security settings
      security = {
        # Disable signups
        disable_gravatar = true;
        allow_embedding = false;
        cookie_secure = true;
        cookie_samesite = "strict";
        strict_transport_security = true;
        strict_transport_security_max_age_seconds = 31536000;
        strict_transport_security_preload = true;
        content_security_policy = true;
      };

      # Anonymous access for read-only viewing (optional)
      "auth.anonymous" = {
        enabled = false; # Set to true if you want read-only public access
        org_name = "Main Org.";
        org_role = "Viewer";
      };

      # Database settings (uses local SQLite by default)
      database = {
        type = "sqlite3";
        path = "/var/lib/grafana/data/grafana.db";
      };

      # Analytics and telemetry
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
    };

    # Automatic provisioning of data sources
    provision = {
      enable = true;

      datasources.settings = {
        apiVersion = 1;

        # Configure Prometheus as default data source
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            uid = "prometheus"; # Fixed UID for dashboard references
            access = "proxy";
            url = "http://localhost:${toString config.services.prometheus.port}";
            isDefault = true;
            editable = false;
            jsonData = {
              timeInterval = "15s";
              queryTimeout = "60s";
              httpMethod = "POST";
            };
          }
          {
            name = "VictoriaMetrics";
            type = "prometheus";
            uid = "victoriametrics"; # Fixed UID for VictoriaMetrics datasource
            access = "proxy";
            url = "http://localhost:8428";
            isDefault = false;
            editable = false;
            jsonData = {
              timeInterval = "60s";
              queryTimeout = "300s";
              httpMethod = "POST";
              # VictoriaMetrics-specific optimizations
              customQueryParameters = "";
            };
          }
          {
            name = "Loki";
            type = "loki";
            uid = "loki"; # Fixed UID for Loki datasource
            access = "proxy";
            url = "http://localhost:3100";
            isDefault = false;
            editable = false;
            jsonData = {
              maxLines = 1000;
              derivedFields = [
                {
                  # Link from trace ID in logs to tempo traces (if using tempo)
                  matcherRegex = "traceID=(\\w+)";
                  name = "TraceID";
                  url = "$${__value.raw}";
                  datasourceUid = "";
                }
              ];
              # Enable correlation with Prometheus metrics
              alertmanager = {
                implementation = "prometheus";
              };
            };
          }
        ];

        # Clean up removed data sources
        deleteDatasources = [ ];
      };

      # Dashboard provisioning
      dashboards.settings = {
        apiVersion = 1;

        providers = [
          {
            name = "default";
            orgId = 1;
            type = "file";
            disableDeletion = false;
            updateIntervalSeconds = 10;
            allowUiUpdates = true;
            options = {
              path = "/var/lib/grafana/dashboards";
            };
          }
        ];
      };
    };
  };

  # Create dashboard directory and populate with JSON dashboards
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana/dashboards 0755 grafana grafana -"
  ];

  # Install dashboards from Nix store (reproducible, available offline)
  # Dashboards are prefetched at build time via pkgs.fetchurl or referenced
  # as local paths, then assembled into a single derivation (dashboardDir).
  systemd.services.grafana-install-dashboards = {
    description = "Install Grafana dashboards from Nix store";
    wantedBy = [ "grafana.service" ];
    before = [ "grafana.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      DASHBOARD_DIR="/var/lib/grafana/dashboards"
      mkdir -p "$DASHBOARD_DIR"

      # Copy all dashboards from the Nix store derivation
      cp -f ${dashboardDir}/*.json "$DASHBOARD_DIR/"

      # Preserve any manually-added dashboards (e.g. technitium-dns.json)
      chown -R grafana:grafana "$DASHBOARD_DIR"
    '';
  };

  # Grafana nginx upstream with retry logic
  # Prevents 502 errors during service restarts
  services.nginx.upstreams."grafana" = {
    servers = {
      "127.0.0.1:3000" = {
        max_fails = 0;
      };
    };
    extraConfig = ''
      keepalive 16;
      keepalive_timeout 60s;
    '';
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."grafana.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/grafana.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/grafana.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://grafana/";
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Increase timeouts for Grafana
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
      '';
    };
  };

  # Certificate generation script service
  systemd.services.grafana-certificate = {
    description = "Generate Grafana TLS certificate";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    after = [ "step-ca.service" ];
    path = [
      pkgs.openssl
      pkgs.step-cli
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      CERT_DIR="/var/lib/nginx-certs"
      mkdir -p "$CERT_DIR"

      CERT_FILE="$CERT_DIR/grafana.vulcan.lan.crt"
      KEY_FILE="$CERT_DIR/grafana.vulcan.lan.key"

      # Check if certificate already exists and is valid
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Check if certificate is still valid for at least 30 days
        if ${pkgs.openssl}/bin/openssl x509 -in "$CERT_FILE" -noout -checkend 2592000; then
          echo "Certificate is still valid for more than 30 days"
          exit 0
        fi
      fi

      # For now, create a self-signed certificate as a fallback
      # This will be replaced once step-ca certificate generation is working
      echo "Creating temporary self-signed certificate for grafana.vulcan.lan"

      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 365 \
        -nodes \
        -subj "/CN=grafana.vulcan.lan" \
        -addext "subjectAltName=DNS:grafana.vulcan.lan"

      # Set proper permissions
      chmod 644 "$CERT_FILE"
      chmod 600 "$KEY_FILE"
      chown -R nginx:nginx "$CERT_DIR"

      echo "Certificate generated successfully"
    '';
  };

  # Ensure Grafana starts after Prometheus
  systemd.services.grafana = {
    after = [ "prometheus.service" ];
    wants = [ "prometheus.service" ];
    # Filter out info-level logs to reduce log volume
    # Saves ~1,776 lines/day by only logging warnings and above
    serviceConfig.LogLevelMax = "warning";
  };

  # Prometheus scrape configuration for Grafana metrics
  services.prometheus.scrapeConfigs = [
    {
      job_name = "grafana";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.grafana.settings.server.http_port}" ];
        }
      ];
      scrape_interval = "30s";
    }
  ];

}
