{
  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    nixos-apple-silicon = {
      url = "github:nix-community/nixos-apple-silicon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firmware = {
      url = "git+file:///etc/nixos/firmware";
      flake = false;  # It's just data, not a flake
    };

    secrets = {
      url = "git+file:///etc/nixos/secrets";
      flake = false;  # It's just data, not a flake
    };

    nagios = {
      url = "git+file:///etc/nixos/nagios";
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
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-logwatch = {
      url = "github:SFrijters/nixos-logwatch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };

    org-jw = {
      url = "github:jwiegley/org-jw";
    };

    # Newer nixpkgs for Immich 2.4.1 (CR3 thumbnail fix in PR #24587)
    nixpkgs-immich = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };

    # nixpkgs unstable for packages that need newer versions
    # Used for: JupyterLab (4.5.0+), and other packages needing unstable
    nixpkgs-unstable = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
  };

  outputs = inputs: let system = "aarch64-linux"; in {
    formatter.aarch64-linux =
      inputs.nixpkgs.legacyPackages."${system}".nixfmt-rfc-style;

    nixosConfigurations.vulcan = inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit system inputs;
        inherit (inputs) firmware secrets nagios;
      };
      modules = [
        inputs.nixos-apple-silicon.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        inputs.quadlet-nix.nixosModules.quadlet
        inputs.nixos-logwatch.nixosModules.logwatch
        inputs.home-manager.nixosModules.home-manager
        {
          nixpkgs.overlays = [
            (import ./overlays inputs system)
          ];
        }
        ./hosts/vulcan
      ];
    };
  };
}
