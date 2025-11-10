{ inputs, config, lib, pkgs, ... }:

{
  # Create a static gitea-runner user and add to keys group
  users.users.gitea-runner = {
    isSystemUser = true;
    group = "gitea-runner";
    extraGroups = [ "keys" ];
  };
  users.groups.gitea-runner = {};

  # SOPS secrets for Gitea Actions Runner
  sops.secrets = {
    "gitea-runner-token" = {
      # Make readable by keys group for systemd services
      owner = "root";
      group = "keys";
      mode = "0440";
    };
    "rclone-config" = {
      owner = "root";
      group = "keys";
      mode = "0440";  # Restricted to root and keys group (gitea-runner is a member)
    };
  };

  # Configure Gitea Actions Runner
  services.gitea-actions-runner = {
    package = pkgs.gitea-actions-runner;

    instances.org-builder = {
      enable = true;
      name = "org-builder";
      url = "https://gitea.vulcan.lan";
      tokenFile = config.sops.secrets."gitea-runner-token".path;

      # Labels for this runner
      labels = [
        "nixos:host"
        "org-builder:host"
      ];

      # Packages available to actions
      hostPackages = with pkgs; [
        bash
        coreutils
        curl
        diffutils  # Provides diff command
        git
        gnugrep
        gnused
        gnutar
        gzip
        nix
        nodejs  # Required for actions/checkout and other GitHub Actions
        rclone
        stdenv.cc
        which
        yuicompressor  # Required for org-jw CSS/JS minification
        inputs.org-jw.packages.${system}.default
      ];

      # Additional settings
      # With :host labels, jobs run directly on the host, so no container settings needed
      settings = {};
    };
  };

  # Allow the gitea-runner user to access the Nix daemon
  nix.settings.trusted-users = [ "gitea-runner" ];
}
