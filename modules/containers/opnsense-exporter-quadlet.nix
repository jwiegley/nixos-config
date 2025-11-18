# OPNsense Exporter - System Configuration
#
# Quadlet container: Managed by Home Manager (see /etc/nixos/modules/users/home-manager/opnsense-exporter.nix)
# This file: SOPS secrets and firewall rules
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

{ config, lib, pkgs, secrets, ... }:

{
  # Quadlet container configuration moved to Home Manager
  # See /etc/nixos/modules/users/home-manager/opnsense-exporter.nix
  # imports = [
  #   (mkQuadletService {
  #     name = "opnsense-exporter";
  #     image = "ghcr.io/athennamind/opnsense-exporter:latest";
  #     port = 9273;
  #     requiresPostgres = false;
  #     containerUser = "opnsense-exporter";
  #     ...
  #   })
  # ];

  # SOPS secrets
  sops.secrets."opnsense-exporter-secrets" = {
    sopsFile = config.sops.defaultSopsFile;
    mode = "0400";
    owner = "opnsense-exporter";
    path = "/run/secrets-opnsense-exporter/opnsense-exporter-secrets";
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
