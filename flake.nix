{
  inputs = {
    # The NixOS module graph and the base operating system stay on the stable release.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    nixos-apple-silicon = {
      # Pinned to kernel 6.17.12 for ZFS compatibility
      # ZFS 2.3.x doesn't support kernel 6.18+ yet
      # Remove pin once ZFS supports newer kernels
      # STATUS 2026-07-27: that premise no longer matches nixpkgs' own compat
      # metadata — `linuxPackages_6_18.zfs_2_3` evaluates with meta.broken =
      # false both in the locked nixpkgs (25.11, zfs 2.3.7) and in
      # nixpkgs-unstable (zfs 2.3.8). Still unverified whether a newer
      # nixos-apple-silicon rev builds its Asahi kernel + ZFS cleanly on this
      # host, so the pin stays until someone tries it.
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

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    quadlet-nix = {
      url = "github:SEIAROTg/quadlet-nix";
    };

    # Keep the NixOS module release-compatible with the stable core; its user
    # package set still follows nixpkgs-user below rather than the system package set.
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs-user";
    };

    nixos-logwatch = {
      url = "github:SFrijters/nixos-logwatch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-config-ai = {
      url = "git+ssh://gitea/johnw/nix-config?dir=config/ai";
      inputs.pi.follows = "pi";
    };

    # The portable configuration consumes this source. The build driver refreshes it before
    # each normal Vulcan rebuild rather than retaining the portable flake's pinned Pi lock.
    pi = {
      url = "github:jwiegley/pi";
      flake = false;
    };

    # User-facing packages follow the same nixpkgs input as Hera through the
    # portable AI configuration. Keep this distinct from the stable system input.
    nixpkgs-user.follows = "nix-config-ai/nixpkgs";

    llm-agents.follows = "nix-config-ai/llm-agents";

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

    # obr: per-repository task tracking. Required by the shared home-manager
    # config, whose config/obr.nix resolves `inputs.obr.packages.<system>.default`
    # and asserts it is non-null ("managed home requires ...").
    #
    # It MUST be declared here rather than inherited: `nix-config` below is
    # consumed with `flake = false`, so it is only a source tree and its own
    # inputs are never resolved. Declared exactly as nix-config declares it
    # (flake.nix:7) -- plain url, no `follows` -- so both sides resolve to the
    # same derivation.
    obr = {
      url = "github:jwiegley/obr";
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
    # rev is the last one that built cleanly (matches vulcan gen at 3ef83cb).
    # Re-float to `nixos-unstable` once nixpkgs' HA Python packages catch up.
    nixpkgs-unstable = {
      url = "github:NixOS/nixpkgs/241313f4e8e508cb9b13278c2b0fa25b9ca27163";
    };

  };

  outputs =
    inputs:
    let
      system = "aarch64-linux";
      # Pkgs with the local overlay applied — used to expose in-repo
      # packages (e.g. hermes-mcp) at the flake's top level so they can
      # be built standalone with `nix build .#<name>`.
      # Standalone applications and flake checks use the same package set as Hera.
      # The NixOS configuration below deliberately continues to use inputs.nixpkgs.
      userPkgs = import inputs.nixpkgs-user {
        inherit system;
        overlays = [
          inputs.nix-config-ai.overlays.default
          (_final: _prev: {
            gogcli = inputs.nixpkgs-unstable.legacyPackages.${system}.gogcli;
          })
          (final: prev: {
            glances = prev.glances.overridePythonAttrs (old: {
              disabledTests = (old.disabledTests or [ ]) ++ [ "test_phys_core_returns_int" ];
            });
            python312 = prev.python312.override {
              packageOverrides = _pyFinal: pyPrev: {
                inline-snapshot = pyPrev.inline-snapshot.overridePythonAttrs (old: {
                  disabledTests = (old.disabledTests or [ ]) ++ [
                    "test_docs[code_generation.md]"
                    "test_docs[testing.md]"
                    "test_docs[categories.md]"
                  ];
                });
                python-ulid = pyPrev.python-ulid.overridePythonAttrs (old: {
                  disabledTests = (old.disabledTests or [ ]) ++ [ "test_same_millisecond_overflow" ];
                });
              };
            };
            task-master-ai = final.callPackage ./pkgs/task-master-ai.nix { };
          })
          inputs.nix-config-ai.overlays.tools
          (import ./overlays inputs system)
        ];
        config.allowUnfree = true;
      };
      pkgs = userPkgs;
    in
    {
      # nixfmt-tree = treefmt pre-configured with nixfmt: walks the git tree
      # itself, so it works with `nix fmt` on Nix >= 2.24 (which no longer
      # passes the tree root as an argument — bare nixfmt would read stdin).
      formatter.aarch64-linux = userPkgs.nixfmt-tree;

      packages.${system} = {
        hermes-mcp = userPkgs.callPackage ./pkgs/hermes-mcp { };
        open-source-secretary = userPkgs.callPackage ./pkgs/open-source-secretary { };
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

        # check-litellm-models REMOVED 2026-08-01 with the LLM proxy it validated.
        # It validated a model *catalog* against the backends it routed to, and
        # there is no catalog any more: the gateway on 127.0.0.1:4000 is a plain
        # reverse proxy to oMLX on hera, which serves its models under their
        # real ids. The equivalent check is now a one-liner:
        #   curl -s http://127.0.0.1:4000/v1/models | jq -r '.data[].id'
        # compared against models.nix.
      };

      nixosConfigurations.vulcan = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit system inputs userPkgs;
          inherit (inputs) firmware secrets;
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
              inputs.nix-config-ai.overlays.default
              # nixos-25.11 has no gogcli base for the supported tools overlay
              # to update, so retain the existing unstable base explicitly.
              (_final: _prev: {
                gogcli = inputs.nixpkgs-unstable.legacyPackages.${system}.gogcli;
              })
              inputs.nix-config-ai.overlays.tools
              (import ./overlays inputs system)
            ];
          }
          ./hosts/vulcan
        ];
      };

      checks.${system} =
        let
          helpers = import ./tests/checks.nix { inherit pkgs; };
          vulcan = inputs.self.nixosConfigurations.vulcan;
          vulcanConfig = vulcan.config;
          buildSource = builtins.readFile ./build;
          sessionGatherSshConfig = pkgs.writeText "session-gather-ssh-config" (
            vulcanConfig.home-manager.users.johnw.xdg.configFile."sessions/ssh_config".text
          );
          inherit (vulcanConfig.services.node-red) port;
          find =
            description: predicate: values:
            pkgs.lib.findFirst predicate (throw "missing ${description}") values;
          nodeRedAdminPackage = find "node-red-admin package" (
            package: pkgs.lib.getName package == "node-red-admin"
          ) vulcanConfig.environment.systemPackages;
          nodeRedAdminSudoRule = find "node-red-admin sudo rule" (
            rule: rule.runAs == "node-red-admin:node-red-admin"
          ) vulcanConfig.security.sudo.extraRules;
          nodeRedAdminSudoCommand = find "node-red-admin sudo command" (
            command: command.command == "${nodeRedAdminPackage.nodeRedAdminBackend}/bin/node-red-admin-backend"
          ) nodeRedAdminSudoRule.commands;
          nodeRedAlertmanagerReceiver = find "Node-RED Alertmanager receiver" (
            receiver: receiver.name == "iphone-notifier"
          ) vulcanConfig.services.prometheus.alertmanager.configuration.receivers;
          nodeRedBlackboxJob = find "Node-RED blackbox job" (
            job: job.job_name == "blackbox_iphone_relay"
          ) vulcanConfig.services.prometheus.scrapeConfigs;
          nodeRedPrometheusJob = find "Node-RED Prometheus job" (
            job: job.job_name == "node-red"
          ) vulcanConfig.services.prometheus.scrapeConfigs;
          nodeRedAdminContract = pkgs.writeText "node-red-admin-contract.json" (
            builtins.toJSON {
              inherit port;
              sysctl = vulcanConfig.boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start";
              upstreams = builtins.attrNames vulcanConfig.services.nginx.upstreams."node-red".servers;
              ambientCapabilities = vulcanConfig.systemd.services.node-red.serviceConfig.AmbientCapabilities;
              capabilityBoundingSet = vulcanConfig.systemd.services.node-red.serviceConfig.CapabilityBoundingSet;
              secret = {
                inherit (vulcanConfig.sops.secrets."node-red-admin-token") owner group mode;
              };
              user = {
                inherit (vulcanConfig.users.users.node-red-admin) isSystemUser group;
              };
              sudo = {
                inherit (nodeRedAdminSudoRule) users runAs;
                inherit (nodeRedAdminSudoCommand) command options;
              };
              alertmanagerUrl = (builtins.head nodeRedAlertmanagerReceiver.webhook_configs).url;
              blackboxTarget = builtins.head (builtins.head nodeRedBlackboxJob.static_configs).targets;
              prometheusTarget = builtins.head (builtins.head nodeRedPrometheusJob.static_configs).targets;
              frontend = "${nodeRedAdminPackage}/bin/node-red-admin";
              backend = "${nodeRedAdminPackage.nodeRedAdminBackend}/bin/node-red-admin-backend";
              source = nodeRedAdminPackage.nodeRedAdminSource;
              inherit (pkgs) bash coreutils;
              python = pkgs.python3;
            }
          );
        in
        {
          vulcan-input-policy =
            assert toString vulcan.pkgs.path == toString inputs.nixpkgs.outPath;
            assert vulcanConfig.home-manager.useGlobalPkgs == false;
            assert
              toString vulcanConfig.home-manager.extraSpecialArgs.inputs.nixpkgs.outPath
              == toString inputs.nixpkgs-user.outPath;
            assert toString inputs.nixpkgs.outPath != toString inputs.nixpkgs-user.outPath;
            assert builtins.elem userPkgs.ripgrep vulcanConfig.environment.systemPackages;
            assert builtins.elem userPkgs.task-master-ai vulcanConfig.environment.systemPackages;
            assert builtins.elem userPkgs.gitea vulcanConfig.environment.systemPackages;
            assert !builtins.elem vulcan.pkgs.ripgrep vulcanConfig.environment.systemPackages;
            assert !builtins.elem vulcan.pkgs.task-master-ai vulcanConfig.environment.systemPackages;
            assert !builtins.elem vulcan.pkgs.gitea vulcanConfig.environment.systemPackages;
            assert pkgs.lib.hasInfix "nix flake update --flake /etc/nixos nix-config nix-config-ai pi"
              buildSource;
            pkgs.runCommand "vulcan-input-policy-check" { } "touch $out";
          session-gather-ssh-config =
            pkgs.runCommand "session-gather-ssh-config-check"
              {
                nativeBuildInputs = [ pkgs.openssh ];
              }
              ''
                effective_user() {
                  ssh -G -F ${sessionGatherSshConfig} "$1" 2>/dev/null | sed -n 's/^user //p'
                }

                test "$(effective_user hera)" = johnw
                test "$(effective_user clio)" = johnw
                test "$(effective_user vps)" = johnw
                test "$(effective_user andoria-08)" = jwiegley
                test "$(ssh -G -F ${sessionGatherSshConfig} andoria-08 2>/dev/null | sed -n 's/^proxyjump //p')" = hera
                touch "$out"
              '';

          llama-cpp-overlay-compat =
            assert
              !(builtins.elem pkgs.npmHooks.npmConfigHook (pkgs.llama-cpp.nativeBuildInputs or [ ]))
              || pkgs.llama-cpp ? npmDeps;
            pkgs.runCommand "llama-cpp-overlay-compat-check" { } "touch $out";

          hermes-searxng-tls =
            let
              hermesPython = inputs.hermes-agent.packages.${system}.default.hermesVenv;
            in
            pkgs.runCommand "hermes-searxng-tls-check"
              {
                nativeBuildInputs = [ pkgs.openssl ];
              }
              ''
                openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
                  -subj /CN=Hermes-Test-CA -keyout ca.key -out ca.crt >/dev/null 2>&1
                openssl req -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 \
                  -keyout server.key -out server.csr >/dev/null 2>&1
                printf '%s\n' 'subjectAltName=IP:127.0.0.1' 'extendedKeyUsage=serverAuth' >server.ext
                openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
                  -CAcreateserial -days 1 -out server.crt -extfile server.ext >/dev/null 2>&1

                env -i HOME="$TMPDIR" PYTHONDONTWRITEBYTECODE=1 \
                  ${hermesPython}/bin/python3 ${./tests/hermes-searxng-tls.py} \
                  server.crt server.key fail
                env -i HOME="$TMPDIR" PYTHONDONTWRITEBYTECODE=1 SSL_CERT_FILE="$PWD/ca.crt" \
                  ${hermesPython}/bin/python3 ${./tests/hermes-searxng-tls.py} \
                  server.crt server.key succeed
                touch "$out"
              '';

          hermes-self-heal-tests = helpers.mkPytestCheck {
            name = "hermes-self-heal-tests";
            src = ./scripts/hermes-self-heal;
            suiteDir = "tests";
          };

          agent-health-report-tests = helpers.mkPytestCheck {
            name = "agent-health-report-tests";
            src = ./scripts;
            suiteDir = "agent-health-report-tests";
          };

          node-red-admin-tests =
            let
              pytestPython = pkgs.python312.withPackages (ps: [ ps.pytest ]);
            in
            pkgs.runCommand "node-red-admin-tests-check"
              {
                nativeBuildInputs = [
                  pkgs.nodejs
                  pytestPython
                ];
              }
              ''
                set -euo pipefail
                mkdir -p suite suite/docs
                cp -r ${./config} suite/config
                cp -r ${./hosts} suite/hosts
                cp -r ${./modules} suite/modules
                cp -r ${./scripts} suite/scripts
                cp -r ${./tests} suite/tests
                cp ${./docs/ports.txt} suite/docs/ports.txt
                chmod -R +w suite
                export NODE_RED_ADMIN_CONTRACT=${nodeRedAdminContract}
                cd suite
                ${pytestPython}/bin/pytest scripts/node-red-admin/tests -v
                touch "$out"
              '';

          # The largest suite in the repo (16 files) and, until 2026-08-05, the
          # only one that never ran in CI -- so it passed or failed only when
          # someone ran it by hand. It needs more than bare pytest: the module
          # imports psycopg2/requests and the tests use pytest-mock, responses
          # and freezegun.
          flume-data-tests = helpers.mkPytestCheck {
            name = "flume-data-tests";
            src = ./scripts/flume-data;
            suiteDir = "tests";
            extraPackages = ps: [
              ps.pytest-mock
              ps.responses
              ps.freezegun
              ps.psycopg2
              ps.requests
              ps.python-dateutil
              ps.pyyaml
            ];
          };

          # Behaviour of the Qdrant memory write-filter. The suite parses the
          # pattern list out of hermes-vm.nix, so the sandbox needs that one
          # file alongside it -- assembled here rather than handing the check
          # the whole repo, which would rebuild it on every unrelated commit.
          hermes-write-filter-tests = helpers.mkPytestCheck {
            name = "hermes-write-filter-tests";
            src = pkgs.runCommand "hermes-write-filter-src" { } ''
              mkdir -p "$out/tests"
              cp ${./tests/hermes-write-filter}/*.py "$out/tests/"
              cp ${./modules/services/hermes-vm.nix} "$out/hermes-vm.nix"
            '';
            suiteDir = "tests";
          };

          drafts-mcp-check-tests = helpers.mkPytestCheck {
            name = "drafts-mcp-check-tests";
            src = ./scripts/drafts-mcp-check;
            suiteDir = "tests";
          };

          open-source-secretary = inputs.self.packages.${system}.open-source-secretary;
        };
    };
}
