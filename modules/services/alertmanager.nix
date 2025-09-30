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
          {
            # Route ZFS replication alerts
            match = {
              component = "zfs_replication";
            };
            receiver = "replication-receiver";
            group_wait = "30s";
            repeat_interval = "4h";
          }
          {
            # Route Chainweb blockchain alerts
            match = {
              component = "chainweb";
            };
            receiver = "chainweb-receiver";
            group_wait = "30s";
            repeat_interval = "15m";  # More frequent notifications for blockchain issues
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
        {
          name = "replication-receiver";
          email_configs = [
            {
              to = "johnw@newartisans.com";
              headers = {
                Subject = "[ZFS Replication] {{ .GroupLabels.alertname }}";
              };
              text = ''
                ZFS REPLICATION ALERT

                {{ range .Alerts }}
                Alert: {{ .Labels.alertname }}
                Status: {{ .Status }}
                Time: {{ .StartsAt.Format "2006-01-02 15:04:05 MST" }}

                {{ .Annotations.summary }}

                Details:
                {{ .Annotations.description }}

                Affected Service: {{ .Labels.name }}

                To investigate:
                - Check service status: systemctl status {{ .Labels.name }}
                - View logs: journalctl -u {{ .Labels.name }} -n 100
                - Run manual check: check-zfs-replication
                {{ end }}
              '';
            }
          ];
        }
        {
          name = "chainweb-receiver";
          email_configs = [
            {
              to = "johnw@kadena.io";
              headers = {
                Subject = "[CHAINWEB ALERT] {{ .GroupLabels.alertname }}";
                Priority = "1";  # High priority for blockchain alerts
              };
              text = ''
                KADENA CHAINWEB ALERT

                {{ range .Alerts }}
                Alert: {{ .Labels.alertname }}
                Severity: {{ .Labels.severity }}
                Time: {{ .StartsAt.Format "2006-01-02 15:04:05 MST" }}

                Summary: {{ .Annotations.summary }}

                Details:
                {{ .Annotations.description }}

                Current Status: {{ .Status }}

                Labels:
                {{ range .Labels.SortedPairs }}  - {{ .Name }}: {{ .Value }}
                {{ end }}

                Actions to take:
                - Check exporter status: systemctl status chainweb-node-exporter
                - View exporter logs: journalctl -u chainweb-node-exporter -n 50
                - Check current metrics: curl localhost:9101/metrics | grep kadena
                - View in Prometheus: {{ .GeneratorURL }}
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


  # Keep the existing nginx configuration
  services.nginx.virtualHosts."alertmanager.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/alertmanager.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/alertmanager.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.prometheus.alertmanager.port}";
      recommendedProxySettings = true;
    };
  };
}
