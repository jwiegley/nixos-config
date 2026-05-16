# Helpers for repo-local flake checks.
# Each function returns a derivation that runs a pytest suite in the
# Nix sandbox; failure of pytest fails the flake check.
{ pkgs }:
let
  pytestPython = pkgs.python312.withPackages (ps: [ ps.pytest ]);

  mkPytestCheck =
    {
      name,
      src,
      suiteDir,
    }:
    pkgs.runCommand "${name}-check"
      {
        nativeBuildInputs = [ pytestPython ];
        inherit src;
      }
      ''
        set -euo pipefail
        cp -r "$src" suite
        chmod -R +w suite
        cd suite
        ${pytestPython}/bin/pytest ${suiteDir} -v
        touch "$out"
      '';
in
{
  inherit mkPytestCheck;
}
