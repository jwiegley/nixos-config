{ config, lib, pkgs, ... }:

{
  sops.secrets."litellm-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "podman-litellm.service" ];
  };

  virtualisation.oci-containers.containers.litellm = {
    autoStart = true;
    image = "ghcr.io/berriai/litellm-database:main-stable";
    ports = [
      "127.0.0.1:4000:4000/tcp"
      "10.88.0.1:4000:4000/tcp"
    ];

    # Secret environment variables from SOPS
    environmentFiles = [
      config.sops.secrets."litellm-secrets".path
    ];

    volumes = [ "/etc/litellm/config.yaml:/app/config.yaml:ro" ];
    cmd = [
      "--config" "/app/config.yaml"
      # "--detailed_debug"
    ];
  };

  # Ensure proper systemd dependencies
  systemd.services."podman-litellm" = {
    after = [ "sops-nix.service" "postgresql.service" ];
    wants = [ "sops-nix.service" ];
  };
}
