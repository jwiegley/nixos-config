{ config, lib, pkgs, ... }:

let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
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

  imports = [
    (mkQuadletService {
      name = "technitium-dns-exporter";
      # Use locally-built image (build instructions in setup doc)
      # Image must be built with: cd /tmp && git clone https://github.com/brioche-works/technitium-dns-prometheus-exporter.git && cd technitium-dns-prometheus-exporter && sudo podman build -t localhost/technitium-dns-exporter:latest .
      image = "localhost/technitium-dns-exporter:latest";
      port = 9274;
      requiresPostgres = false;

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
