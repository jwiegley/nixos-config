{ ... }:

{
  # Common paths and variables used across multiple modules
  # Import this in modules that need consistent path references

  # Path to the SOPS secrets file
  # Use this instead of hardcoding ../../secrets.yaml or ../../../secrets.yaml
  secretsPath = ../../secrets.yaml;

  # Common service restart policies for reliability
  # Use these in systemd.services.*.serviceConfig
  restartPolicies = {
    # Standard restart policy for critical services
    always = {
      Restart = "always";
      RestartSec = "10s";
      StartLimitIntervalSec = "300";
      StartLimitBurst = "5";
    };

    # Restart policy for services that should retry on failure
    onFailure = {
      Restart = "on-failure";
      RestartSec = "30s";
      StartLimitIntervalSec = "600";
      StartLimitBurst = "3";
    };

    # No automatic restart (for oneshot services)
    none = {
      Restart = "no";
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
