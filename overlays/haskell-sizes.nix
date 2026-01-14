# Haskell overlay to fix the "sizes" package by using version 2.4.1 from Hackage
#
# The current version in nixpkgs has broken dependencies. This overlay overrides
# the haskellPackages.sizes package to use a working version from Hackage.
#
# Usage: This overlay is automatically applied via /etc/nixos/overlays/default.nix
#
# References:
# - Hackage package: https://hackage.haskell.org/package/sizes-2.4.1
# - NixOS Haskell infrastructure: https://nixos.org/manual/nixpkgs/stable/#haskell

final: prev: {
  haskellPackages = prev.haskellPackages.override {
    overrides = hfinal: hprev: {
      # Override the "sizes" package to use version 2.4.1 from Hackage
      # This version has working dependencies and builds successfully
      sizes = hfinal.callHackageDirect {
        pkg = "sizes";
        ver = "2.4.1";
        sha256 = "1cmfwfa8x2r0big4f646f8h2rfnwjwlhjyvidnw8b71g04swqld1";
      } { };
    };
  };
}
