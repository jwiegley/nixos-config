{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    nixos-apple-silicon = {
      # Pinned to kernel 6.17.12 for ZFS compatibility
      # ZFS 2.3.x doesn't support kernel 6.18+ yet
      # Remove pin once ZFS supports newer kernels
      url = "github:nix-community/nixos-apple-silicon/f94f4496775f9ca6e8a9e9e83f5aa4e4210fbb5d";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firmware = {
      url = "git+file:///etc/nixos/firmware";
      flake = false; # It's just data, not a flake
    };

    secrets = {
      url = "git+file:///etc/nixos/secrets";
      flake = false; # It's just data, not a flake
    };

    nagios = {
      url = "git+file:///etc/nixos/nagios";
      flake = false; # It's just data, not a flake
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

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    org-jw = {
      url = "github:jwiegley/org-jw";
    };

    una = {
      url = "github:jwiegley/una";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sizes = {
      url = "github:jwiegley/sizes";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pushme = {
      url = "github:jwiegley/pushme";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-ai = {
      url = "git+file:///tank/src/git-ai/nix-fix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    promptdeploy = {
      url = "git+ssh://gitea/johnw/promptdeploy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-scripts = {
      url = "git+ssh://gitea/johnw/git-scripts";
      flake = false;
    };

    # Shared home-manager configuration from the Darwin nix-config repo.
    # Imported as non-flake to avoid evaluating Darwin's local git+file inputs.
    nix-config = {
      url = "git+ssh://gitea/johnw/nix-config";
      flake = false;
    };

    # nixpkgs unstable for packages that need newer versions
    # Used for: JupyterLab (4.5.0+), Immich 2.4.1 (CR3 fix), and other packages needing unstable
    nixpkgs-unstable = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
  };

  outputs =
    inputs:
    let
      system = "aarch64-linux";
    in
    {
      formatter.aarch64-linux = inputs.nixpkgs.legacyPackages."${system}".nixfmt-rfc-style;

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
          inputs.microvm.nixosModules.host
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
