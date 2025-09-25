{ config, lib, pkgs, ... }:

{
  imports = [
    # Hardware configuration
    ./hardware-configuration.nix

    # Core modules
    ../../modules/core/boot.nix
    ../../modules/core/networking.nix
    ../../modules/core/firewall.nix
    ../../modules/core/nix.nix
    ../../modules/core/system.nix
    ../../modules/core/programs.nix

    # Security modules
    ../../modules/security/hardening.nix

    # User management
    ../../modules/users/default.nix
    ../../modules/users/johnw.nix
    ../../modules/users/assembly.nix

    # Services
    ../../modules/services/certificates.nix
    ../../modules/services/certificate-automation.nix
    ../../modules/services/databases.nix
    ../../modules/services/pgadmin.nix
    ../../modules/services/web.nix
    ../../modules/services/monitoring.nix
    ../../modules/services/prometheus-monitoring.nix
    ../../modules/services/service-reliability.nix
    ../../modules/services/network-services.nix
    ../../modules/services/postfix.nix
    ../../modules/services/dovecot.nix
    ../../modules/services/mbsync.nix
    ../../modules/services/mbsync-alerts.nix
    ../../modules/services/dns.nix

    # Containers
    ../../modules/containers/default.nix

    # Storage
    ../../modules/storage/zfs.nix
    ../../modules/storage/backups.nix
    ../../modules/storage/backup-monitoring.nix

    # Maintenance
    ../../modules/maintenance/timers.nix

    # Packages
    ../../modules/packages/custom.nix
    ../../modules/packages/zsh.nix
  ];

  # This value determines the NixOS release from which the default settings
  # for stateful data, like file locations and database versions on your
  # system were taken. It's perfectly fine and recommended to leave this value
  # at the release version of the first install of this system. Before
  # changing this value read the documentation for this option (e.g. man
  # configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}
