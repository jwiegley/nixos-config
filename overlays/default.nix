inputs: system: final: prev:
let
  # Import the package definitions to capture paths at evaluation time
  hacsFrontendDef = import ./hacs-frontend.nix;
  miniRacerDef = import ./mini-racer.nix;
  copypartyDef = import ./copyparty.nix;

  # Import Haskell overlay to fix broken packages
  haskellOverlay = import ./haskell-sizes.nix;

  # Import check-systemd overlay to add reload-notify support
  checkSystemdOverlay = import ./check-systemd.nix;

  # Apply Haskell overlay first to get patched haskellPackages
  prevWithHaskell = prev // (haskellOverlay final prev);

  # Apply check-systemd overlay
  prevWithCheckSystemd = prevWithHaskell // (checkSystemdOverlay final prevWithHaskell);

  # wrapBuddy with 16K page size support for Asahi Linux
  # The upstream wrapBuddy uses hardcoded PAGE_SIZE=4096, but Asahi Linux
  # uses 16K pages due to Apple Silicon IOMMU requirements.
  # This causes mprotect() to fail with EINVAL when trying to restore
  # original entry point bytes at 4K-aligned addresses on a 16K page system.
  #
  # The llm-agents wrapBuddy has three components:
  # 1. wrap-buddy-loader (C binary with PAGE_SIZE)
  # 2. wrap-buddy (Python script that references the loader)
  # 3. wrap-buddy-hook (setup hook)
  #
  # We rebuild from source with patched PAGE_SIZE.
  wrapBuddy-16k =
    let
      # Get the original wrapBuddy source
      originalWrapBuddy = inputs.llm-agents.packages.${system}.wrapBuddy;

      # Build patched loader with 16K page size
      wrap-buddy-loader-16k = prev.stdenv.mkDerivation {
        pname = "wrap-buddy-loader-16k";
        version = "0.3.0";

        # Use the same source as the original llm-agents flake
        src = prev.fetchFromGitHub {
          owner = "numtide";
          repo = "llm-agents.nix";
          rev = "98185694332ee75319f8139fcc751eea9426bde7";
          hash = "sha256-dMOdwzCdJeJHRVT2udM3cziJAsxMOO0wHjeZ2WWhzk0=";
        };

        sourceRoot = "source/packages/wrapBuddy";

        nativeBuildInputs = [ prev.binutils ];

        # Patch PAGE_SIZE from 4096 to 16384 for Asahi Linux 16K pages
        postPatch = ''
          echo "Patching types.h for 16K page size (Asahi Linux)"
          substituteInPlace types.h \
            --replace-fail '#define PAGE_SIZE 4096' '#define PAGE_SIZE 16384'
        '';

        buildPhase = ''
          runHook preBuild

          # Compile loader to ELF, then extract flat binary with objcopy
          arch_flags=""
          if [[ "$($CC -dumpmachine)" == aarch64* ]]; then
            arch_flags="-mcmodel=tiny"
          fi
          $CC -nostdlib -fPIC -fno-stack-protector \
            -fno-exceptions -fno-unwind-tables \
            -fno-asynchronous-unwind-tables -fno-builtin \
            -Os -I. $arch_flags \
            -Wl,-T,preamble.ld \
            -Wl,-e,_start \
            -Wl,-Ttext=0 \
            -o loader.elf loader.c
          objcopy -O binary --only-section=.all loader.elf loader.bin

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp loader.bin $out/loader.bin
          runHook postInstall
        '';

        meta = {
          description = "wrapBuddy loader with 16K page size support for Asahi Linux";
          license = prev.lib.licenses.mit;
          platforms = [ "aarch64-linux" ];
        };
      };

      # Build the Python script with patched loader path
      wrap-buddy-script-16k = prev.stdenv.mkDerivation {
        pname = "wrap-buddy-16k";
        version = "0.3.0";

        src = prev.fetchFromGitHub {
          owner = "numtide";
          repo = "llm-agents.nix";
          rev = "98185694332ee75319f8139fcc751eea9426bde7";
          hash = "sha256-dMOdwzCdJeJHRVT2udM3cziJAsxMOO0wHjeZ2WWhzk0=";
        };

        sourceRoot = "source/packages/wrapBuddy";

        buildInputs = [
          (prev.python3.withPackages (ps: [ ps.pyelftools ]))
        ];

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin $out/share/wrap-buddy

          # Install the main script with substituted loader path
          substitute wrap-buddy.py $out/bin/wrap-buddy \
            --replace-fail "@loader_path@" "${wrap-buddy-loader-16k}/loader.bin"
          chmod +x $out/bin/wrap-buddy

          # Also patch the hardcoded PAGE_SIZE in the Python script
          substituteInPlace $out/bin/wrap-buddy \
            --replace-fail 'PAGE_SIZE = 4096' 'PAGE_SIZE = 16384'

          # Install source files for stub compilation
          cp arch.h common.h types.h preamble.ld $out/share/wrap-buddy/
          # Patch types.h in shared files too
          substituteInPlace $out/share/wrap-buddy/types.h \
            --replace-fail '#define PAGE_SIZE 4096' '#define PAGE_SIZE 16384'
          install -Dm644 stub.c $out/share/wrap-buddy/stub.c

          runHook postInstall
        '';

        meta = {
          description = "wrapBuddy script with 16K page size support for Asahi Linux";
          license = prev.lib.licenses.mit;
          platforms = [ "aarch64-linux" ];
          mainProgram = "wrap-buddy";
        };
      };
    in
    # Create the hook that references our patched script
    prev.runCommand "wrap-buddy-hook-16k" {
      propagatedBuildInputs = [ wrap-buddy-script-16k ];
    } ''
      mkdir -p $out/nix-support

      cat > $out/nix-support/setup-hook << HOOK
      # shellcheck shell=bash

      declare -a wrapBuddyLibs
      declare -a extraWrapBuddyLibs

      gatherWrapBuddyLibs() {
        if [[ -d "\$1/lib" ]]; then
          wrapBuddyLibs+=("\$1/lib")
        fi
      }

      addEnvHooks "\$targetOffset" gatherWrapBuddyLibs

      addWrapBuddySearchPath() {
        local dir
        for dir in "\$@"; do
          if [[ -d \$dir ]]; then
            extraWrapBuddyLibs+=("\$dir")
          fi
        done
      }

      declare -a wrapBuddyRuntimeDeps

      addWrapBuddyRuntimeDeps() {
        local dep
        for dep in "\$@"; do
          if [[ -d "\$dep/lib" ]]; then
            wrapBuddyRuntimeDeps+=("\$dep/lib")
          elif [[ -d \$dep ]]; then
            wrapBuddyRuntimeDeps+=("\$dep")
          fi
        done
      }

      wrapBuddy() {
        local norecurse=

        while [ \$# -gt 0 ]; do
          case "\$1" in
          --) shift; break ;;
          --no-recurse) shift; norecurse=1 ;;
          --*) echo "wrapBuddy: ERROR: Invalid argument: \$1" >&2; return 1 ;;
          *) break ;;
          esac
        done

        echo "wrapBuddy: wrapping paths: \$*"

        if [[ -n \''${runtimeDependencies:-} ]]; then
          addWrapBuddyRuntimeDeps \$runtimeDependencies
        fi

        ${wrap-buddy-script-16k}/bin/wrap-buddy \\
          \''${norecurse:+--no-recurse} \\
          --paths "\$@" \\
          --libs "\''${wrapBuddyLibs[@]}" "\''${extraWrapBuddyLibs[@]}" \\
          \''${wrapBuddyRuntimeDeps:+--runtime-dependencies "\''${wrapBuddyRuntimeDeps[@]}"}
      }

      wrapBuddyPostFixup() {
        if [[ -n \''${dontWrapBuddy:-} ]]; then
          return
        fi

        wrapBuddy -- \$(for output in \$(getAllOutputNames); do
          [ -e "\''${!output}" ] || continue
          [ "\''${output}" = debug ] && continue
          echo "\''${!output}"
        done)
      }

      postFixupHooks+=(wrapBuddyPostFixup)
      HOOK
    '';
in
{
  inherit (import ./dirscan.nix final prevWithCheckSystemd) dirscan;

  # Inherit the patched haskellPackages from the Haskell overlay
  inherit (prevWithHaskell) haskellPackages;

  # Inherit the patched check_systemd from the check-systemd overlay
  inherit (prevWithCheckSystemd) check_systemd;
  # Extend Python package sets system-wide using pythonPackagesExtensions
  # This ensures all Python derivations (including Home Assistant's) get our custom packages
  pythonPackagesExtensions = prev.pythonPackagesExtensions or [] ++ [
    (pyfinal: pyprev: {
      # HACS frontend package
      hacs-frontend = pyfinal.callPackage hacsFrontendDef { };

      # Mini-racer: V8 JavaScript engine for Python (required by Dreame Vacuum)
      # Use underscore to match Python package naming and avoid Nix identifier issues
      mini_racer = pyfinal.callPackage miniRacerDef { };

      # Copyparty: Portable file server with media features
      copyparty = pyfinal.callPackage copypartyDef { };
    })
  ];

  home-assistant-custom-components = prev.home-assistant-custom-components or {} // {
    # HACS - Home Assistant Community Store
    hacs = final.callPackage ./hacs.nix {
      hacs-frontend = final.python3Packages.hacs-frontend;
    };

    # Pentair IntelliCenter Integration
    intellicenter = final.callPackage ./intellicenter.nix { };
  };

  llama-cpp = (prev.llama-cpp.override {
    vulkanSupport = true;  # Compiled but buggy on Asahi - don't use -ngl flag
    blasSupport = true;    # Enable BLAS for optimized CPU inference
  }).overrideAttrs(attrs: rec {
    version = "6721";
    src = prev.fetchFromGitHub {
      owner = "ggml-org";
      repo = "llama.cpp";
      tag = "b${version}";
      hash = "sha256-saqnRL04KZSMAdoo1AuqoivmN4kG5Lfaxg4AYk24JJg=";
    };
  });

  llama-swap =
  let
    version = "164";

    src = prev.fetchFromGitHub {
      owner = "mostlygeek";
      repo = "llama-swap";
      rev = "v${version}";
      hash = "sha256-Br3CES4j78nev858qw+TeTSJ74kjKAErHFCMg9cAZSc=";
    };

    ui = with prev; buildNpmPackage (finalAttrs: {
      pname = "llama-swap-ui";
      inherit version src;

      postPatch = ''
        substituteInPlace vite.config.ts \
        --replace '../proxy/ui_dist' '${placeholder "out"}/ui_dist'
      '';

      sourceRoot = "source/ui";

      npmDepsHash = "sha256-F6izMZY4554M6PqPYjKcjNol3A6BZHHYA0CIcNrU5JA=";

      postInstall = ''
        rm -rf $out/lib
      '';

      meta = {
        description = "llama-swap - UI";
        license = lib.licenses.mit;
        platforms = lib.platforms.unix;
      };
    });
  in
  with prev; llama-swap.overrideAttrs(attrs: rec {
    inherit version src;
    vendorHash = "sha256-5mmciFAGe8ZEIQvXejhYN+ocJL3wOVwevIieDuokhGU=";
    preBuild = ''
      cp -r ${ui}/ui_dist proxy/
    '';
    ldflags = [
      "-X main.version=${version}"
      "-X main.date=unknown"
      "-X main.commit=v${version}"
    ];
    doCheck = false;
    meta = {
      description = "Model swapping for llama.cpp (or any local OpenAPI compatible server)";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
      mainProgram = "llama-swap";
    };
  });

  # Claude Code - Fix for 16K page size (Apple Silicon / Asahi Linux)
  #
  # Two fixes are needed:
  # 1. Replace bundled ripgrep (compiled with jemalloc for 4K pages)
  # 2. Use patched wrapBuddy with 16K page size support
  #
  # The wrapBuddy loader uses hardcoded PAGE_SIZE=4096, causing mprotect() to fail
  # with EINVAL when restoring original entry bytes at 4K-aligned addresses on 16K pages.
  claude-code =
    let
      upstreamWrapBuddy = inputs.llm-agents.packages.${system}.wrapBuddy;
    in
    inputs.llm-agents.packages.${system}.claude-code.overrideAttrs (oldAttrs: {
      # Replace wrapBuddy with our 16K page size patched version in nativeBuildInputs
      nativeBuildInputs = map (dep:
        if dep == upstreamWrapBuddy then wrapBuddy-16k else dep
      ) (oldAttrs.nativeBuildInputs or []);

      preFixup = (oldAttrs.preFixup or "") + ''
        # Replace bundled arm64-linux ripgrep with system ripgrep
        # This fixes crashes caused by jemalloc 4K/16K page size incompatibility
        rg_path="$out/lib/node_modules/@anthropic-ai/claude-code/vendor/ripgrep/arm64-linux/rg"
        if [ -f "$rg_path" ]; then
          echo "Replacing bundled ripgrep with system ripgrep (16K page size compatible)"
          chmod +w "$(dirname "$rg_path")"
          rm -f "$rg_path"
          ln -s ${final.ripgrep}/bin/rg "$rg_path"
        fi
      '';
    });
  claude-code-acp = inputs.llm-agents.packages.${system}.claude-code-acp;
  ccusage = inputs.llm-agents.packages.${system}.ccusage;

  # Droid (Factory AI) - Fix for 16K page size (Apple Silicon / Asahi Linux)
  # Same wrapBuddy fix as claude-code above
  droid =
    let
      upstreamWrapBuddy = inputs.llm-agents.packages.${system}.wrapBuddy;
    in
    inputs.llm-agents.packages.${system}.droid.overrideAttrs (oldAttrs: {
      nativeBuildInputs = map (dep:
        if dep == upstreamWrapBuddy then wrapBuddy-16k else dep
      ) (oldAttrs.nativeBuildInputs or []);
    });

  # Rspamd - Update to 3.13.2 to fix lua_magic empty text part errors
  # Version 3.13.0 has a bug that causes errors when processing emails with empty text parts
  # Fixed in 3.13.1+, using 3.13.2 (more stable than 3.14.0 which crashes on AARCH64)
  # 3.14.0 has Lua API crash: "invalid option '%.' to 'lua_pushfstring'" on ARM64
  rspamd = prev.rspamd.overrideAttrs (oldAttrs: {
    version = "3.13.2";
    src = prev.fetchFromGitHub {
      owner = "rspamd";
      repo = "rspamd";
      rev = "3.13.2";
      hash = "sha256-lfMU9o/wnHHAnfRUUNto1edZjXI32q847ZQkSoekg5o=";
    };
    # Remove patches that are already included in 3.13.2
    patches = [];
  });

  # n8n - Update to 1.120.3 to fix workflow execution bug in 1.118.2
  # Version 1.118.2 has a critical bug (upstream issue #21647) that prevents
  # workflow execution with "problem running workflow - lost connection" error
  # Fixed in 1.120.x series
  n8n = prev.n8n.overrideAttrs (oldAttrs: {
    version = "1.120.3";
    src = prev.fetchFromGitHub {
      owner = "n8n-io";
      repo = "n8n";
      rev = "n8n@1.120.3";
      hash = "sha256-bKMOK0Z6gGSEdtGdFc9YsaCeRwUM5mCTGQjB+bWmfLM=";
    };
    pnpmDeps = oldAttrs.pnpmDeps.overrideAttrs {
      outputHash = "sha256-YvDszeLaATHqiEU7bakiS4a0lvcl+NbRX7ggoHbVMFM=";
    };
  });

  # ZFS - Enable support for 16K page size (Apple Silicon / Asahi Linux)
  # EXPERIMENTAL: This may cause data corruption - use at your own risk!
  #
  # Based on workaround from: https://github.com/openzfs/zfs/issues/16429
  # Asahi Linux uses 16KB pages due to M1/M2 IOMMU hardware requirements
  #
  # The Fedora Asahi workaround involves changing kernel-devel dependencies.
  # For NixOS, we build from source, so we just need to ensure it builds
  # against the Asahi kernel and doesn't have hardcoded PAGE_SIZE checks.

  zfs_unstable = prev.zfs_unstable.overrideAttrs (oldAttrs: {
    meta = oldAttrs.meta // {
      description = oldAttrs.meta.description + " (patched for 16K page size)";
      broken = false;  # Un-break if marked broken on aarch64 with 16K pages
    };

    # Note: If build fails with PAGE_SIZE errors, we'll need to add patches here
    # to disable PAGE_SIZE checks in configure scripts or source code
  });

  # Also override the stable ZFS variant
  zfs = prev.zfs.overrideAttrs (oldAttrs: {
    meta = oldAttrs.meta // {
      description = oldAttrs.meta.description + " (patched for 16K page size)";
      broken = false;
    };
  });

  # Factory CLI - Fix for aarch64-linux (steam-run is x86-only)
  # The upstream factory-cli-nix overlay uses steam-run which doesn't work on ARM64.
  # The ARM64 binary runs natively without FHS wrapper, just needs ripgrep in PATH.
  factory-cli =
    let
      version = "0.25.1";
      baseUrl = "https://downloads.factory.ai";
      droidSrc = prev.fetchurl {
        url = "${baseUrl}/factory-cli/releases/${version}/linux/arm64/droid";
        hash = "sha256-O/FROT/QqHZsZXhWbbQhe7ktl+wAeXYiJLOKVX4DSM0=";
      };
    in
    prev.stdenv.mkDerivation {
      pname = "factory-cli";
      inherit version;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      dontCheck = true;
      dontStrip = true;

      nativeBuildInputs = [ prev.makeWrapper ];

      installPhase = ''
        runHook preInstall
        install -Dm755 ${droidSrc} "$out/bin/droid-unwrapped"
        mkdir -p "$out/bin"

        # Create wrapper that adds ripgrep to PATH
        # The binary runs natively on aarch64-linux without FHS wrapper
        makeWrapper "$out/bin/droid-unwrapped" "$out/bin/droid" \
          --prefix PATH : ${prev.lib.makeBinPath [ prev.ripgrep ]}

        runHook postInstall
      '';

      meta = {
        description = "Command-line interface for Factory AI (aarch64-linux)";
        homepage = "https://factory.ai/";
        license = prev.lib.licenses.unfree;
        platforms = [ "aarch64-linux" ];
      };
    };
}
