inputs: system: final: prev:
let
  # Import the package definitions to capture paths at evaluation time
  hacsFrontendDef = import ./hacs-frontend.nix;
  miniRacerDef = import ./mini-racer.nix;
  copypartyDef = import ./copyparty.nix;
  vobjectDef = import ./vobject.nix;
  radicaleVcard4Def = import ./radicale-vcard4.nix;

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
  # Python environment for JupyterLab from nixpkgs-unstable
  # Uses unstable's Python to avoid version mismatch (stable has 3.13.9, unstable has 3.13.11)
  # This gives us JupyterLab 4.5.0+ with PyTorch and data science packages
  jupyterlab-env =
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
    in
    let
      # d2l (Dive into Deep Learning) - not in nixpkgs, build from PyPI
      d2l = unstable.python3Packages.buildPythonPackage rec {
        pname = "d2l";
        version = "1.0.3";
        format = "wheel";

        src = unstable.fetchurl {
          url = "https://files.pythonhosted.org/packages/8b/39/418ef003ed7ec0f2a071e24ec3f58c7b1f179ef44bec5224dcca276876e3/d2l-1.0.3-py3-none-any.whl";
          hash = "sha256-xiWgHmbrXXk6fgpvhYKx4eNd+tArXnfz0qspnQcXe6Y=";
        };

        dependencies = with unstable.python3Packages; [
          numpy
          matplotlib
          requests
          pandas
        ];

        # Skip tests - package doesn't include test suite
        doCheck = false;

        meta = {
          description = "Dive into Deep Learning - interactive book companion library";
          homepage = "https://d2l.ai";
          license = unstable.lib.licenses.mit;
        };
      };
    in
    unstable.python3.withPackages (ps: [
      ps.jupyterlab
      ps.ipykernel
      ps.ipywidgets
      ps.jupyterlab-widgets
      # ps.jupyter-collaboration  # Disabled - causes WebSocketClosedError and notebook loading issues
      ps.notebook
      ps.torch
      ps.torchvision
      ps.numpy
      ps.pandas
      ps.matplotlib
      ps.scipy
      ps.scikit-learn
      ps.seaborn
      ps.pillow
      ps.requests
      ps.tqdm

      # Deep Learning books/tutorials
      d2l  # Dive into Deep Learning companion library
    ]);

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

      # vobject: Override with jwiegley's fork for vCard 4.0 support
      # https://github.com/jwiegley/vobject
      vobject = pyfinal.callPackage vobjectDef { };

      # Google Nest SDM - Update to 9.1.2 to fix datetime comparison errors
      # Version 9.1.0 has a bug comparing offset-naive and offset-aware datetimes
      # Fixed in PR #1225 (9.1.1) and PR #1227 (9.1.2) - "Ensure all trait timestamp
      # comparisons are done with timezones"
      google-nest-sdm = pyprev.google-nest-sdm.overridePythonAttrs (oldAttrs: rec {
        version = "9.1.2";
        src = prev.fetchFromGitHub {
          owner = "allenporter";
          repo = "python-google-nest-sdm";
          rev = version;
          hash = "sha256-yElmh+ajNVbjhsnNsUtQ3mJw9fvJtXqgS58iow+Nwi8=";
        };
      });
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

  claude-code = inputs.llm-agents.packages.${system}.claude-code;
  claude-code-acp = inputs.llm-agents.packages.${system}.claude-code-acp;
  ccusage = inputs.llm-agents.packages.${system}.ccusage;
  droid = inputs.llm-agents.packages.${system}.droid;

  # Immich - Update to 2.4.1 for Canon CR3 thumbnail fix (PR #24587)
  # Version 2.3.1 incorrectly detects CR3 files as having 1-second duration,
  # causing them to be treated as animated GIFs and displaying "Error loading image"
  # https://github.com/immich-app/immich/issues/24559
  immich = inputs.nixpkgs-immich.legacyPackages.${system}.immich;

  # Radicale - Override with jwiegley's fork for vCard 4.0 support
  # https://github.com/jwiegley/Radicale
  # Uses the vobject overlay defined in pythonPackagesExtensions above
  radicale = final.callPackage radicaleVcard4Def { };

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
