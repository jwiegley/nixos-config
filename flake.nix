{
  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

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

    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
  };

  outputs = { nixpkgs, nixos-hardware, home-manager, sops-nix, nixos-logwatch, quadlet-nix, ... }:
    let system = "x86_64-linux"; in {
      formatter.x86_64-linux =
        nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;

      nixosConfigurations.vulcan = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.apple-t2
          nixos-logwatch.nixosModules.logwatch
          sops-nix.nixosModules.sops
          quadlet-nix.nixosModules.quadlet
          home-manager.nixosModules.home-manager
          ./hosts/vulcan
        ];
      };
    };
}

# system.activationScripts.consoleBlank = ''
#   echo "Setting up console blanking..."
#   ${pkgs.util-linux}/bin/setterm --blank 1 --powerdown 2 > /dev/tty1
# '';
