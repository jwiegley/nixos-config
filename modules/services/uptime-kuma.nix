{ config, lib, pkgs, ... }:

{
  services.uptime-kuma = {
    enable = true;

    # Enable apprise support for additional notification options
    appriseSupport = true;

    # Additional environment variables and settings
    settings = {
      # Port configuration (default is 3001)
      PORT = "3001";

      # Host binding - only localhost since we'll use nginx
      HOST = "127.0.0.1";

      # Data directory will use default /var/lib/uptime-kuma
      # which is managed by the NixOS module

      # Enable additional CA certificates for monitoring internal services
      NODE_EXTRA_CA_CERTS = "/var/lib/step-ca/certs/root_ca.crt";

      # Disable telemetry
      UPTIME_KUMA_DISABLE_TELEMETRY = "1";
    };
  };

  # Ensure the service starts after network and certificates are available
  systemd.services.uptime-kuma = {
    after = [ "network-online.target" "step-ca.service" ];
    wants = [ "network-online.target" ];
  };
}