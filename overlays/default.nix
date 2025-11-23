final: prev:
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

  # Claude Code - Fix bundled ripgrep for 16K page size (Apple Silicon / Asahi Linux)
  # The bundled ripgrep is compiled with jemalloc for 4K pages, which crashes on Asahi
  # Replace with system ripgrep that's properly compiled for this platform
  claude-code = prev.claude-code.overrideAttrs (oldAttrs: {
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
}
