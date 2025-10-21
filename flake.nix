{
  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-apple-silicon.url = "github:nix-community/nixos-apple-silicon";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-logwatch = {
      url = "github:SFrijters/nixos-logwatch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    quadlet-nix = {
      url = "github:SEIAROTg/quadlet-nix";
    };

    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs,
              nixos-apple-silicon,
              home-manager,
              sops-nix,
              nixos-logwatch,
              quadlet-nix,
              claude-code-nix, ... }:
    let system = "aarch64-linux"; in {
      formatter.aarch64-linux =
        nixpkgs.legacyPackages."${system}".nixfmt-rfc-style;

      nixosConfigurations.vulcan = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-apple-silicon.nixosModules.default
          nixos-logwatch.nixosModules.logwatch
          sops-nix.nixosModules.sops
          quadlet-nix.nixosModules.quadlet
          {
            nixpkgs.overlays = [
              claude-code-nix.overlays.default
              (import ./overlays)
            ];
          }
          home-manager.nixosModules.home-manager
          ./hosts/vulcan
        ];
      };
    };
}
