{ config, lib, pkgs, ... }:

{
  imports = [
    # Hardware configuration
    ./hardware-configuration.nix

    # Options
    ../../modules/options

    # Core modules
    ../../modules/core/boot.nix
    ../../modules/core/hardware.nix
    ../../modules/core/networking.nix
    ../../modules/core/nm-ignore-dhcp-dns.nix
    ../../modules/core/wifi.nix
    ../../modules/core/firewall.nix
    ../../modules/core/nix.nix
    ../../modules/core/system.nix
    ../../modules/core/programs.nix

    # Security modules
    ../../modules/security/hardening.nix

    # User management
    ../../modules/users/johnw.nix
    ../../modules/users/assembly.nix
    ../../modules/users/home-manager
    ../../modules/users/home-manager/johnw.nix

    # Services
    ../../modules/services/certificates.nix
    ../../modules/services/certificate-automation.nix
    ../../modules/services/databases.nix
    ../../modules/services/postgresql-backup.nix
    ../../modules/services/local-backup.nix
    ../../modules/services/pgadmin.nix
    ../../modules/services/web.nix
    ../../modules/services/media.nix
    ../../modules/services/monitoring.nix
    ../../modules/services/prometheus-monitoring.nix
    ../../modules/services/blackbox-monitoring.nix
    ../../modules/services/alertmanager.nix
    ../../modules/services/nagios.nix
    ../../modules/monitoring/homeassistant-nagios-check.nix
    ../../modules/monitoring/nagios-daily-report.nix
    ../../modules/monitoring/mrtg.nix
    ../../modules/monitoring/mrtg-config.nix
    ../../modules/monitoring/container-health-exporter.nix
    ../../modules/services/service-reliability.nix
    ../../modules/services/network-services.nix
    ../../modules/services/home-assistant.nix
    ../../modules/services/home-assistant-metric-trick.nix
    ../../modules/services/mosquitto.nix
    ../../modules/services/node-red.nix
    ../../modules/services/grafana.nix
    ../../modules/services/loki.nix
    ../../modules/services/promtail.nix
    ../../modules/monitoring/services/victoriametrics.nix
    ../../modules/services/postfix.nix
    ../../modules/services/dovecot.nix
    ../../modules/services/imapdedup.nix
    ../../modules/services/mbsync.nix
    ../../modules/services/dns.nix
    ../../modules/services/glance.nix
    ../../modules/services/cockpit.nix
    ../../modules/services/llama-swap.nix

    # Containers
    ../../modules/containers/default.nix
    ../../modules/containers/teable-quadlet.nix

    # Maintenance
    ../../modules/maintenance/timers.nix

    # Packages
    ../../modules/packages/custom.nix
    ../../modules/packages/zsh.nix

    # Storage
    ../../modules/services/nextcloud.nix
    ../../modules/storage/zfs.nix
    ../../modules/storage/hd-idle.nix
    ../../modules/storage/backups.nix
    ../../modules/storage/backup-monitoring.nix
    ../../modules/services/samba.nix
  ];

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
