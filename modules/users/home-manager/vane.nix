{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  home-manager.users.vane =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];

      home.stateVersion = "24.11";
      home.username = "vane";
      home.homeDirectory = "/var/lib/containers/vane";

      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      home.file.".keep".text = "";

      home.packages = with pkgs; [
        podman
        coreutils
      ];

      # Rootless quadlet container using host networking for SearXNG access
      virtualisation.quadlet.containers.vane = {
        autoStart = true;

        containerConfig = {
          # Use slim image (no bundled SearXNG — we use the existing instance)
          image = "itzcrazykns1337/vane:slim-latest";

          # Host networking allows direct access to host's localhost services
          # (SearXNG at 127.0.0.1:8890, etc.)
          networks = [ "host" ];

          environments = {
            # Bind to localhost only (host network mode)
            HOSTNAME = "127.0.0.1";
            PORT = "3007";

            # Point to the existing SearXNG instance
            SEARXNG_API_URL = "http://127.0.0.1:8890";

            # Data directory inside container (maps to our volume)
            DATA_DIR = "/home/vane";

            # Trust local Step-CA for outbound HTTPS verification
            NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/vulcan-ca.crt";
          };

          # Persistent data volumes
          volumes = [
            "/var/lib/vane/data:/home/vane/data:rw"
            "/var/lib/vane/uploads:/home/vane/uploads:rw"
            # Mount Step-CA root certificate for HTTPS connections to local services
            "/etc/ssl/certs/vulcan-ca.crt:/etc/ssl/certs/vulcan-ca.crt:ro"
          ];
        };

        unitConfig = {
          After = [
            "network-online.target"
            "sops-nix.service"
          ];
          Wants = [ "sops-nix.service" ];
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          Restart = "always";
          RestartSec = "15s";
          TimeoutStartSec = "300";
        };
      };
    };
}
