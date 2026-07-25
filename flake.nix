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

    # AI/agent stack. Formerly the `ai-nix` flake; that has been folded into
    # nix-config, whose ai overlay + packages are exposed as a plain function at
    # `${inputs.nix-config}/flake-ai.nix` (see `aiFlake` in outputs). nix-config
    # is `flake = false` (its flake.nix has Darwin-only git+file inputs), so it
    # can't supply its own inputs — we declare flake-ai.nix's required inputs
    # here. Pins track nix-config's flake.lock so we build what it was tested
    # against. Keep this set in sync with the header of nix-config/flake-ai.nix.
    llm-agents.url = "github:numtide/llm-agents.nix/e12f1c0df7ef59f57089bf9e80a96f9b1e419b06";

    rust-overlay = {
      url = "github:oxalica/rust-overlay/095c394bb91342882f27f6c73f64064fb9de9f2a";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix/f87c14091dccea78d4e3ee4c29af4184215cc28d";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-ai = {
      url = "github:git-ai-project/git-ai/16ebfc032814a1acb5286508c3fb3194d61d9983";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mcp-remote = {
      url = "github:geelen/mcp-remote/02619aff36e79803d7c894e8c8ae7b34b2d11f8c";
      flake = false;
    };

    pal-mcp-server = {
      url = "github:jwiegley/pal-mcp-server/89f05d7cc5ecacaf527d2d6fbacc68a6b6a7534d";
      flake = false;
    };

    agent-browser-source = {
      url = "github:vercel-labs/agent-browser/1ed371f3af472cc0d6cd8fdaea75d1a085ff7534";
      flake = false;
    };

    bigpowers = {
      url = "github:danielvm-git/bigpowers/d1993d31437bfbdb5bda81e84650628215365754";
      flake = false;
    };

    pi-btw = {
      url = "github:dbachelder/pi-btw/4f858102706910ee9d520a9666832f3103631b61";
      flake = false;
    };

    pi-subagentura = {
      url = "github:jwiegley/pi-subagentura/f71281bce8f88741da0e2f9f7ba722964f19d4f0";
      flake = false;
    };

    ponytail = {
      url = "github:DietrichGebert/ponytail/16f29800fd2681bdf24f3eb4ccffe38be3baec6b";
      flake = false;
    };

    translate-tool = {
      url = "github:jwiegley/translate-tool/bffdb7ba3e5db603ea1390fee555354c1d45d642";
      flake = false;
    };

    pi-mcp-adapter = {
      url = "github:nicobailon/pi-mcp-adapter/19d88da27ef82dc61b6e4041b3af7cd0669dbeb5";
      flake = false;
    };

    pi-openai-server-compaction = {
      url = "github:algal/pi-openai-server-compaction/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466";
      flake = false;
    };

    pi-quiet = {
      url = "github:zenspc/pi-extensions/43e6756823a8f77985bec69b86f294c9ef55e8b7";
      flake = false;
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
    #
    # Pinned to the 2026-07-19 rev (nixos-unstable branch tip at that date). The
    # 2026-07-23 bump (e2587caef) broke several HA Python deps sourced from this
    # channel: langfuse 4.0.2 pins wrapt<2.0 but the channel ships wrapt 2.2.2,
    # and a new pyprojectVersionPatchHook rejects pybose's version metadata. This
    # rev is the last one that built cleanly (matches vulcan gen at ac85b36).
    # Re-float to `nixos-unstable` once nixpkgs' HA Python packages catch up.
    nixpkgs-unstable = {
      url = "github:NixOS/nixpkgs/241313f4e8e508cb9b13278c2b0fa25b9ca27163";
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
      # Shared AI/agent overlay + packages from nix-config, imported as a plain
      # function (nix-config is flake=false; this avoids its Darwin-only inputs).
      # Replaces the former inputs.ai-nix.overlays.default.
      aiFlake = import "${inputs.nix-config}/flake-ai.nix" inputs;
      # Pkgs with the local overlay applied — used to expose in-repo
      # packages (e.g. hermes-mcp) at the flake's top level so they can
      # be built standalone with `nix build .#<name>`.
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [
          aiFlake.overlays.default
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
        open-source-secretary = pkgs.callPackage ./pkgs/open-source-secretary { };
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
      apps.${system} = {
        water-attribution-check = {
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

        # `nix run .#check-litellm-models` — validate the LiteLLM model catalog
        # against the live hera/clio model servers: (a) server models with no
        # config entry (warn), (b) config entries the server doesn't offer (fail),
        # and unreachable servers. On-demand ONLY — it hits the network, so it is
        # deliberately never run at eval time (that would couple rebuilds to the
        # servers' uptime). Pass --strict to fail on (a) too. Model ids aren't
        # secrets; servers are queried with a dummy bearer token.
        check-litellm-models = {
          type = "app";
          program =
            let
              runner = pkgs.writeShellApplication {
                name = "check-litellm-models";
                runtimeInputs = [
                  pkgs.nix
                  pkgs.python3
                ];
                # Pass the settings file explicitly: under `nix run` the script
                # lands standalone in the store, so its repo-relative default
                # would not resolve. A user-supplied --settings in "$@" still wins.
                text = ''
                  exec python3 ${./scripts/check-litellm-models.py} \
                    --settings ${./modules/services/litellm-settings.nix} "$@"
                '';
              };
            in
            "${runner}/bin/check-litellm-models";
        };
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
              aiFlake.overlays.default
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
          llama-cpp-overlay-compat =
            assert
              !(builtins.elem pkgs.npmHooks.npmConfigHook (pkgs.llama-cpp.nativeBuildInputs or [ ]))
              || pkgs.llama-cpp ? npmDeps;
            pkgs.runCommand "llama-cpp-overlay-compat-check" { } "touch $out";

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

          drafts-mcp-check-tests = helpers.mkPytestCheck {
            name = "drafts-mcp-check-tests";
            src = ./scripts/drafts-mcp-check;
            suiteDir = "tests";
          };

          drafts-mcp-probe-wiring =
            let
              lib = inputs.nixpkgs.lib;
              systemd = inputs.self.nixosConfigurations.vulcan.config.systemd;
              scheduledExec = systemd.services.drafts-mcp-check.serviceConfig.ExecStart;
              manualUnit = systemd.services.drafts-mcp-app-check or null;
              manualExec = if manualUnit == null then "" else manualUnit.serviceConfig.ExecStart;
              manualWantedBy = if manualUnit == null then [ "missing" ] else manualUnit.wantedBy or [ ];
              timerUnit = systemd.timers.drafts-mcp-check.timerConfig.Unit;
            in
            assert !lib.hasInfix "--app-check" scheduledExec;
            assert manualUnit != null;
            assert lib.hasInfix "--app-check" manualExec;
            assert manualWantedBy == [ ];
            assert timerUnit == "drafts-mcp-check.service";
            assert !builtins.hasAttr "drafts-mcp-app-check" systemd.timers;
            pkgs.runCommand "drafts-mcp-probe-wiring-check"
              {
                nativeBuildInputs = [
                  pkgs.gnugrep
                  pkgs.prometheus.cli
                ];
              }
              ''
                set -euo pipefail
                rules=${./modules/monitoring/alerts/drafts.yaml}
                self_heal=${./modules/services/drafts-mcp-self-heal.nix}
                alertmanager=${./modules/services/alertmanager.nix}

                promtool check rules "$rules"
                grep -Fq 'alert: DraftsMcpTransportFailing' "$rules"
                grep -Fq 'expr: drafts_mcp_sse_open_ok == 1 and drafts_mcp_ssh_hera_ok == 0' "$rules"
                grep -Fq 'HEALABLE = {"DraftsMcpBridgeDown", "DraftsMcpTransportFailing"}' "$self_heal"

                if grep -Eq 'drafts_mcp_(e2e|tcc_automation)_ok|DraftsMcp(AskFailing|TccAutomationLost)' "$rules" "$self_heal" "$alertmanager"; then
                  echo "obsolete Drafts app-level monitoring contract remains" >&2
                  exit 1
                fi
                touch "$out"
              '';

          open-source-secretary = inputs.self.packages.${system}.open-source-secretary;
        };
    };
}
