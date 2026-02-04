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

    # Options
    ../../modules/options

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
    ../../modules/monitoring/aide-nagios-check.nix

    # User management
    ../../modules/users/johnw.nix
    ../../modules/users/nasimw.nix
    ../../modules/users/assembly.nix
    ../../modules/users/container-users-dedicated.nix
    ../../modules/users/home-manager
    ../../modules/users/home-manager/johnw.nix
    ../../modules/users/home-manager/container-users-dedicated.nix

    # Rootless container Home Manager configs
    ../../modules/users/home-manager/litellm.nix
    ../../modules/users/home-manager/changedetection.nix
    ../../modules/users/home-manager/mailarchiver.nix
    ../../modules/users/home-manager/nocobase.nix
    ../../modules/users/home-manager/open-webui.nix
    ../../modules/users/home-manager/openproject.nix
    ../../modules/users/home-manager/shlink.nix
    ../../modules/users/home-manager/shlink-web-client.nix
    ../../modules/users/home-manager/teable.nix
    ../../modules/users/home-manager/wallabag.nix
    ../../modules/users/home-manager/sillytavern.nix
    ../../modules/users/home-manager/opnsense-exporter.nix
    # technitium-dns-exporter: Reverted to system-level container (uses localhost image)
    ../../modules/users/home-manager/openspeedtest.nix
    ../../modules/users/home-manager/lastsignal.nix

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
    ../../modules/services/dovecot.nix
    ../../modules/services/gitea-actions-runner.nix
    ../../modules/services/gitea.nix
    ../../modules/services/github-gitea-mirror.nix
    ../../modules/services/grafana.nix
    ../../modules/services/home-assistant-metric-trick.nix
    ../../modules/services/home-assistant.nix
    ../../modules/services/immich.nix
    ../../modules/services/jupyterlab.nix
    ../../modules/services/local-backup.nix
    ../../modules/services/loki.nix
    ../../modules/services/media.nix
    ../../modules/services/monitoring.nix
    ../../modules/services/mosquitto.nix
    ../../modules/services/n8n.nix
    ../../modules/services/nagios.nix
    ../../modules/services/network-services.nix
    ../../modules/services/nginx-n8n-webhook.nix
    ../../modules/services/node-red.nix
    ../../modules/services/ntopng.nix
    ../../modules/services/pgadmin.nix
    ../../modules/services/postfix.nix
    ../../modules/services/postgresql-backup.nix
    ../../modules/services/promtail.nix
    ../../modules/services/rspamd-alerts.nix
    ../../modules/services/rspamd.nix
    ../../modules/services/service-reliability.nix
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
    ../../modules/services/mbsync-alerts.nix
    ../../modules/services/fetchmail.nix
    ../../modules/services/fetchmail-alerts.nix
    ../../modules/services/radicale.nix
    ../../modules/services/vdirsyncer.nix
    ../../modules/services/vdirsyncer-alerts.nix
    ../../modules/services/dns.nix
    ../../modules/services/glance.nix
    ../../modules/services/glances.nix
    ../../modules/services/searxng.nix
    ../../modules/monitoring/services/copyparty-exporter.nix
    ../../modules/services/cockpit.nix
    ../../modules/services/llama-swap.nix
    ../../modules/services/aria2.nix
    ../../modules/services/atd.nix
    ../../modules/services/atd-web.nix
    ../../modules/services/atd-nginx.nix
    ../../modules/monitoring/services/atd-exporter.nix
    ../../modules/monitoring/services/atd-alerts.nix
    ../../modules/monitoring/services/atd-nagios.nix
    ../../modules/services/zimit.nix

    # Containers
    ../../modules/containers/default.nix
    ../../modules/containers/openproject-quadlet.nix
    ../../modules/containers/teable-quadlet.nix
    ../../modules/containers/windows11-quadlet.nix

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
}
