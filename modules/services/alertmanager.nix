{ config, lib, pkgs, ... }:

{
  services.prometheus.alertmanager = {
    enable = true;
    port = 9093;
    listenAddress = "127.0.0.1";
    webExternalUrl = "https://alertmanager.vulcan.lan";

    configuration = {
      global = {
        # Email configuration using local postfix
        smtp_from = "alertmanager@vulcan.lan";
        smtp_smarthost = "localhost:25";
        smtp_require_tls = false;
      };

      # Route configuration
      route = {
        receiver = "default-receiver";
        group_by = [ "alertname" "cluster" "service" ];
        group_wait = "10s";
        group_interval = "10m";
        repeat_interval = "1h";

        # Special routing for critical alerts
        routes = [
          {
            match = {
              severity = "critical";
            };
            receiver = "critical-receiver";
            repeat_interval = "15m";
          }
        ];
      };

      # Receivers configuration
      receivers = [
        {
          name = "default-receiver";
          email_configs = [
            {
              to = "johnw@newartisans.com";
              headers = {
                Subject = "[{{ .GroupLabels.severity | toUpper }}] {{ .GroupLabels.alertname }} on vulcan";
              };
              text = ''
                {{ range .Alerts }}
                Alert: {{ .Labels.alertname }}
                Severity: {{ .Labels.severity }}
                Summary: {{ .Annotations.summary }}
                Description: {{ .Annotations.description }}

                Labels:
                {{ range .Labels.SortedPairs }}  - {{ .Name }}: {{ .Value }}
                {{ end }}

                Source: {{ .GeneratorURL }}
                {{ end }}
              '';
            }
          ];
        }
        {
          name = "critical-receiver";
          email_configs = [
            {
              to = "johnw@newartisans.com";
              headers = {
                Subject = "[CRITICAL] {{ .GroupLabels.alertname }} - IMMEDIATE ACTION REQUIRED";
                Priority = "1";
                X-Priority = "1";
              };
              text = ''
                CRITICAL ALERT - IMMEDIATE ACTION REQUIRED

                {{ range .Alerts }}
                Alert: {{ .Labels.alertname }}
                Time: {{ .StartsAt.Format "2006-01-02 15:04:05 MST" }}
                Summary: {{ .Annotations.summary }}
                Description: {{ .Annotations.description }}

                Labels:
                {{ range .Labels.SortedPairs }}  - {{ .Name }}: {{ .Value }}
                {{ end }}

                View in Prometheus: {{ .GeneratorURL }}
                {{ end }}
              '';
            }
          ];
        }
      ];

      # Inhibit rules to prevent alert storms
      inhibit_rules = [
        {
          source_match = {
            severity = "critical";
          };
          target_match = {
            severity = "warning";
          };
          equal = [ "alertname" "instance" ];
        }
      ];
    };
  };

  # Configure Prometheus to use alertmanager
  services.prometheus.alertmanagers = [
    {
      scheme = "http";
      static_configs = [
        {
          targets = [ "localhost:${toString config.services.prometheus.alertmanager.port}" ];
        }
      ];
    }
  ];

  # Ensure alertmanager starts after network
  systemd.services.alertmanager = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };


  # Alertmanager nginx upstream with retry logic
  # Prevents 502 errors during service restarts
  services.nginx.upstreams."alertmanager" = {
    servers = {
      "127.0.0.1:${toString config.services.prometheus.alertmanager.port}" = {
        max_fails = 0;
      };
    };
    extraConfig = ''
      keepalive 8;
      keepalive_timeout 60s;
    '';
  };

  # Keep the existing nginx configuration
  services.nginx.virtualHosts."alertmanager.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/alertmanager.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/alertmanager.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://alertmanager/";
      recommendedProxySettings = true;
      extraConfig = ''
        # Retry logic for temporary backend failures
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;
      '';
    };
  };
}
