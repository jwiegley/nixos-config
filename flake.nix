{
  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-apple-silicon.url = "github:nix-community/nixos-apple-silicon";

    firmware = {
      url = "git+file:///etc/nixos/firmware";
      flake = false;  # It's just data, not a flake
    };

    secrets = {
      url = "git+file:///etc/nixos/secrets";
      flake = false;  # It's just data, not a flake
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    quadlet-nix = {
      url = "github:SEIAROTg/quadlet-nix";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-logwatch = {
      url = "github:SFrijters/nixos-logwatch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: let system = "aarch64-linux"; in {
    formatter.aarch64-linux =
      inputs.nixpkgs.legacyPackages."${system}".nixfmt-rfc-style;

    nixosConfigurations.vulcan = inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit system;
        inherit (inputs) firmware secrets;
      };
      modules = [
        inputs.nixos-apple-silicon.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        inputs.quadlet-nix.nixosModules.quadlet
        inputs.nixos-logwatch.nixosModules.logwatch
        inputs.home-manager.nixosModules.home-manager
        {
          nixpkgs.overlays = [
            inputs.claude-code-nix.overlays.default
            (import ./overlays)
          ];
        }
        ./hosts/vulcan
      ];
    };
  };
}
