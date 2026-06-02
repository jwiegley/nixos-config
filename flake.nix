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

    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    org-jw = {
      url = "github:jwiegley/org-jw";
    };

    sacramento-cluster-ics = {
      url = "git+ssh://gitea/johnw/sacramento-cluster-ics";
      inputs.nixpkgs.follows = "nixpkgs";
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

    promptdeploy = {
      url = "git+ssh://gitea/johnw/promptdeploy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-scripts = {
      url = "git+ssh://gitea/johnw/git-scripts";
      flake = false;
    };

    # stock-trader: pinned source tree consumed by the Vulcan deployment.
    # Not a flake — the laptop repo's own flake.nix is for dev only.
    stock-trader = {
      url = "git+ssh://gitea/johnw/stock-trader?ref=refs/tags/v0.1.7";
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
      # Pkgs with the local overlay applied — used to expose in-repo
      # packages (e.g. hermes-mcp) at the flake's top level so they can
      # be built standalone with `nix build .#<name>`.
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ (import ./overlays inputs system) ];
        config.allowUnfree = true;
      };
    in
    {
      formatter.aarch64-linux = inputs.nixpkgs.legacyPackages."${system}".nixfmt-rfc-style;

      packages.${system} = {
        hermes-mcp = pkgs.callPackage ./pkgs/hermes-mcp { };
      };

      # `nix run .#water-attribution-check` — validate the generated
      # water_attribution.yaml against HA's entity registry. The script
      # parses the YAML, pulls out every `zone_slug` attribute, and
      # confirms each `valve.sprinkler_control_<slug>_zone` exists.
      #
      # SECURITY note: the script reads /var/lib/hass/.storage/core.entity_registry
      # for METADATA ONLY (entity-id strings). It never dumps the full file
      # contents — every jq invocation is either `jq -e` (boolean test, no
      # value output) or field-targeted (`.entity_id` only). Per CLAUDE.md
      # the entity registry is on the "adjacent / context-sensitive" list,
      # which permits field-targeted jq but forbids `cat`.
      apps.${system}.water-attribution-check = {
        type = "app";
        program =
          let
            checkScript = pkgs.writeShellScript "water-attribution-check" ''
              set -euo pipefail

              # Prefer the live deployment path — it's always the current
              # generation's file (the activation script ran on the last
              # nixos-rebuild switch). The store fallback handles the case
              # where the script runs before any switch has happened (e.g.
              # immediately after a `nixos-rebuild build`).
              pkg=/var/lib/hass/packages/water_attribution.yaml
              if [ ! -r "$pkg" ]; then
                # Files in /nix/store have hash-prefixed names like
                # `<hash>-water_attribution.yaml`; the right glob is
                # `*-water_attribution.yaml`. Pick the file with the newest
                # ctime (store-file mtime is always Unix epoch).
                pkg=$(find /nix/store -maxdepth 1 \
                          -name '*-water_attribution.yaml' \
                          -not -name '*.drv' \
                          -printf '%C@ %p\n' 2>/dev/null \
                      | sort -nr | head -1 | cut -d' ' -f2-)
              fi
              if [ -z "''${pkg:-}" ] || [ ! -r "$pkg" ]; then
                echo "ERROR: water_attribution.yaml not deployed and not in store — run nixos-rebuild build/switch first"
                exit 1
              fi
              echo "Validating YAML at: $pkg"

              if ! ${pkgs.yq-go}/bin/yq eval '.' "$pkg" > /dev/null; then
                echo "FAIL: YAML parse error"
                exit 1
              fi

              registry=/var/lib/hass/.storage/core.entity_registry
              if [ ! -r "$registry" ]; then
                echo "WARN: cannot read entity registry — skipping live-entity check"
                exit 0
              fi

              # Pull every zone_slug attribute out of the YAML's template
              # sensors. The YAML structure puts the gated-GPM template's
              # attributes under template[*].sensor[*].attributes.zone_slug.
              slugs=$(${pkgs.yq-go}/bin/yq eval '
                [.template[]?.sensor[]?.attributes.zone_slug // ""] | unique | .[]
              ' "$pkg" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -v '^$' || true)

              missing=0
              count=0
              for slug in $slugs; do
                count=$((count + 1))
                eid="valve.sprinkler_control_''${slug}_zone"
                # `jq -e` is a boolean test — no values are emitted to
                # stdout, so the entity registry's other fields (e.g.
                # unique_id, capabilities) never reach the conversation.
                if ! ${pkgs.jq}/bin/jq -e --arg eid "$eid" \
                    '.data.entities[] | select(.entity_id == $eid)' \
                    "$registry" > /dev/null; then
                  echo "MISSING: $eid not in entity registry"
                  missing=$((missing + 1))
                fi
              done

              if [ "$missing" -gt 0 ]; then
                echo "FAIL: $missing zone(s) missing from registry"
                exit 1
              fi
              echo "OK: $count zone slugs validated"
            '';
          in
          toString checkScript;
      };

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

      checks.${system} =
        let
          helpers = import ./tests/checks.nix { inherit pkgs; };
        in
        {
          openclaw-config-schema = import ./tests/openclaw/check-schema.nix {
            inherit pkgs;
            inherit (inputs.self.nixosConfigurations.vulcan.pkgs)
              openclaw-config-template
              ;
          };

          openclaw-self-heal-tests = helpers.mkPytestCheck {
            name = "openclaw-self-heal-tests";
            src = ./scripts/openclaw-self-heal;
            suiteDir = "tests";
          };

          hermes-self-heal-tests = helpers.mkPytestCheck {
            name = "hermes-self-heal-tests";
            src = ./scripts/hermes-self-heal;
            suiteDir = "tests";
          };

          openclaw-hermes-smoke-tests = helpers.mkPytestCheck {
            name = "openclaw-hermes-smoke-tests";
            src = ./scripts;
            suiteDir = "openclaw-hermes-smoke-tests";
          };

          agent-health-report-tests = helpers.mkPytestCheck {
            name = "agent-health-report-tests";
            src = ./scripts;
            suiteDir = "agent-health-report-tests";
          };
        };
    };
}
