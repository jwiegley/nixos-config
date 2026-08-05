# Helpers for repo-local flake checks.
# Each function returns a derivation that runs a pytest suite in the
# Nix sandbox; failure of pytest fails the flake check.
{ pkgs }:
let
  mkPytestCheck =
    {
      name,
      src,
      suiteDir,
      # Opt-in extra Python packages for suites that need more than bare pytest.
      # Per-check rather than global so one suite's dependencies do not inflate
      # every other check's closure.
      extraPackages ? (_ps: [ ]),
    }:
    let
      pytestPython = pkgs.python312.withPackages (ps: [ ps.pytest ] ++ extraPackages ps);
    in
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
