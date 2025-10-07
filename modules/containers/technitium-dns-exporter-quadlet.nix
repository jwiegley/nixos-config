{ config, lib, pkgs, ... }:

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
  virtualisation.quadlet.containers.technitium-dns-exporter = {
    containerConfig = {
      # Use locally-built image (build instructions in setup doc)
      # Image must be built with: cd /tmp && git clone https://github.com/brioche-works/technitium-dns-prometheus-exporter.git && cd technitium-dns-prometheus-exporter && sudo podman build -t localhost/technitium-dns-exporter:latest .
      image = "localhost/technitium-dns-exporter:latest";

      # Bind to localhost only for Prometheus scraping
      publishPorts = [
        "127.0.0.1:9274:8080/tcp"
      ];

      # Environment file containing API credentials
      environmentFiles = [ config.sops.secrets."technitium-dns-exporter-env".path ];

      # Container runs on port 8080 internally
      exec = "--log.level=info --log.format=json";

      # Connect to default podman network
      networks = [ "podman" ];
    };

    unitConfig = {
      # Ensure dependencies are ready
      After = [ "sops-nix.service" "network-online.target" "podman.service" "technitium-dns-server.service" ];
      Wants = [ "sops-nix.service" "network-online.target" "technitium-dns-server.service" ];
    };

    serviceConfig = {
      # Restart policy
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # SOPS secret for Technitium DNS exporter credentials
  # Format of the environment file:
  # TECHNITIUM_API_DNS_BASE_URL=http://127.0.0.1:5380
  # TECHNITIUM_API_DNS_TOKEN=your_api_token_here
  # TECHNITIUM_API_DNS_LABEL=vulcan-dns
  sops.secrets."technitium-dns-exporter-env" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "technitium-dns-exporter.service" ];
  };

  # Open firewall port on localhost for Prometheus access
  networking.firewall.interfaces = {
    "lo".allowedTCPPorts = [
      9274  # technitium-dns-exporter
    ];
  };
}
