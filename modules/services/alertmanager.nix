{
  config,
  lib,
  pkgs,
  ...
}:

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
        group_by = [
          "alertname"
          "cluster"
          "service"
        ];
        group_wait = "10s";
        group_interval = "10m";
        repeat_interval = "4h";

        # Special routing rules
        routes = [
          # Dead-man's switch (P0 #4). The always-firing Watchdog rule
          # (severity=watchdog, expr vector(1)) must be peeled off FIRST
          # and sent ONLY to the watchdog-deadman webhook receiver, which
          # pings an EXTERNAL heartbeat endpoint (healthchecks.io). It
          # fires forever by design, so continue=false is mandatory:
          # without this carve-out it would fall through to
          # default-receiver and email constantly, and a severity match
          # below could also page the iPhone. This route MUST stay the
          # first entry in routes[] so the watchdog never reaches any
          # other receiver. repeat_interval (4m) is the heartbeat cadence;
          # configure the healthchecks.io check's grace period to a small
          # multiple of it so a stalled alerting pipeline trips the
          # external check.
          {
            match = {
              severity = "watchdog";
            };
            receiver = "watchdog-deadman";
            group_wait = "15s";
            group_interval = "3m";
            repeat_interval = "4m";
            continue = false;
          }
          # OpenClawConfigDrift is an informational warning-severity
          # alert (for: 24h) about live-config vs. Nix-template schema
          # drift.  It must NOT trigger restart_microvm — restarting
          # the VM doesn't reconcile the JSON, so before this carve-out
          # the daemon's default-action fallback bounced the VM on
          # Alertmanager's repeat_interval (every 4h) indefinitely.
          # Route to email-only so a human sees it and can fix the
          # drift, but the self-heal daemon never gets the webhook.
          # continue=false: do not fall through to openclaw-self-heal.
          {
            match = {
              alertname = "OpenClawConfigDrift";
            };
            receiver = "default-receiver";
            group_wait = "30s";
            group_interval = "1h";
            repeat_interval = "24h";
            continue = false;
          }
          # Self-heal pipeline — service=openclaw alerts go to the
          # openclaw-self-heal daemon's webhook receiver.  continue=true
          # keeps the email/critical paths firing too so a human still
          # sees the alert, even when the daemon takes the action.
          # NOTE: alerts with service=openclaw-self-heal (the daemon's
          # own watchdog) intentionally do NOT match here, so they never
          # loop back to the daemon that may already be dead.
          {
            match = {
              service = "openclaw";
            };
            receiver = "openclaw-self-heal";
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "4h";
            continue = true;
          }
          # Hermes self-heal pipeline — service=hermes-mcp and
          # service=hermes-agent alerts both go to the hermes-self-heal
          # daemon's webhook receiver. continue=true preserves the email
          # path so a human still sees the critical alert.
          # NOTE: alerts with service=hermes-self-heal (the daemon's own
          # watchdog) intentionally do NOT match here, so they never loop
          # back to the daemon that may already be dead.
          # First use of match_re in this file; passes through to upstream
          # Alertmanager YAML.
          {
            match_re = {
              service = "hermes-(mcp|agent)";
            };
            receiver = "hermes-self-heal";
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "4h";
            continue = true;
          }
          # Backup and storage alerts - group by category and reduce noise
          {
            match = {
              category = "storage";
            };
            receiver = "storage-receiver";
            group_by = [
              "alertname"
              "category"
              "repository"
            ];
            group_wait = "30s";
            group_interval = "30m";
            repeat_interval = "12h";
          }
          # iPhone push for critical alerts. continue=true so the
          # email/grouped-critical receiver below ALSO fires. Auth via
          # bearer token extracted from /run/secrets/node-red/api-tokens
          # at alertmanager startup (see systemd override).
          {
            match = {
              severity = "critical";
            };
            receiver = "iphone-notifier";
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "4h";
            continue = true;
          }
          # Critical alerts - faster notification but still grouped
          {
            match = {
              severity = "critical";
            };
            receiver = "critical-receiver";
            group_by = [
              "alertname"
              "severity"
              "service"
              "repository"
            ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
          }
        ];
      };

      # Receivers configuration
      receivers = [
        {
          name = "default-receiver";
          email_configs = [
            {
              to = "johnw@vulcan.lan";
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
          name = "storage-receiver";
          email_configs = [
            {
              to = "johnw@vulcan.lan";
              headers = {
                Subject = "[Storage] {{ .GroupLabels.alertname }} - {{ .Alerts | len }} alert(s)";
              };
              text = ''
                Storage/Backup Alert Summary
                ============================

                Alert: {{ .GroupLabels.alertname }}
                Category: {{ .GroupLabels.category }}
                Affected Items: {{ .Alerts | len }}

                {{ range .Alerts }}
                ---
                {{ if .Labels.repository }}Repository: {{ .Labels.repository }}{{ end }}
                {{ if .Labels.pool }}Pool: {{ .Labels.pool }}{{ end }}
                {{ if .Labels.snapshot }}Snapshot: {{ .Labels.snapshot }}{{ end }}
                Severity: {{ .Labels.severity }}
                Summary: {{ .Annotations.summary }}
                Description: {{ .Annotations.description }}

                {{ end }}

                This alert will repeat in 12 hours if not resolved.
              '';
            }
          ];
        }
        {
          name = "critical-receiver";
          email_configs = [
            {
              to = "johnw@vulcan.lan";
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
          name = "openclaw-self-heal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:9092/alert";
              send_resolved = true;
            }
          ];
        }
        {
          name = "hermes-self-heal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:9098/alert";
              send_resolved = true;
            }
          ];
        }
        # iPhone push via Node-RED's /alert HTTP-In endpoint.
        # Auth token is extracted at activation time from
        # /run/secrets/node-red/api-tokens (see the alertmanager
        # systemd override below) and placed at
        # /run/alertmanager/nr-token (mode 0400 alertmanager).
        # Routed to from the critical-severity match in the routes
        # block with continue=true so other matching receivers
        # (email, self-heal) still fire — this is an additive page.
        {
          name = "iphone-notifier";
          webhook_configs = [
            {
              url = "http://127.0.0.1:1880/alert";
              send_resolved = true;
              http_config = {
                authorization = {
                  type = "Bearer";
                  credentials_file = "/run/alertmanager/nr-token";
                };
              };
            }
          ];
        }
        # Dead-man's switch delivery (P0 #4). The Watchdog alert is routed
        # here (and ONLY here) by the severity=watchdog route. Each
        # notification POSTs to the EXTERNAL heartbeat URL stored in
        # url_file — keeping the secret URL out of the Nix store / git.
        # url_file is read on every notify, so the URL can be installed or
        # rotated without a rebuild (Alertmanager 0.29 supports url_file).
        # send_resolved=false: a heartbeat is a ping, never a "resolved".
        # max_alerts=1: the body carries no useful per-alert payload, so
        # cap it. The file must be created by the operator at
        # /var/lib/alertmanager/watchdog-ping-url (the StateDirectory,
        # owned alertmanager:alertmanager, mode 0600) and hold a single
        # healthchecks.io ping URL. Until it exists, notify fails and
        # alertmanager_notifications_failed_total rises — intentional
        # loud-until-configured behavior (the delivery-failure alert, once
        # AM is scraped, surfaces the missing config).
        {
          name = "watchdog-deadman";
          webhook_configs = [
            {
              url_file = "/var/lib/alertmanager/watchdog-ping-url";
              send_resolved = false;
              max_alerts = 1;
            }
          ];
        }
      ];

      # Inhibit rules to prevent alert storms
      inhibit_rules = [
        # Suppress warning alerts when critical alerts are firing for the same service
        {
          source_match = {
            severity = "critical";
          };
          target_match = {
            severity = "warning";
          };
          equal = [
            "alertname"
            "instance"
          ];
        }
        # Suppress warning backup alerts when critical backup alerts are firing for same repo
        {
          source_match = {
            severity = "critical";
            category = "storage";
          };
          target_match = {
            severity = "warning";
            category = "storage";
          };
          equal = [ "repository" ];
        }
        # Suppress ResticNoRecentSnapshot when ResticCheckFailed is firing for same repo
        {
          source_match = {
            alertname = "ResticCheckFailed";
          };
          target_match = {
            alertname = "ResticNoRecentSnapshot";
          };
          equal = [ "repository" ];
        }
        # Suppress BackupNotRunning when BackupServiceFailed is firing for same backup
        {
          source_match = {
            alertname = "BackupServiceFailed";
          };
          target_match = {
            alertname = "BackupNotRunning";
          };
          equal = [ "name" ];
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
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    wants = [ "network-online.target" ];

    # Extract the Node-RED bearer token from
    # /run/secrets/node-red/api-tokens (an array of token objects)
    # and write the first token to /run/alertmanager/nr-token at
    # mode 0400 alertmanager:alertmanager. The iphone-notifier
    # receiver (above) references this file via credentials_file.
    #
    # PermissionsStartOnly=true would be cleaner but is removed in
    # newer systemd; we use ExecStartPre with +/ prefix (run as root)
    # to do the privileged extraction without giving alertmanager.service
    # broader perms.
    serviceConfig.RuntimeDirectory = lib.mkForce [ "alertmanager" ];
    serviceConfig.RuntimeDirectoryMode = "0750";
    serviceConfig.ExecStartPre = [
      (
        "+"
        + pkgs.writeShellScript "alertmanager-extract-nr-token" ''
          set -eu
          token=$(${pkgs.jq}/bin/jq -r '.[0].token' /run/secrets/node-red/api-tokens)
          if [ -z "$token" ] || [ "$token" = "null" ]; then
            echo "alertmanager: failed to extract Node-RED api token" >&2
            exit 1
          fi
          umask 0277
          printf %s "$token" > /run/alertmanager/nr-token
          chown alertmanager:alertmanager /run/alertmanager/nr-token
          chmod 0400 /run/alertmanager/nr-token
        ''
      )
    ];
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
