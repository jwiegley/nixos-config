{ config, lib, pkgs, secrets, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs secrets; };
  inherit (mkQuadletLib) mkQuadletService;
in
{
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
    deps = [];
  };

  imports = [
    (mkQuadletService {
      name = "technitium-dns-exporter";
      # Use locally-built image (auto-built at activation if missing)
      image = "localhost/technitium-dns-exporter:latest";
      port = 9274;
      requiresPostgres = false;
      containerUser = "technitium-dns-exporter";  # Run rootless as dedicated technitium-dns-exporter user

      # Enable health checks
      healthCheck = {
        enable = true;
        type = "exec";
        interval = "30s";
        timeout = "10s";
        startPeriod = "30s";
        retries = 3;
        execCommand = "wget --spider -q http://localhost:8080/metrics || exit 1";
      };
      enableWatchdog = false;  # Disabled - requires sdnotify

      # Bind to localhost only for Prometheus scraping
      publishPorts = [
        "127.0.0.1:9274:8080/tcp"
      ];

      secrets = {
        technitiumDnsEnv = "technitium-dns-exporter-env";
      };

      # Container runs on port 8080 internally
      exec = "--log.level=info --log.format=json";

      # No nginx virtual host for this exporter (Prometheus scrapes directly)
      nginxVirtualHost = null;

      # Wait for Technitium DNS Server
      extraUnitConfig = {
        After = [ "technitium-dns-server.service" ];
        Wants = [ "technitium-dns-server.service" ];
      };
    })
  ];

  # Open firewall port on localhost for Prometheus access
  networking.firewall.interfaces = {
    "lo".allowedTCPPorts = [
      9274  # technitium-dns-exporter
    ];
  };
}
