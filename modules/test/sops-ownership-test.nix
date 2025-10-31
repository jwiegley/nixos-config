{ config, lib, pkgs, secrets, ... }:

{
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
    key = "litellm-secrets";  # Reuse existing secret for testing
    owner = "container-db";
    group = "container-db";
    mode = "0400";
    path = "/run/secrets-container-db/litellm-secrets-test";
  };
}
