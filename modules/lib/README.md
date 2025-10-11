# NixOS Configuration Library Functions

This directory contains reusable helper functions to reduce boilerplate and standardize patterns across the configuration.

## Available Functions

### `common.nix` - Shared Variables and Constants

Import with: `common = import ../lib/common.nix { };`

Provides:
- `secretsPath` - Consistent path to `secrets.yaml` (use instead of `../../secrets.yaml`)
- `restartPolicies` - Standard systemd restart configurations (each contains `unit` and `service` sections)
  - `restartPolicies.always.unit` - Rate limiting for [Unit] section (StartLimitIntervalSec, StartLimitBurst)
  - `restartPolicies.always.service` - Restart behavior for [Service] section (Restart, RestartSec)
  - `restartPolicies.onFailure.{unit,service}` - Restart only on failure
  - `restartPolicies.none.{unit,service}` - No automatic restart
- `nginxSSLPaths hostname` - Standard step-ca certificate paths
- `postgresDefaults` - Common PostgreSQL connection settings

Example:
```nix
let
  common = import ../lib/common.nix { };
in
{
  sops.secrets."my-secret" = {
    sopsFile = common.secretsPath;  # Instead of ../../secrets.yaml
  };

  services.nginx.virtualHosts."myapp.vulcan.lan" =
    common.nginxSSLPaths "myapp" // {
      locations."/".proxyPass = "http://localhost:8080";
    };
}
```

### `mkPostgresUserSetup.nix` - PostgreSQL User Password Setup

Import with:
```nix
let
  mkPostgresLib = import ../lib/mkPostgresUserSetup.nix { inherit config lib pkgs; };
  inherit (mkPostgresLib) mkPostgresUserSetup;
in
```

Creates a systemd service that sets PostgreSQL user passwords from SOPS secrets.

Example:
```nix
imports = [
  (mkPostgresUserSetup {
    user = "myapp";
    database = "myapp";
    secretPath = config.sops.secrets."myapp-db-password".path;
    dependentService = "myapp.service";  # Optional
  })
];
```

**Replaces this pattern:**
```nix
systemd.services.postgresql-myapp-setup = {
  description = "Set PostgreSQL password for myapp";
  after = [ "postgresql.service" ];
  wants = [ "postgresql.service" ];
  before = [ "myapp.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = { ... };
  script = ''
    if ! psql ...; then
      psql -c "ALTER USER myapp WITH PASSWORD '$(cat ...)'"
    fi
  '';
};
```

### `mkQuadletService.nix` - Podman Quadlet Container Helper

Import with:
```nix
let
  mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
  inherit (mkQuadletLib) mkQuadletService;
in
```

Creates a complete Podman quadlet container configuration with:
- Standard restart policies
- PostgreSQL dependency checks (optional)
- SOPS secrets management
- Nginx reverse proxy (optional)
- Tmpfiles.d rules

Example:
```nix
imports = [
  (mkQuadletService {
    name = "myapp";
    image = "docker.io/myapp:latest";
    port = 8080;
    requiresPostgres = true;  # Adds pg_isready check

    secrets = {
      appPassword = "myapp-secrets";  # References sops secret key
    };

    environments = {
      DATABASE_HOST = "10.88.0.1";
      DATABASE_NAME = "myapp";
    };

    nginxVirtualHost = {
      enable = true;
      proxyPass = "http://127.0.0.1:8080/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
      '';
    };

    tmpfilesRules = [
      "d /etc/myapp 0755 root root -"
    ];
  })
];
```

**Replaces ~50 lines of boilerplate:**
- `virtualisation.quadlet.containers.myapp`
- `unitConfig` with After/Wants/Requires
- `serviceConfig` with ExecStartPre, Restart policies
- `sops.secrets` definitions with restartUnits
- `services.nginx.virtualHosts` with SSL certificates
- `systemd.tmpfiles.rules`

See `wallabag-quadlet.nix` and `litellm-quadlet.nix` for working examples.

## Migration Guide

### Migrating Existing Containers

1. **Replace boilerplate with mkQuadletService:**
   ```nix
   # Before (68 lines)
   { config, lib, pkgs, ... }:
   {
     virtualisation.quadlet.containers.myapp = {
       containerConfig = { ... };
       unitConfig = { ... };
       serviceConfig = { ... };
     };
     sops.secrets."myapp-secrets" = { ... };
     services.nginx.virtualHosts."myapp.vulcan.lan" = { ... };
     systemd.tmpfiles.rules = [ ... ];
   }

   # After (45 lines)
   { config, lib, pkgs, ... }:
   let
     mkQuadletLib = import ../lib/mkQuadletService.nix { inherit config lib pkgs; };
     inherit (mkQuadletLib) mkQuadletService;
   in
   {
     imports = [
       (mkQuadletService {
         name = "myapp";
         image = "docker.io/myapp:latest";
         port = 8080;
         requiresPostgres = true;
         secrets = { appPassword = "myapp-secrets"; };
         # ... other config
       })
     ];
     # Any custom config not covered by mkQuadletService
   }
   ```

2. **Standardize SOPS paths:**
   ```nix
   # Before
   sopsFile = ../../secrets.yaml;
   # or
   sopsFile = ../../../secrets.yaml;

   # After
   let
     common = import ../lib/common.nix { };
   in
   sopsFile = common.secretsPath;
   ```

3. **Consolidate PostgreSQL setup:**
   ```nix
   # Before (30 lines per user)
   systemd.services.postgresql-myapp-setup = { ... };

   # After (6 lines per user)
   imports = [
     (mkPostgresUserSetup {
       user = "myapp";
       database = "myapp";
       secretPath = config.sops.secrets."myapp-db-password".path;
     })
   ];
   ```

## Benefits

- **Reduced duplication**: ~30-50 lines saved per container
- **Consistency**: All containers use same restart policies, SSL setup, etc.
- **Maintainability**: Changes to patterns happen in one place
- **Readability**: Container configs focus on what's unique, not boilerplate
- **Type safety**: Common mistakes (wrong secret paths, missing dependencies) prevented

## Future Enhancements

Potential additional helpers:
- `mkTextfileExporter` - For Prometheus textfile collectors
- `mkAlertRules` - For standardized Prometheus alert definitions
- `mkBackupJob` - For Restic backup configurations
