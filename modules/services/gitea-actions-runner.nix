{ config, lib, pkgs, ... }:

{
  # SOPS secrets for Gitea Actions Runner
  sops.secrets = {
    "gitea-runner-token" = {
      # Make readable by keys group for systemd services
      owner = "root";
      group = "keys";
      mode = "0440";
    };
    "rclone-password" = {
      owner = "root";
      group = "keys";
      mode = "0440";
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
        # TODO: Add org-jw package once build issues are resolved
      ];

      # Additional settings
      # With :host labels, jobs run directly on the host, so no container settings needed
      settings = {};
    };
  };

  # The runner service is automatically configured by the NixOS module
  # with DynamicUser=true and proper permissions

  # Allow the gitea-runner user to access the Nix daemon
  nix.settings.trusted-users = [ "gitea-runner" ];

  # Wrapper script for rclone with SOPS secret
  environment.systemPackages = [
    (pkgs.writeScriptBin "rclone-with-secret" ''
      #!${pkgs.bash}/bin/bash
      export RCLONE_PASSWORD_COMMAND="cat ${config.sops.secrets."rclone-password".path}"
      exec ${pkgs.rclone}/bin/rclone "$@"
    '')
  ];
}
