{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    # Hardware configuration
    ./hardware-configuration.nix

    # Core modules
    ../../modules/core/base.nix
    ../../modules/core/networking.nix
    ../../modules/core/wifi.nix
    ../../modules/core/system.nix
    ../../modules/core/programs.nix
    ../../modules/core/memory-limits.nix
    ../../modules/core/crash-debug.nix

    # Hardware modules
    ../../modules/hardware/wifi-stability.nix

    # Security modules
    ../../modules/security/hardening.nix
    ../../modules/security/aide.nix
    ../../modules/security/root-ssh-gitea.nix
    ../../modules/monitoring/aide-nagios-check.nix

    # User management
    ../../modules/users/johnw.nix
    ../../modules/users/nasimw.nix
    ../../modules/users/assembly.nix
    ../../modules/users/bia.nix
    ../../modules/users/rbcca.nix
    ../../modules/users/container-users-dedicated.nix
    ../../modules/users/home-manager
    ../../modules/users/home-manager/johnw.nix
    ../../modules/users/home-manager/container-users-dedicated.nix

    # Rootless container Home Manager configs
    ../../modules/users/home-manager/changedetection.nix
    ../../modules/users/home-manager/mailarchiver.nix
    ../../modules/users/home-manager/open-webui.nix
    ../../modules/users/home-manager/openproject.nix
    ../../modules/users/home-manager/nocobase.nix
    ../../modules/users/home-manager/wallabag.nix
    ../../modules/users/home-manager/opnsense-exporter.nix
    # technitium-dns-exporter: Reverted to system-level container (uses localhost image)
    ../../modules/users/home-manager/vane.nix
    ../../modules/users/home-manager/speedtest-tracker.nix

    # Services
    ../../modules/services/alertmanager.nix
    ../../modules/services/blackbox-monitoring.nix
    ../../modules/services/certificate-automation.nix
    ../../modules/services/certificates.nix
    ../../modules/services/cleanup.nix
    ../../modules/services/cloudflare-tunnels.nix
    ../../modules/services/databases.nix
    ../../modules/services/dirscan-share-config.nix
    ../../modules/services/dirscan-share.nix
    ../../modules/services/dovecot-archive.nix
    ../../modules/services/dovecot-imapsieve-monitor.nix
    ../../modules/services/dovecot-fts-monitor.nix
    ../../modules/services/dovecot.nix
    ../../modules/services/eternal-terminal.nix
    ../../modules/services/gitea-actions-runner.nix
    ../../modules/services/gitea.nix
    ../../modules/services/github-gitea-mirror.nix
    ../../modules/services/flume-data.nix
    ../../modules/services/grafana.nix
    ../../modules/services/home-assistant-metric-trick.nix
    ../../modules/services/home-assistant.nix
    ../../modules/services/home-assistant-water-attribution.nix
    ../../modules/services/immich.nix
    ../../modules/services/local-backup.nix
    ../../modules/services/loki.nix
    ../../modules/services/media.nix
    ../../modules/services/model-config.nix
    ../../modules/services/monitoring.nix
    ../../modules/services/mosquitto.nix
    ../../modules/services/nagios.nix
    ../../modules/services/network-services.nix
    ../../modules/services/node-red.nix
    ../../modules/services/nut.nix
    ../../modules/services/node-red-backup.nix
    ../../modules/services/node-red-event-logger.nix
    ../../modules/services/pgadmin.nix
    ../../modules/services/postfix.nix
    ../../modules/services/postgresql-backup.nix
    ../../modules/services/promtail.nix
    ../../modules/services/rclone-cloud-backup.nix
    ../../modules/services/rspamd-alerts.nix
    ../../modules/services/rspamd.nix
    ../../modules/services/service-reliability.nix
    ../../modules/services/stock-trader.nix
    ../../modules/services/technitium-dns-backup.nix
    ../../modules/services/web.nix

    # Service monitoring
    ../../modules/monitoring/container-health-exporter.nix
    ../../modules/monitoring/homeassistant-nagios-check.nix
    ../../modules/monitoring/nagios-daily-report.nix
    ../../modules/monitoring/services

    # Email testing script (manual use only)
    # Note: Automated monitoring disabled to avoid over-training rspamd
    ../../modules/services/email-tester-manual.nix
    ../../modules/services/imapdedup.nix
    ../../modules/services/mbsync.nix
    ../../modules/services/fetchmail.nix
    ../../modules/services/fetchmail-alerts.nix
    ../../modules/services/radicale.nix
    ../../modules/services/calendar-publisher.nix
    ../../modules/monitoring/services/calendar-publisher-health.nix
    ../../modules/services/vdirsyncer.nix
    ../../modules/services/dns.nix
    ../../modules/services/glance.nix
    ../../modules/services/glances.nix
    ../../modules/services/searxng.nix
    ../../modules/services/vane.nix
    ../../modules/services/vane-llm-shim.nix
    ../../modules/monitoring/services/copyparty-exporter.nix
    ../../modules/monitoring/services/hermes-fallback-counter.nix
    ../../modules/services/nginx-default-vhost.nix
    ../../modules/services/hera-llm-proxy.nix
    ../../modules/services/syncthing.nix
    ../../modules/services/pushme-positron.nix
    ../../modules/services/session-gather.nix
    ../../modules/services/aria2.nix
    ../../modules/services/atd.nix
    ../../modules/services/atd-web.nix
    ../../modules/services/atd-nginx.nix
    ../../modules/monitoring/services/atd-exporter.nix
    ../../modules/monitoring/services/atd-alerts.nix
    ../../modules/monitoring/services/atd-nagios.nix
    ../../modules/services/zimit.nix
    ../../modules/services/hermes-nightly-report.nix
    ../../modules/services/open-source-secretary.nix
    ../../modules/services/hermes-microvm.nix
    ../../modules/services/hermes-mcp.nix
    ../../modules/services/drafts-mcp.nix
    ../../modules/services/drafts-mcp-self-heal.nix
    ../../modules/services/hermes-self-heal.nix
    ../../modules/services/qdrant.nix
    ../../modules/services/qdrant-inference-bridge.nix
    ../../modules/monitoring/services/qdrant-nagios.nix
    ../../modules/services/voice-assistant.nix
    # nagios-prometheus-mirror.nix REMOVED 2026-07-31 -- the operator is undoing the
    # Nagios/Prometheus duplication. That module generated one `PROM-MIRROR <alertname>`
    # Nagios service per Prometheus rule (499 of them, i.e. 60% of Nagios's entire service
    # set) purely so each stack could re-check the other. It is duplication by construction,
    # so it is the first thing to go.
    #
    # nagios-tier1-mirror.nix DELIBERATELY KEPT despite the name: it is NOT generated
    # mirror machinery. Of its hand-curated services, several textfile collectors have no
    # Prometheus equivalent at all (atd, imapsieve, git_workspace, fts_staleness); the two
    # openclaw_* ones went with OpenClaw on 2026-08-03. Deleting it would drop real coverage, and would
    # also move the native check count 339 -> 255, breaking the acceptance invariant that
    # this change leaves native checks untouched.
    ../../modules/monitoring/services/nagios-tier1-mirror.nix

    # Containers
    ../../modules/containers/default.nix
    ../../modules/containers/matter-server-quadlet.nix
    ../../modules/containers/openproject-quadlet.nix

    # Maintenance
    ../../modules/maintenance/timers.nix

    # Packages
    ../../modules/packages/custom.nix
    ../../modules/packages/zsh.nix

    # Storage
    ../../modules/storage/zfs.nix
    ../../modules/storage/hd-idle.nix
    ../../modules/storage/backups.nix
    ../../modules/storage/backup-monitoring.nix
    ../../modules/services/samba.nix
  ];

  # GitHub to Gitea mirroring service
  services.github-gitea-mirror = {
    enable = true;
    githubUser = "jwiegley";
    giteaUser = "johnw";
    giteaUrl = "https://gitea.vulcan.lan";
    mirrorInterval = "8h"; # 8 hours (Go duration format)
    schedule = "*-*-* 03:00:00"; # Daily at 3 AM
  };

  services.stock-trader.enable = true;
  services.hermes-mcp.enable = true;
  services.open-source-secretary.enable = true;
  services.drafts-mcp.enable = true;
  services.draftsMcpCheck.enable = true;
  services.draftsMcpSelfHeal.enable = true;
  services.hermesHealthCheck = {
    enable = true;
    # Stays at 900s, but the ask_hermes leg inside it now runs HOURLY on its own
    # gate (ASK_HERMES_MIN_INTERVAL_S in hermes-health-check.nix). This unit also
    # carries the free checks — api_server, MCP SSE, Discord heartbeat age,
    # Qdrant memory — and slowing those to an hour to spare one LLM call would
    # have traded agent-liveness detection latency for nothing.
    intervalSeconds = 900;
  };
  services.hermesSelfHeal.enable = true;
  # The Discord round-trip canary was REMOVED 2026-07-31 together with OpenClaw. It was
  # inherently cross-agent -- the two agents probed EACH OTHER -- so it cannot outlive the
  # removal of one of them. Both probes,
  # modules/monitoring/services/discord-canary.nix, the removed Discord canary script and all 12
  # *DiscordCanary* rules went with it.
  #
  # It never reached a clean steady state either: @Claw's bot holds neither MANAGE_MESSAGES
  # nor MANAGE_THREADS in #interconnect, so every SUCCESSFUL round-trip left Hermes' reply
  # undeletable inside a thread -- 8 of 8 final runs were reply+reference green followed by
  # http 403 on both the thread delete and the message delete. Retiring it stops that
  # accumulation in a channel granted on the condition it stays clean.
  #
  # Hermes' OWN monitoring is untouched and remains: the e2e chat probe, WS-zombie
  # detection, the fallback counter and its freshness guard, and the nightly health report.
  services.hermesFallbackCounter.enable = true;

  services.home-assistant-water-attribution = {
    enable = true;
    flumeCurrentSensor = "sensor.flume_sensor_sierra_oaks_current";
    domesticHotFlowSensor = "sensor.water_heater_ch1_ch1_unit1_hot_water_flow";

    # Auto-fill valve replaced 2026-05-26 — new valve does SHORT top-offs
    # (~2-9 min bursts at 1.3-1.9 gal/min), NOT the old valve's long 30-200 min
    # fills at 3-5. So band [1.3, 1.9] + a SHORT 5-min window (4-of-5 sustained,
    # mean-checked): the conservative profile. It catches the >=5-min bursts
    # while the mean-check rejects 1-2 min toilet/sink blips that share this
    # flow band (verified against 14 days of Flume data, 2026-06-09 — w15/min14
    # caught zero because the longest real burst was 9 min). The irrigation/hot
    # guards in poolAutofillActiveBinarySensor still apply. For higher recall,
    # shorten to w3/min2 (more short-burst coverage, some false-positive cost);
    # widen the band toward [1.2, 2.0] only with care.
    autofill = {
      gpmMin = 1.3;
      gpmMax = 1.9;
      windowMinutes = 5;
      minMinutesInRange = 4;
      enforceMeanCheck = true;
    };

    cycles = [
      "daily"
      "weekly"
      "monthly"
    ];
    weekStart = "monday";
    aggregateDropToleranceGal = 5.0;

    zones = [
      {
        slug = "front_yard";
        name = "Front Yard";
        type = "spray";
      }
      {
        slug = "side_yard_right";
        name = "Side Yard (right)";
        type = "spray";
      }
      {
        slug = "back_wall";
        name = "Back Wall";
        type = "spray";
      }
      {
        slug = "around_dining_set";
        name = "Around Dining Set";
        type = "spray";
      }
      {
        slug = "along_driveway";
        name = "Along Driveway";
        type = "spray";
      }
      {
        slug = "back_of_house_and_side_yard_left";
        name = "Back of House and Side Yard (left)";
        type = "spray";
      }
      {
        slug = "drip_front_left";
        name = "Drip Front Left";
        type = "drip";
      }
      {
        slug = "drip_front_right";
        name = "Drip Front Right";
        type = "drip";
      }
      {
        slug = "planter_box";
        name = "Planter Box";
        type = "drip";
      }
      {
        slug = "zone_5";
        name = "Zone 5";
        type = null;
      }
    ];
  };

  # Phase 2/3 backend for water attribution: weekly cross-check that
  # re-derives totals from VictoriaMetrics + HA Postgres, emails a water
  # report, and writes the max-delta sensor back to HA.
  #
  # ENABLED (as of 2026-07-27 the timers are active and the weekly run exits
  # 0), so the SOPS setup below is DONE — kept as the reference list of keys
  # this module needs if the secret store is ever rebuilt:
  #   1. sops /etc/nixos/secrets/secrets.yaml and add the keys:
  #        flume:
  #          client_id: <Flume Personal API client_id>
  #          client_secret: <Flume Personal API client_secret>
  #          username: <Flume account email>
  #          password: <Flume account password>
  #        home-assistant:
  #          flume-data-token: <long-lived HA token>
  #   2. sudo nixos-rebuild switch --flake '/etc/nixos#vulcan'
  #      (this was originally staged in the /etc/nixos.worktrees/water-attribution
  #      worktree; it has since landed on the main tree)
  #
  # The Phase 1 templates + utility meters deploy independently of this
  # (gated GPM sensors, integration totals, weekly/monthly cycles).
  services.flume-data.enable = true;

  # NocoBase low-code platform, restored 2026-08-15 for evaluation (it was
  # removed 2026-03-14 in f40e2ac01). Everything is wired -- container, user,
  # database, nginx vhost, blackbox probe, certificate renewal, dashboard link.
  #
  # OFF until its two SOPS keys exist, because sops-nix fails activation for a
  # declared secret whose key is absent, which would break EVERY rebuild on this
  # host rather than just this service. Add nocobase-db-password and
  # nocobase-secrets (exact contents documented at the top of
  # modules/containers/nocobase-quadlet.nix), then flip this to true and issue
  # the certificate as described there.
  services.nocobase.enable = false;

  # This option defines the first version of NixOS you have installed on this
  # particular machine, and is used to maintain compatibility with application
  # data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for
  # any reason, even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are
  # pulled from, so changing it will NOT upgrade your system - see
  # https://nixos.org/manual/nixos/stable/#sec-upgrading for how to actually
  # do that.
  #
  # This value being lower than the current NixOS release does NOT mean your
  # system is out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the
  # changes it would make to your configuration, and migrated your data
  # accordingly.
  #
  # For more information, see `man configuration.nix` or
  # https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.11"; # Did you read the comment?

  # Allow Nix to fetch flakes from local gitea
  networking.extraHosts = "127.0.0.1 gitea";
}
