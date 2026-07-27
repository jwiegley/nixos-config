{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

{
  # ORPHANED as of 2026-07-27: nothing imports this module, and the shared
  # container users it targets (container-db / container-web) no longer exist —
  # that model was replaced by per-service users, see
  # modules/users/container-users-dedicated.nix. /run/secrets-container-db is
  # absent on the running host. Kept for reference only; the description below
  # documents what the test WAS meant to prove, not current behaviour.
  #
  # Test module to validate per-user SOPS secrets ownership configuration
  # This module tests that secrets can be deployed to user-specific directories
  # with proper ownership and permissions.
  #
  # Expected behavior:
  # - Secret file created at /run/secrets-container-db/litellm-secrets-test
  # - Owner: container-db, Group: container-db, Mode: 0400
  # - Only container-db user can read the secret
  # - Other users (container-web, etc.) cannot access it

  sops.secrets."litellm-secrets-test" = {
    sopsFile = secrets.outPath + "/secrets.yaml";
    key = "litellm-secrets"; # Reuse existing secret for testing
    owner = "container-db";
    group = "container-db";
    mode = "0400";
    path = "/run/secrets-container-db/litellm-secrets-test";
  };
}
