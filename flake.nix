{
  nixConfig = {
    extra-substituters = [
      "https://cache.soopy.moe"
    ];
    extra-trusted-public-keys = [ "cache.soopy.moe-1:0RZVsQeR+GOh0VQI9rvnHz55nVXkFardDqfm4+afjPo=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-pr.url = "github:williamvds/nixpkgs/add_pihole";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs =
    { nixpkgs, nixos-hardware, ... }:
    {
      formatter.x86_64-linux =
        nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;

      nixosConfigurations.vulcan = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          ./nix/substituter.nix
          nixos-hardware.nixosModules.apple-t2
        ];
      };
    };
}
