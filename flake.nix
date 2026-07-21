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
      # Pinned to be5813ba (2026-06-27, gemini-cli 0.47.0). The next locked rev
      # (552400b0, 2026-06-28) bumps gemini-cli to 0.49.0 and adds a postPatch
      # that runs `node align-pins-to-lock.mjs`. buildNpmPackage replays
      # postPatch inside the `gemini-cli-0.49.0-npm-deps` fixed-output
      # derivation, which carries no nodejs on PATH, so on aarch64 — where that
      # FOD isn't in numtide's binary cache and must build locally — it dies
      # with "node: command not found" (exit 127) in patchPhase, breaking
      # johnw's home-manager-path (gemini-cli is in the nix-config shared
      # package list). x86_64 substitutes the FOD from cache and never hits it.
      # Unpin once upstream adds nodejs to the gemini-cli npm-deps inputs (or
      # drops the node postPatch from the FOD); no fix exists as of HEAD
      # (70e4e3d5, 2026-06-29).
      url = "github:numtide/llm-agents.nix/be5813ba4f71c49494d530c9a0b79132f089270e";
    };

    ai-nix = {
      # Pinned to 4690e999 — the last rev whose llama-cpp overlay is compatible
      # with our nixpkgs pin. Later revs (94b7f45+) redefine llama-cpp as
      # `prev.llama-cpp.override { inherit (final) nodejs_latest; }`, which assumes
      # a newer nixpkgs whose llama-cpp/package.nix takes a `nodejs_latest` arg
      # (the in-tree tools/ui webui era, llama-cpp ≳ 9190). Our nixpkgs is pinned
      # to nixos-25.11 @ d6df351 (llama-cpp 6981, pre-webui), which has no such
      # parameter, so the override fails with "function 'anonymous lambda' called
      # with unexpected argument 'nodejs_latest'". 4690e999's overlay uses
      # overrideAttrs only and builds the bundled webui via the nodejs /
      # npmConfigHook that overlays/default.nix layers on. Unpin once our nixpkgs
      # is bumped past the llama-cpp webui-in-tools/ui change.
      url = "github:jwiegley/ai-nix/4690e999a0ac";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hermes-agent = {
      # Pinned to c47b9d12 (2026-06-02). Later revs (c3055d61, fd1e7c2b, HEAD)
      # refactored npm packaging to a single shared npmDepsHash in nix/lib.nix
      # that is x86_64-only: the lockfile carries per-arch esbuild/rollup native
      # deps and prefetch-npm-deps hashes only the build platform's set. Upstream
      # CI runs x86_64, so they ship sha256-cY+gM1FnTBjmld...; this aarch64 host
      # computes sha256-hgnqcpKRPztHhDEpwC7HJrALuJp9wsrV4+GJ6t6HI2c=, breaking
      # hermes-tui's fixed-output npm-deps. Unpin once upstream makes the
      # npm-deps hash architecture-independent (or recomputes per-system).
      url = "github:NousResearch/hermes-agent/c47b9d126f2f820f41059813a2c5b16ea4742bf8";
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
      # Keep this pin aligned with programs.promptdeploy.expectedRevision.
      # Revision 56f8e02 also carries the portable HTTPS submodule URL.
      url = "git+https://github.com/jwiegley/promptdeploy?rev=56f8e02fbc4a86031a5dbc434693d947f7ba90af&submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-scripts = {
      url = "git+ssh://gitea/johnw/git-scripts";
      flake = false;
    };

    # stock-trader: pinned source tree consumed by the Vulcan deployment.
    # Not a flake — the laptop repo's own flake.nix is for dev only.
    stock-trader = {
      url = "git+ssh://gitea/johnw/stock-trader?ref=refs/tags/v0.2.0";
      flake = false;
    };

    # Shared home-manager configuration from the Darwin nix-config repo.
    # Imported as non-flake to avoid evaluating Darwin's local git+file inputs.
    nix-config = {
      url = "git+ssh://gitea/johnw/nix-config";
      flake = false;
    };

    # nixpkgs unstable for packages that need newer versions
    # Used for: JupyterLab (4.5.0+), Home Assistant, and other packages needing unstable
    nixpkgs-unstable = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };

    # Dedicated pin for Immich 3.0.1 (server must be >= the auto-updating
    # mobile app, which is already 3.0.1; v3's checksum-based backup sync is
    # what lets phone photos byte-identical to the /tank archive register as
    # backed up instead of looping "Preparing" forever). nixos-unstable still
    # carries 2.7.5 (the 3.0.1 bump f76955e3 hasn't reached the channel), and
    # bumping the whole nixpkgs-unstable input would drag Home Assistant /
    # JupyterLab along. Rev 266a3597 is the nixpkgs master commit from Hydra
    # eval 1826899, whose immich.aarch64-linux and
    # immich-machine-learning.aarch64-linux jobs both built successfully, so
    # everything substitutes from cache.nixos.org. Drop this input (and point
    # overlays/default.nix's immich back at nixpkgs-unstable) once
    # nixos-unstable ships immich >= 3.0.1.
    nixpkgs-immich = {
      url = "github:NixOS/nixpkgs/266a3597f538657576ca4b476bb032b68bace284";
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
        overlays = [
          inputs.ai-nix.overlays.default
          (import ./overlays inputs system)
        ];
        config.allowUnfree = true;
      };
    in
    {
      # nixfmt-tree = treefmt pre-configured with nixfmt: walks the git tree
      # itself, so it works with `nix fmt` on Nix >= 2.24 (which no longer
      # passes the tree root as an argument — bare nixfmt would read stdin).
      formatter.aarch64-linux = inputs.nixpkgs.legacyPackages."${system}".nixfmt-tree;

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
              inputs.ai-nix.overlays.default
              (import ./overlays inputs system)
              # nix-config's misc-tools overlay (+ its 00-lib helper dep):
              # johnw's HM packages import nix-config/config/packages.nix
              # against vulcan's pkgs (useGlobalPkgs), and as of nix-config
              # a6ae5339 (2026-07-06) that list references cmdperf, defined
              # only in nix-config's own overlays — which vulcan never
              # applied. Same local-adaptation class as ssh-settings-compat
              # and the git-ai stub. Deliberately NOT importing the whole
              # overlays/ dir (the emacs overlay would force large rebuilds).
              (import "${inputs.nix-config}/overlays/00-lib.nix")
              # gogcli base for the misc-tools overlay below: it bumps gogcli
              # via `prev.gogcli.overrideAttrs`, assuming the underlying
              # nixpkgs ships a base gogcli — true on Darwin (unstable
              # nixpkgs, 0.29.0), absent from nixos-25.11, so the overlay
              # alone eval-fails with "attribute 'gogcli' missing" (the
              # 2026-07-06 switch failure). Provide unstable's base here so
              # the override has something to override; the misc-tools stage
              # then replaces src/version with the openclaw/gogcli 0.31.1
              # fork as intended. Drop once vulcan's nixpkgs ships gogcli.
              (final: prev: {
                gogcli = inputs.nixpkgs-unstable.legacyPackages.${system}.gogcli;
              })
              (import "${inputs.nix-config}/overlays/30-misc-tools.nix")
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
