{ config, lib, pkgs, ... }:

{
  # OPNsense Exporter container configuration
  #
  # NOTE: Currently using insecure mode (OPNSENSE_EXPORTER_OPS_INSECURE = "true") as a workaround
  # for a known issue with the gateway collector in v0.0.11:
  # - Issue: https://github.com/AthennaMind/opnsense-exporter/issues/70
  # - The gateway collector fails with "json: cannot unmarshal bool into Go struct field .rows.monitor_disable of type string"
  # - PR #79 (https://github.com/AthennaMind/opnsense-exporter/pull/79) has a fix but is not yet merged
  # - Once a new version with the fix is released, we should:
  #   1. Update to the new version
  #   2. Set OPNSENSE_EXPORTER_OPS_INSECURE back to "false"
  #   3. Re-enable the volume mounts for CA certificates
  #   4. Re-enable SSL_CERT_FILE environment variable
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
        OPNSENSE_EXPORTER_OPS_PROTOCOL = "https";
        OPNSENSE_EXPORTER_OPS_API = "192.168.1.1";
        OPNSENSE_EXPORTER_OPS_INSECURE = "true";  # Set to true to skip TLS verification as a workaround
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
      After = [ "sops-nix.service" "network-online.target" "ensure-podman-network.service" ];
      Wants = [ "sops-nix.service" "network-online.target" "ensure-podman-network.service" ];
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
