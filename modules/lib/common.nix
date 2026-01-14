{ secrets, ... }:

{
  # Common paths and variables used across multiple modules
  # Import this in modules that need consistent path references

  # Path to the SOPS secrets file
  secretsPath = secrets.outPath + "/secrets.yaml";

  # Common service restart policies for reliability
  # Each policy contains both 'unit' and 'service' configurations
  # unit: Settings for systemd [Unit] section (rate limiting)
  # service: Settings for systemd [Service] section (restart behavior)
  restartPolicies = {
    # Standard restart policy for critical services
    always = {
      unit = {
        StartLimitIntervalSec = "300";
        StartLimitBurst = "5";
      };
      service = {
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # Restart policy for services that should retry on failure
    onFailure = {
      unit = {
        StartLimitIntervalSec = "600";
        StartLimitBurst = "3";
      };
      service = {
        Restart = "on-failure";
        RestartSec = "30s";
      };
    };

    # No automatic restart (for oneshot services)
    none = {
      unit = { };
      service = {
        Restart = "no";
      };
    };
  };

  # Common nginx SSL certificate paths for step-ca managed certificates
  # hostname: the subdomain (e.g., "hass" for hass.vulcan.lan)
  nginxSSLPaths = hostname: {
    sslCertificate = "/var/lib/nginx-certs/${hostname}.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/${hostname}.vulcan.lan.key";
  };

  # Common PostgreSQL settings for containers
  postgresDefaults = {
    host = "10.88.0.1"; # Podman bridge IP
    port = 5432;
  };
}
