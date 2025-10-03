{ config, lib, pkgs, ... }:

{
  # OPNsense Exporter container configuration
  #
  # NOTE: Using an nginx proxy to transform API responses as a workaround
  # for a known issue with the gateway collector in v0.0.11:
  # - Issue: https://github.com/AthennaMind/opnsense-exporter/issues/70
  # - The gateway collector fails with "json: cannot unmarshal bool into Go struct field .rows.monitor_disable of type string"
  # - The proxy (opnsense-api-proxy.nix) transforms boolean monitor_disable to string
  #
  # TO REMOVE THIS WORKAROUND when a fixed version is released:
  #   1. Remove opnsense-api-proxy.nix and its import from quadlet.nix
  #   2. Change OPNSENSE_EXPORTER_OPS_API back to "192.168.1.1"
  #   3. Change OPNSENSE_EXPORTER_OPS_PROTOCOL back to "https"
  #   4. Set OPNSENSE_EXPORTER_OPS_INSECURE back to "false"
  #   5. Re-enable the volume mounts for CA certificates
  #   6. Re-enable SSL_CERT_FILE environment variable
  virtualisation.quadlet.containers.opnsense-exporter = {
    containerConfig = {
      image = "ghcr.io/athennamind/opnsense-exporter:latest";
      # Bind to localhost for Prometheus scraping
      publishPorts = [
        "127.0.0.1:9273:8080/tcp"
      ];
      # Environment file containing OPNSENSE_EXPORTER_OPS_API_KEY and OPNSENSE_EXPORTER_OPS_API_SECRET
      environmentFiles = [ config.sops.secrets."opnsense-exporter-secrets".path ];
      environments = {
        OPNSENSE_EXPORTER_OPS_PROTOCOL = "http";  # Proxy uses HTTP internally
        OPNSENSE_EXPORTER_OPS_API = "10.88.0.1:8444";  # Point to nginx proxy on podman0 bridge
        OPNSENSE_EXPORTER_OPS_INSECURE = "true";  # No TLS to proxy
        OPNSENSE_EXPORTER_INSTANCE_LABEL = "opnsense-router";
        # Disable SSL cert since we're using insecure mode
        # SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      };
      # Volumes disabled since we're using insecure mode as a workaround for gateway collector issue
      # volumes = [
      #   "/var/lib/opnsense-exporter-ca.crt:/usr/local/share/ca-certificates/opnsense-ca.crt:ro"
      #   "/var/lib/opnsense-exporter-ca.crt:/etc/ssl/certs/ca-certificates.crt:ro"
      # ];
      # Command line arguments for the exporter
      exec = "--log.level=info --log.format=json --web.listen-address=:8080";
      networks = [ "podman" ];
      autoUpdate = "registry";
    };
    unitConfig = {
      After = [ "sops-nix.service" "network-online.target" "ensure-podman-network.service" "opnsense-api-transformer.service" ];
      Wants = [ "sops-nix.service" "network-online.target" "ensure-podman-network.service" "opnsense-api-transformer.service" ];
    };
    serviceConfig = {
      # Restart policy
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # SOPS secret for OPNsense exporter credentials
  sops.secrets."opnsense-exporter-secrets" = {
    sopsFile = ../../secrets.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "opnsense-exporter.service" ];
  };

  # Open firewall port on podman0 interface for container access
  networking.firewall.interfaces = {
    "lo".allowedTCPPorts = [
      9273  # opnsense-exporter
    ];
    podman0.allowedTCPPorts = [
      9273  # opnsense-exporter
    ];
  };
}
