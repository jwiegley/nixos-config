final: prev:
# Node-RED 4.1.10 override.
#
# Nixpkgs stable (nixos-25.11) ships 4.1.2. This overlay bumps the pin to the
# upstream maintenance release 4.1.10 while keeping the rest of the
# packaging (postPatch entrypoints, npm-deps mechanism) intact.
#
# Upstream's own package-lock.json (bundled in src) is used instead of the
# nixpkgs-maintained ./package-lock.json — the original recipe symlinked the
# nixpkgs copy because nixpkgs versions the lockfile against a fixed src;
# at a different version we just use whatever the upstream tag ships.
#
# We override `npmDeps` directly (not just `npmDepsHash`) so the
# fixed-output derivation's name carries the new version. Otherwise nix
# substitutes the cached 4.1.2-keyed artifact and the lockfile-vs-cache
# integrity check fails downstream.
#
# To bump in future: update `version`, refresh `srcHash` via
#   nix-prefetch-url --unpack https://github.com/node-red/node-red/archive/refs/tags/<version>.tar.gz
# then nix-build, copy the "got: sha256-…" line printed by fetchNpmDeps into
# `npmDepsHash`.
let
  version = "4.1.10";
  srcHash = "sha256-r/yYYTK4ldaNH130GTg9YZ2uBMZYt06mxKgiI+KKPUw=";
  npmDepsHash = "sha256-0OhnIrkjG2uwr9j0w/7tM5YhzCkcRb4oMbAJJfWVAjA=";

  src = prev.fetchFromGitHub {
    owner = "node-red";
    repo = "node-red";
    tag = version;
    hash = srcHash;
  };
in
{
  node-red = prev.node-red.overrideAttrs (_oldAttrs: {
    inherit version src;

    npmDeps = prev.fetchNpmDeps {
      inherit src;
      name = "node-red-${version}-npm-deps";
      hash = npmDepsHash;
    };

    # Use upstream's own package-lock.json (bundled in src), not the
    # nixpkgs-maintained one the original recipe symlinks in. Keep the
    # bin-attr injection from the original postPatch.
    postPatch = ''
      ${prev.lib.getExe prev.jq} '. += {"bin": {"node-red": "packages/node_modules/node-red/red.js", "node-red-pi": "packages/node_modules/node-red/bin/node-red-pi"}}' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';
  });
}
