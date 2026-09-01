{ userPkgs, utils }:

# Application modules for vulcan.
#
# EVERY module here gets the ordinary module-system `pkgs` -- inputs.nixpkgs,
# the STABLE nixos-25.11 pin -- unless it is named in `needsUserPkgs` below.
#
# WHY THE DEFAULT IS STABLE. `userPkgs` is built from inputs.nixpkgs-user, which
# follows nix-config-ai/nixpkgs = github:NixOS/nixpkgs/nixpkgs-unstable. Handing
# it to a module swaps the whole BASE package set for that module, not just the
# AI tooling. Between 2026-08-31 and 2026-09-01 this file wrapped all 89 modules
# with `pkgs = userPkgs`, which moved 45 of the ~54 packages they reference off
# the stable pin -- glibc 2.40->2.42, systemd 258.7->261.2, zfs 2.3.7->2.4.4,
# postgresql 17.10->18.6, python3 3.13->3.14, step-ca, samba, openssh. The NixOS
# modules themselves still come from stable, so each of those is a
# module/package version mix. Two of them broke on contact (nixos-7bp):
#
#   * dovecot: this repo's dovecot.nix hardcodes ${pkgs.dovecot_pigeonhole}/bin/sievec
#     in systemd.services.dovecot.preStart. Unstable's pigeonhole 2.4.5 against the
#     stable module's 2.3-style config aborts with "Module is for different ABI
#     version 2.3.ABIv21(2.3.21.1) (we have 2.4.ABIv5)" -- a 30-minute mail outage
#     with 44 messages queued, generation 2611.
#   * gitea-actions-runner: stable ships 0.2.13 with bin/act_runner, exactly what
#     the stable module hardcodes. Unstable's 3.1.0 renamed it to bin/gitea-runner,
#     so the unit died 203/EXEC and took the whole switch to exit 4.
#
# WHY AN ALLOWLIST COSTS NOTHING. nixpkgs.overlays on the nixosConfiguration
# (flake.nix:321-329) already applies nix-config-ai.overlays.default and .tools,
# so the plain module-system pkgs ALREADY carries all 100 overlay attributes
# (84 + 16). Routing through userPkgs adds no package that is otherwise missing;
# it only changes the base. Confirmed by scanning all 89 modules: none references
# an overlay-only attribute through `pkgs.`.
#
# BEFORE ADDING AN ENTRY HERE, demonstrate the need: build the module's package
# against the stable set and show that it fails. Packages that merely differ in
# store path are NOT evidence -- everything differs, because unstable rebuilds
# against its own stdenv. Verified to build fine on stable and therefore
# deliberately absent: stock-trader (incl. the locally packaged pandas-ta on
# python 3.13), hermes-mcp, qdrant, vane, home-assistant. home-assistant is a
# useful reference for the RIGHT pattern -- overlays/default.nix:524 takes it from
# the dedicated inputs.nixpkgs-unstable pin, so exactly one package moves instead
# of a module's whole base.
let
  needsUserPkgs = [
  ];

  # `pkgs` is named in the formal pattern deliberately. The module system only
  # supplies a module argument when the function declares it (lib.functionArgs),
  # so a bare `args:` wrapper receives no `pkgs` at all. That went unnoticed while
  # this file always set `pkgs = userPkgs` itself -- the override masked the gap.
  # Now that the common path forwards the module-system pkgs, it has to be asked
  # for by name or every module downstream fails with "called without required
  # argument 'pkgs'".
  mkModule =
    path:
    args@{ pkgs, ... }:
    import path (
      args
      // {
        inherit utils;
      }
      // (if builtins.elem path needsUserPkgs then { pkgs = userPkgs; } else { })
    );
in
map mkModule [
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
  ../../modules/monitoring/container-health-exporter.nix
  ../../modules/monitoring/services
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
  ../../modules/services/voice-assistant.nix
  ../../modules/services/samba.nix
  ../../modules/containers/default.nix
  ../../modules/containers/matter-server-quadlet.nix
  ../../modules/containers/openproject-quadlet.nix
]
