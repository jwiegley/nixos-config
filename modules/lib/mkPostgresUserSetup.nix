{ config, lib, pkgs, ... }:

{
  # Creates a systemd service to set PostgreSQL user password from SOPS secret
  #
  # Usage:
  #   imports = [
  #     (mkPostgresUserSetup {
  #       user = "nextcloud";
  #       database = "nextcloud";
  #       secretPath = config.sops.secrets."nextcloud-db-password".path;
  #       dependentService = "nextcloud-setup.service";
  #     })
  #   ];
  #
  # Parameters:
  #   - user: PostgreSQL username to set password for
  #   - database: Database name for connection test
  #   - secretPath: Path to SOPS secret containing password
  #   - dependentService: Optional service that depends on this setup (e.g., "nextcloud-setup.service")

  mkPostgresUserSetup = {
    user,
    database,
    secretPath,
    dependentService ? null
  }: {
    systemd.services."postgresql-${user}-setup" = {
      description = "Set PostgreSQL password for ${user} user";
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
      before = lib.optional (dependentService != null) dependentService;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
      };

      script = ''
        # Check if password is already set by trying to connect
        if ! ${config.services.postgresql.package}/bin/psql -U ${user} -d ${database} -c "SELECT 1" 2>/dev/null; then
          # Set the password from the SOPS secret file
          ${config.services.postgresql.package}/bin/psql -c "ALTER USER ${user} WITH PASSWORD '$(cat ${secretPath})'"
        fi
      '';
    };
  };
}
