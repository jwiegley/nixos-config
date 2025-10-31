{ config, lib, pkgs, secrets, ... }:

{
  # Container Secrets Migration Module
  #
  # This module creates user-specific variants of existing container secrets
  # for rootless Podman operation. It maintains backward compatibility by keeping
  # the original /run/secrets/ paths while adding new /run/secrets-<user>/ paths.
  #
  # Migration strategy:
  # - Existing secrets remain at /run/secrets/ (root-owned)
  # - New user-specific secrets deployed to /run/secrets-<user>/ (user-owned)
  # - Same SOPS keys reused for both paths
  # - Services gradually migrated to use user-specific paths
  #
  # Container user assignments:
  # - container-db: Database-dependent services (litellm, metabase, wallabag, teable, nocobase, vanna)
  # - container-web: Web services (changedetection, openspeedtest, silly-tavern)
  # - container-monitor: Monitoring services (opnsense-exporter, technitium-dns-exporter)
  # - container-misc: Miscellaneous services (budgetboard)

  sops = {
    # Reuse existing secrets file
    defaultSopsFile = secrets.outPath + "/secrets.yaml";

    secrets = {
      # === container-db secrets (database-dependent services) ===

      # LiteLLM API keys and configuration
      "litellm-secrets-container-db" = {
        key = "litellm-secrets";
        owner = "container-db";
        group = "container-db";
        mode = "0400";
        path = "/run/secrets-container-db/litellm-secrets";
      };

      # Teable PostgreSQL password
      "teable-postgres-password-container-db" = {
        key = "teable-postgres-password";
        owner = "container-db";
        group = "container-db";
        mode = "0400";
        path = "/run/secrets-container-db/teable-postgres-password";
      };

      # Teable application environment
      "teable-env-container-db" = {
        key = "teable-env";
        owner = "container-db";
        group = "container-db";
        mode = "0400";
        path = "/run/secrets-container-db/teable-env";
      };

      # Nocobase secrets
      "nocobase-db-password-container-db" = {
        key = "nocobase-db-password";
        owner = "container-db";
        group = "container-db";
        mode = "0400";
        path = "/run/secrets-container-db/nocobase-db-password";
      };

      "nocobase-secrets-container-db" = {
        key = "nocobase-secrets";
        owner = "container-db";
        group = "container-db";
        mode = "0400";
        path = "/run/secrets-container-db/nocobase-secrets";
      };

      # Vanna AI secrets
      "vanna-env-container-db" = {
        key = "vanna-env";
        owner = "container-db";
        group = "container-db";
        mode = "0400";
        path = "/run/secrets-container-db/vanna-env";
      };

      # Metabase secrets
      "metabase-env-container-db" = {
        key = "metabase-env";
        owner = "container-db";
        group = "container-db";
        mode = "0400";
        path = "/run/secrets-container-db/metabase-env";
      };

      # === container-monitor secrets (monitoring services) ===
      # (All secrets now managed by mkQuadletService with containerUser parameter)

      # === container-web secrets (web services) ===

      # ChangeDetection API key
      "changedetection/api-key-container-web" = {
        key = "changedetection/api-key";
        owner = "container-web";
        group = "container-web";
        mode = "0400";
        path = "/run/secrets-container-web/changedetection-api-key";
      };

      # === container-misc secrets ===

      # BudgetBoard database password
      "budgetboard/database-password-container-misc" = {
        key = "budgetboard/database-password";
        owner = "container-misc";
        group = "container-misc";
        mode = "0400";
        path = "/run/secrets-container-misc/budgetboard-database-password";
      };
    };
  };
}
