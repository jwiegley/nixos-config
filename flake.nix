{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nixpkgs.url = "github:williamvds/nixpkgs/add_pihole";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    nixos-logwatch = {
      url = "github:SFrijters/nixos-logwatch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, nixos-hardware, nixos-logwatch, ... }:
    let system = "x86_64-linux"; in {
      formatter.x86_64-linux =
        nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;

      nixosConfigurations.vulcan = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-logwatch.nixosModules.logwatch
          ./configuration.nix
          ({ config, lib, pkgs, ... }: {
            systemd.services.pihole-ftl-setup = {
              script = lib.mkForce ''
                set -x
                ${import "${nixpkgs}/nixos/modules/services/networking/pihole-ftl-setup-script.nix" {
                  inherit config lib pkgs;
                  cfg = config.services.pihole-ftl;
                }}
              '';
            };
          })
          nixos-hardware.nixosModules.apple-t2
        ];
      };
    };
}
