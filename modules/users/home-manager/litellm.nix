{ config, lib, pkgs, inputs, ... }:

{
  # Deploy harmony_filter.py from /etc/nixos/scripts to /etc/litellm
  environment.etc."litellm/harmony_filter.py" = {
    source = ../../../scripts/harmony_filter.py;
    mode = "0644";
  };

  home-manager.users.litellm = { config, lib, pkgs, ... }: {
    # Import the quadlet-nix Home Manager module
    imports = [
      inputs.quadlet-nix.homeManagerModules.quadlet
    ];
    # Home Manager state version
    home.stateVersion = "24.11";

    # Basic home settings
    home.username = "litellm";
    home.homeDirectory = "/var/lib/containers/litellm";

    # Environment for rootless container operation
    home.sessionVariables = {
      PODMAN_USERNS = "keep-id";
    };

    # Ensure home directory structure exists
    home.file.".keep".text = "";

    # Basic packages available in container user environment
    home.packages = with pkgs; [
      podman
      coreutils
      postgresql  # For pg_isready health check
    ];

    # Rootless quadlet container configuration
    virtualisation.quadlet.containers.litellm = {
      autoStart = true;

      containerConfig = {
        image = "ghcr.io/berriai/litellm-database:main-stable";
        publishPorts = [ "127.0.0.1:4000:4000/tcp" ];

        # Rootless networking with host loopback access
        networks = [ "slirp4netns:allow_host_loopback=true" ];

        # Environment configuration
        environments = {
          POSTGRES_HOST = "127.0.0.1";
          PYTHONPATH = "/app";
        };

        # Secrets via environment file
        environmentFiles = [ "/run/secrets-litellm/litellm-secrets" ];

        # Volume mounts
        volumes = [
          "/etc/litellm/config.yaml:/app/config.yaml:ro"
          "/etc/litellm/harmony_filter.py:/app/harmony_filter.py:ro"
        ];

        # Container exec command
        exec = "--config /app/config.yaml";
      };

      unitConfig = {
        After = [ "network-online.target" ];

        # Restart rate limiting
        StartLimitIntervalSec = "300";
        StartLimitBurst = "5";
      };

      serviceConfig = {
        # Wait for PostgreSQL to be ready
        ExecStartPre = "${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 30";

        # Restart policies
        Restart = "always";
        RestartSec = "10s";
        TimeoutStartSec = "900";
      };
    };
  };
}
