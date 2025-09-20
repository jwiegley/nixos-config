{
  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    nixos-logwatch = {
      url = "github:SFrijters/nixos-logwatch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixos-hardware, nixos-logwatch, ... }:
    let system = "x86_64-linux"; in {
      formatter.x86_64-linux =
        nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;

      nixosConfigurations.vulcan = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-logwatch.nixosModules.logwatch
          nixos-hardware.nixosModules.apple-t2
          ./hosts/vulcan
        ];
      };
    };
}

# system.activationScripts.consoleBlank = ''
#   echo "Setting up console blanking..."
#   ${pkgs.util-linux}/bin/setterm --blank 1 --powerdown 2 > /dev/tty1
# '';
