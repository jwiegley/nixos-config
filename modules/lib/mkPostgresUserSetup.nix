{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Creates a systemd service to set PostgreSQL user password from SOPS secret
  #
  # Usage:
  #   imports = [
  #     (mkPostgresUserSetup {
  #       user = "johnw";
  #       database = "johnw";
  #       secretPath = config.sops.secrets."johnw-db-password".path;
  #       dependentService = "johnw-setup.service";
  #     })
  #   ];
  #
  # Parameters:
  #   - user: PostgreSQL username to set password for
  #   - database: Database name for connection test
  #   - secretPath: Path to SOPS secret containing password
  #   - dependentService: Optional service that depends on this setup
  #     (e.g., "johnw-setup.service")

  mkPostgresUserSetup =
    {
      user,
      database,
      secretPath,
      dependentService ? null,
    }:
    {
      systemd.services."postgresql-${user}-setup" = {
        description = "Set PostgreSQL password for ${user} user";

        # Ensure PostgreSQL is fully ready before attempting connection.
        #
        # postgresql-setup.service is ordered here too, and that is load-bearing
        # rather than defensive: postgresql.service only starts the SERVER, while
        # `services.postgresql.ensureUsers` / `ensureDatabases` are applied by
        # postgresql-setup.service (its generated script issues the CREATE USER /
        # CREATE DATABASE / ALTER DATABASE ... OWNER TO statements). Without this
        # ordering the ALTER USER below can run before the role exists.
        #
        # That is not hypothetical: enabling NocoBase on 2026-08-16 produced
        # `ERROR: role "nocobase" does not exist` from this very unit, failing
        # switch-to-configuration with exit 4, because it raced ahead of
        # postgresql-setup. Every other consumer of this helper was unaffected
        # only because its role already existed from an earlier boot -- so the
        # race was latent for every one of them and would surface on any host
        # rebuild that introduces a new database user.
        after = [
          "postgresql.service"
          "postgresql-setup.service"
          "network.target"
        ];
        wants = [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        before = lib.optional (dependentService != null) dependentService;
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          RemainAfterExit = true;
          # Don't fail if password is already set
          SuccessExitStatus = "0 2";
          # Use systemd LoadCredential to securely load the secret
          # This creates an isolated copy at $CREDENTIALS_DIRECTORY/db-password
          # that the postgres user can read, regardless of the source file ownership
          LoadCredential = "db-password:${secretPath}";
        };

        # Wait for PostgreSQL to be ready before attempting to set password
        preStart = ''
          # Wait for PostgreSQL to be ready (up to 30 seconds)
          for i in {1..30}; do
            if ${config.services.postgresql.package}/bin/pg_isready -U postgres >/dev/null 2>&1; then
              echo "PostgreSQL is ready"
              break
            fi
            echo "Waiting for PostgreSQL to be ready... ($i/30)"
            sleep 1
          done
        '';

        script = ''
          # Check if password is already set by trying to connect
          if ! ${config.services.postgresql.package}/bin/psql -U ${user} -d ${database} -c "SELECT 1" 2>/dev/null; then
            # Set the password from the systemd credentials directory
            # LoadCredential creates an isolated copy that this service can read
            ${config.services.postgresql.package}/bin/psql -c "ALTER USER ${user} WITH PASSWORD '$(cat $CREDENTIALS_DIRECTORY/db-password)'"
          fi
        '';
      };
    };
}
