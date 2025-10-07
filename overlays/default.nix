final: prev: {
  # Python package for HACS frontend
  python3Packages = prev.python3Packages // {
    hacs-frontend = final.callPackage ./hacs-frontend.nix {
      inherit (prev.python3Packages) buildPythonPackage;
      inherit (final) fetchurl;
    };
  };

  home-assistant-custom-components = prev.home-assistant-custom-components or {} // {
    # HACS - Home Assistant Community Store
    hacs = final.callPackage ./hacs.nix {
      hacs-frontend = final.python3Packages.hacs-frontend;
    };

    # Pentair IntelliCenter Integration
    intellicenter = final.callPackage ./intellicenter.nix { };
  };
}
