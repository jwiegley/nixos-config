final: prev: {
  home-assistant-custom-components = prev.home-assistant-custom-components or {} // {
    # HACS - Home Assistant Community Store
    hacs = final.callPackage ./hacs.nix { };

    # Pentair IntelliCenter Integration
    intellicenter = final.callPackage ./intellicenter.nix { };
  };
}
