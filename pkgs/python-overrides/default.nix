{ pkgs, python }:

# Returns an attrset of pip-only Python packages built against the
# supplied python interpreter. Each .nix file in this directory is a
# buildPythonPackage; default.nix composes them. Add a new override by
# dropping a file here and adding it to the attrset below.
#
# Why a per-host overlay slot rather than direct pythonPackagesExtensions?
# The host's existing pythonPackagesExtensions overlay (overlays/default.nix)
# is shared across all Python derivations on the system — adding pip-only
# experimental deps there would hot-recompile every Python service. These
# overrides are scoped to the stock-trader package only and consumed via
# `final.callPackage ./pkgs/stock-trader.nix { ... pythonOverrides = ...; }`.

let
  callPackage = pkgs.lib.callPackageWith (pkgs // { inherit python; });
in
{
  claude-agent-sdk = callPackage ./claude-agent-sdk.nix { };
  fredapi = callPackage ./fredapi.nix { };
  vaderSentiment = callPackage ./vaderSentiment.nix { };
}
