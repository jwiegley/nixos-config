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
        # 24h (was 4h): a still-firing alert re-emails at most once/day, not
        # every 4h. With long-lived deferred conditions (a dead device, a
        # pending token re-auth) the 4h repeat produced ~6 reminders/day/alert
        # (2026-07-21 flood). group_wait/group_interval still notify NEW alerts
        # and state changes promptly; this only slows the reminders.
        repeat_interval = "24h";

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
          # Drafts MCP self-heal pipeline — service=drafts-mcp alerts go to
          # the drafts-mcp-self-heal webhook receiver. continue=true keeps the
          # email/critical/iPhone paths firing so a human still sees it.
          # NOTE: any future drafts-self-heal watchdog alert MUST carry a
          # distinct service label (e.g. service=drafts-mcp-self-heal) so it
          # never loops back to the possibly-dead daemon, mirroring the
          # / hermes self-watchdog exclusions above.
          {
            match = {
              service = "drafts-mcp";
            };
            receiver = "drafts-mcp-self-heal";
            group_wait = "10s";
            group_interval = "5m";
            repeat_interval = "4h";
            continue = true;
          }
          # D13 (2026-07-29): info-severity paging policy -- promote 4, digest the other 17.
          #
          # Before this, info alerts emailed like anything else, which is the bulk of the
          # notification volume this host produces. The four promoted here keep notifying
          # because each is a COVERAGE failure rather than a status report: a CVE scanner that
          # stops scanning, or a stale CVE database, means the check silently stopped checking
          # (the vacuous-check class), and on this host only the operator reboots, so an
          # unexpected reboot is always worth knowing about.
          #
          # "Digest" is not a euphemism for dropping them -- VERIFIED before making this change:
          # AlertHistory in scripts/log-summarizer.py collects ALERTS{alertstate="firing"} with
          # NO severity filter, so all 17 still appear in the daily report's alert-history
          # section with their firing durations. Had that section filtered to warning+, this
          # route would be silent suppression and D13 would need a different design.
          #
          # PLACEMENT IS LOAD-BEARING: this must precede the storage route below, which matches
          # `category = "storage"` with no severity condition and no `continue`, so it
          # TERMINATES. Exactly one info rule carries that category (ResticRepositorySizeGrowing);
          # placed after, it would silently escape the digest and keep emailing.
          #
          # `matchers` rather than match/match_re because the negative regex `!~` cannot be
          # expressed by either of those (Alertmanager >= 0.22). First use of it in this file.
          {
            matchers = [
              "severity=\"info\""
              "alertname!~\"HostUnexpectedReboot|ContainerCVEScanFailed|ContainerCVEDBStale|MicroVMStateShareExporterStale\""
            ];
            receiver = "null-receiver";
            continue = false;
          }
          # Backup and storage alerts - group by category and reduce noise.
          #
          # `severity!="critical"` added 2026-07-29. This route has no `continue`, so it
          # TERMINATES -- and because it sat ahead of both critical routes and matched on
          # category alone, every CRITICAL storage alert was swallowed here: email only, on
          # this route's 12h repeat_interval, never reaching iphone-notifier or
          # critical-receiver's 4h. That silently covered the most severe failures this host
          # can have. Found by an amtool regression test while implementing D13; 19 rules were
          # affected:
          #   TankMountGone (the documented USB/UAS enclosure failure mode)
          #   ZFSPool{Suspended,Degraded,DataErrors,CapacityCritical}, ZFSScrubErrors
          #   NVMe{SmartFailed,MediaErrors,CriticalWarning,SpareExhausted}  (the boot disk)
          #   Restic{IntegrityCheckFailed,CheckFailed,NoSnapshots}
          #   SmartDevice{Unhealthy,Missing}, LocalBackup{Missing,Stale},
          #   NodeRedBackupFailed, TechnitiumBackupFailed
          #
          # Excluding critical here (rather than adding `continue = true`) is deliberate, but
          # CORRECTED 2026-07-29 -- the reason first recorded here was mechanically wrong and an
          # audit reproduced the counterfactual. `continue = true` advances to the next SIBLING
          # route; the PARENT receiver is appended only when no child matched at all. So it
          # would NOT have double-delivered the warnings via default-receiver: with
          # `continue = true` all 32 warning-storage labelsets still resolve to storage-receiver
          # alone, exactly as they do now.
          #
          # The double delivery `continue = true` would really have caused is on the 19
          # CRITICALS -- storage-receiver AND critical-receiver, both of which email
          # johnw@vulcan.lan, plus the iPhone webhook. So the design choice stands; only its
          # stated justification was wrong. Getting `continue` backwards matters beyond this
          # route: it governs four others in this file.
          #
          # Info-severity storage alerts never reach this route at all -- the D13 digest route
          # above catches them first.
          {
            matchers = [
              "category=\"storage\""
              "severity!=\"critical\""
            ];
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
        # Digest-only sink for D13's 17 non-promoted info alerts. Deliberately has no
        # notifier: these alerts still reach the operator through the daily report's
        # alert-history section (see the route comment above), so a second delivery path
        # here would defeat the purpose.
        {
          name = "null-receiver";
        }
        {
          name = "default-receiver";
          email_configs = [
            {
              to = "johnw@vulcan.lan";
              headers = {
                # CommonLabels (not GroupLabels) so severity renders even
                # though it isn't in this route's group_by — otherwise the
                # subject prefix is an empty "[]".
                Subject = "[{{ .CommonLabels.severity | toUpper }}] {{ .GroupLabels.alertname }} on vulcan";
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
          name = "hermes-self-heal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:9098/alert";
              send_resolved = true;
            }
          ];
        }
        {
          name = "drafts-mcp-self-heal";
          webhook_configs = [
            {
              url = "http://127.0.0.1:9085/alert";
              send_resolved = true;
            }
          ];
        }
        # iPhone push via Node-RED's /alert HTTP-In endpoint.
        # Auth token is extracted at service start (ExecStartPre) from
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
              url = "http://127.0.0.1:${toString config.services.node-red.port}/alert";
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
        # notification POSTs to the EXTERNAL heartbeat URL (healthchecks.io)
        # read from url_file on every notify (Alertmanager 0.29 supports
        # url_file). send_resolved=false: a heartbeat is a ping, never a
        # "resolved". max_alerts=1: the body carries no useful per-alert
        # payload, so cap it.
        #
        # The URL is a SOPS secret ("watchdog-ping-url", declared below).
        # sops-install-secrets drops it root-only at /run/secrets, and
        # because alertmanager runs as a DynamicUser (no stable uid to chown
        # to), systemd LoadCredential= (see the service block) copies it into
        # the per-service credential store — which is where url_file points.
        # To rotate: edit the secrets repo with `sops`, commit, bump the
        # flake lock for the `secrets` input, then rebuild. If the secret is
        # ever missing, alertmanager fails to start (LoadCredential is a hard
        # dependency) — fail-loud rather than silently un-monitored.
        {
          name = "watchdog-deadman";
          webhook_configs = [
            {
              url_file = "/run/credentials/alertmanager.service/watchdog-ping-url";
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
          # `repository=~".+"` added 2026-07-29. `equal = [ "repository" ]` compares label
          # VALUES, and Alertmanager's comparison is a plain map lookup -- so when the label is
          # absent from BOTH sides it compares "" == "" and the inhibition APPLIES. Only
          # restic_* and git_workspace_* series carry a repository label, so 17 of the 19
          # critical and 30 of the 32 warning storage rules have none: any repository-less
          # storage critical was muting every repository-less storage warning, ACROSS UNRELATED
          # HARDWARE -- e.g. TankMountGone on the USB enclosure silencing NVMe wear and pending
          # sector warnings on the boot disk. This is the same "" == "" semantics this file
          # already documents two rules below, which had simply never been applied here.
          #
          # Requiring a non-empty repository on both sides confines the rule to the
          # same-repository case it was written for. Measured before changing it: the loud
          # cross-device pairs had 0 minutes of real overlap in 30d and TankMountGone never
          # fired, so this was latent rather than actively harmful -- fixed on the semantics,
          # not on an observed incident.
          source_match = {
            severity = "critical";
            category = "storage";
          };
          source_match_re = {
            repository = ".+";
          };
          target_match = {
            severity = "warning";
            category = "storage";
          };
          target_match_re = {
            repository = ".+";
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
        # Suppress the "backup is stale" alert when the backup SERVICE is already failing
        # for the same repository -- the staleness is a consequence, not new information.
        #
        # RETARGETED 2026-07-28. This rule was a double no-op as originally written:
        #  1. Its target, alertname "BackupNotRunning", came from the generated
        #     `backup_alerts` group whose metrics do not exist on this host, so the target
        #     could never fire. That group has now been deleted (see
        #     modules/storage/backup-monitoring.nix); the live equivalent is
        #     BackupNotRunRecently in health-checks.yaml.
        #  2. Even had it fired, `equal = [ "name" ]` could never have matched. The old
        #     target's expr selected a `unit` label, so `name` was PRESENT on the source
        #     (restic-backups-X.service) and ABSENT on the target. Precise mechanism:
        #     Alertmanager compares source.Labels[n] against target.Labels[n] on a Go map
        #     where a missing key yields "", so a label absent from BOTH sides compares
        #     equal and the inhibition WOULD apply -- it was the one-sided mismatch that
        #     defeated it, not the mere absence. Either way: no error, no effect.
        # `equal = [ "backup" ]` is correct, but note precisely WHICH source serves it.
        # There are TWO live alerts named BackupServiceFailed:
        #   health_check_alerts    `backup_service_failed == 1`              for=300s, HAS `backup`
        #   systemd_service_health `node_systemd_unit_state{...} == 1`       for=60s,  has `name`, NOT `backup`
        # Only the first can satisfy this join. That is fine -- Alertmanager scans all
        # cached source alerts rather than just the first alertname match, so the
        # label-less variant does not block the working one -- but it has two consequences
        # worth knowing: the target is UNINHIBITED during the 60s-300s window when only the
        # faster source has fired, and the pair co-fires rarely in practice because the
        # exporter refreshes backup_last_run_timestamp_seconds from the unit's activation
        # timestamps on EVERY attempt, so a repeatedly-failing-but-still-triggering backup
        # keeps a fresh last-run. The inhibition mainly engages in the "service failed AND
        # timer stopped" case.
        {
          source_match = {
            alertname = "BackupServiceFailed";
          };
          target_match = {
            alertname = "BackupNotRunRecently";
          };
          equal = [ "backup" ];
        }
        # Parent/child network topology for the IoT ICMP coverage. The IoT
        # devices all hang off the IoT-subnet network gear (the ASUS
        # router/AP/mesh-node). If that gateway itself goes unreachable, EVERY
        # downstream IoT device will fail its ICMP probe at once — that is a
        # single root-cause event, not N independent device failures. This is
        # the classic parent/child host-dependency pattern, expressed here as an
        # Alertmanager inhibition rule.
        #
        # source: HostUnreachable firing for the gateway/AP/router instances
        # (those infra hosts live in host_group="local", so a gateway outage
        # trips the always-on HostUnreachable critical). target: the
        # BlackboxICMPIoTDeviceDown warnings for the child devices.
        #
        # equal = [] (no shared label): when the gateway is down we suppress ALL
        # IoT-down warnings regardless of which specific device, since the
        # gateway being unreachable explains every child failure. The gateway
        # instances are matched by name via source_match_re.
        #
        # SOURCE LIST CORRECTED 2026-07-31. It previously also listed
        # asus-rt-ax88u.lan and asus-bq16-pro-node.lan. Neither is a gateway:
        # checked against the host inventory, both have ZERO children and both
        # have parent = asus-bq16-pro-ap, i.e. they are LEAVES. Combined with
        # equal = [] making the join unconditional, either leaf going down
        # silenced ALL 16 BlackboxICMPIoTDeviceDown warnings -- one unrelated
        # device failure blanket-muting the entire IoT tier, and presenting as
        # quiet rather than as breakage. That matters here because the leaves
        # fail far more often than the real gateway: over 365d of firing
        # samples, hera-wifi 16,249 and asus-bq16-pro-node 6,199 against
        # asus-bq16-pro-ap's 31.
        #
        # asus-bq16-pro-ap is the only genuine parent of the IoT devices
        # (18 children), so it is the only correct source. This is the whole of
        # the topology modelling here by deliberate choice: a general
        # parent/child scheme was designed and REJECTED as unnecessary
        # complexity -- measured over 90d it would have suppressed ~6 extra
        # alerts once a quarter. Keep this one rule; do not rebuild the general
        # case.
        {
          source_match = {
            alertname = "HostUnreachable";
          };
          source_match_re = {
            instance = "(asus-bq16-pro-ap\\.lan)";
          };
          target_match = {
            alertname = "BlackboxICMPIoTDeviceDown";
          };
          equal = [ ];
        }
        # Same parent/child suppression, but for the case where the gateway/AP
        # itself is also (mis)classified into the IoT coverage and reported via
        # BlackboxICMPIoTDeviceDown rather than HostUnreachable. Keyed on the
        # same gateway instance name so the child IoT warnings are still
        # inhibited by a single upstream failure. Source list corrected in the
        # same change and for the same reason as the rule above.
        {
          source_match = {
            alertname = "BlackboxICMPIoTDeviceDown";
          };
          source_match_re = {
            instance = "(asus-bq16-pro-ap\\.lan)";
          };
          target_match = {
            alertname = "BlackboxICMPIoTDeviceDown";
          };
          equal = [ ];
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

  # Dead-man's-switch heartbeat URL (healthchecks.io) consumed by the
  # watchdog-deadman receiver. Root-owned in /run/secrets; alertmanager
  # (DynamicUser) reads it from its credential store via LoadCredential
  # below, never directly. Lives in the `secrets` flake input.
  sops.secrets."watchdog-ping-url" = {
    mode = "0400";
    owner = "root";
  };

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
    # Hand the SOPS-managed healthchecks.io heartbeat URL to alertmanager's
    # credential store. DynamicUser has no stable uid to chown /run/secrets
    # to, so the watchdog-deadman receiver reads it from
    # /run/credentials/alertmanager.service/watchdog-ping-url (its url_file).
    serviceConfig.LoadCredential = [
      "watchdog-ping-url:${config.sops.secrets."watchdog-ping-url".path}"
    ];
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
