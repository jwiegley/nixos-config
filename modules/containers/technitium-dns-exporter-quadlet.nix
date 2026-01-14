# Technitium DNS Exporter - System Configuration
#
# NOTE: This container runs as a system-level container (not rootless) because it uses
# a locally-built image (localhost/technitium-dns-exporter:latest) which cannot be
# easily shared with rootless user containers. Locally-built images are stored in the
# root user's image store and would need to be rebuilt for each user.
#
# Technitium DNS Prometheus Exporter container configuration
#
# This exporter collects DNS metrics from Technitium DNS Server including:
# - Query rates and types (A, AAAA, MX, etc.)
# - Response codes (NOERROR, NXDOMAIN, SERVFAIL, etc.)
# - Cache hit/miss statistics
# - Query latency metrics
# - Blocking statistics
#
# GitHub: https://github.com/brioche-works/technitium-dns-prometheus-exporter

{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix {
    inherit
      config
      lib
      pkgs
      secrets
      ;
  };
  inherit (mkQuadletLib) mkQuadletService;
in
{
  imports = [
    (mkQuadletService {
      name = "technitium-dns-exporter";
      image = "localhost/technitium-dns-exporter:latest";
      port = 9274;
      requiresPostgres = false;

      # Run as system container due to localhost image
      # containerUser = null;  # System-level container

      publishPorts = [ "127.0.0.1:9274:8080/tcp" ];

      secrets = {
        technitiumEnv = "technitium-dns-exporter-env";
      };

      exec = "--log.level=info --log.format=json";

      extraUnitConfig = {
        After = [ "technitium-dns-server.service" ];
        Wants = [ "technitium-dns-server.service" ];
      };

      healthCheck = {
        enable = false;
      };
      enableWatchdog = false;
    })
  ];

  # Automatically build the container image if it doesn't exist
  system.activationScripts.technitium-dns-exporter-image = {
    text = ''
      # Check if the container image exists
      if ! ${pkgs.podman}/bin/podman image exists localhost/technitium-dns-exporter:latest; then
        echo "Building technitium-dns-exporter container image..."

        # Create temporary directory for build
        BUILD_DIR=$(${pkgs.coreutils}/bin/mktemp -d)
        cd "$BUILD_DIR"

        # Clone the repository
        ${pkgs.git}/bin/git clone https://github.com/brioche-works/technitium-dns-prometheus-exporter.git
        cd technitium-dns-prometheus-exporter

        # Build the container image
        ${pkgs.podman}/bin/podman build -t localhost/technitium-dns-exporter:latest .

        # Clean up
        cd /
        ${pkgs.coreutils}/bin/rm -rf "$BUILD_DIR"

        echo "technitium-dns-exporter image built successfully"
      else
        echo "technitium-dns-exporter image already exists"
      fi
    '';
    deps = [ ];
  };

  # Note: SOPS secrets automatically configured by mkQuadletService
  # Note: Firewall rules automatically configured by mkQuadletService
}
