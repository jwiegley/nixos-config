{ config, lib, pkgs, ... }:

{
  services.pgadmin = {
    enable = true;
    port = 5050;
    initialEmail = "johnw@newartisans.com";
    initialPasswordFile = config.sops.secrets."pgadmin-password".path;

    settings = {
      # Allow pgAdmin to run behind a reverse proxy
      PROXY_X_FOR_COUNT = 1;
      PROXY_X_PROTO_COUNT = 1;
      PROXY_X_HOST_COUNT = 1;
      PROXY_X_PORT_COUNT = 1;
      PROXY_X_PREFIX_COUNT = 0;

      # Server mode settings
      SERVER_MODE = true;

      # Session settings
      SESSION_COOKIE_SECURE = true;
      SESSION_COOKIE_SAMESITE = "Lax";

      # Security settings
      ENHANCED_COOKIE_PROTECTION = true;

      # Log settings
      LOG_LEVEL = 20; # INFO level
    };
  };

  # SOPS secret configuration for pgAdmin password
  sops.secrets."pgadmin-password" = {
    sopsFile = ../../secrets.yaml;
    owner = "pgadmin";
    group = "pgadmin";
    mode = "0400";
  };

  # Ensure pgAdmin starts after PostgreSQL and SOPS
  systemd.services.pgadmin = {
    after = [ "postgresql.service" "sops-install-secrets.service" ];
    wants = [ "postgresql.service" "sops-install-secrets.service" ];
  };
}