inputs: system: final: prev:
let
  # Import the package definitions to capture paths at evaluation time
  hacsFrontendDef = import ./hacs-frontend.nix;
  miniRacerDef = import ./mini-racer.nix;
  copypartyDef = import ./copyparty.nix;
  vobjectDef = import ./vobject.nix;
  pyLetsBeRationalDef = import ./py-lets-be-rational.nix;
  pyVollibDef = import ./py-vollib.nix;
  curlCffiDef = import ./curl-cffi.nix;
  requestsFuturesDef = import ./requests-futures.nix;
  yahooqueryDef = import ./yahooquery.nix;
  radicaleVcard4Def = import ./radicale-vcard4.nix;

  # Import Haskell overlay to fix broken packages
  haskellOverlay = import ./haskell-sizes.nix;

  # Import check-systemd overlay to add reload-notify support
  checkSystemdOverlay = import ./check-systemd.nix;

  # Apply Haskell overlay first to get patched haskellPackages
  prevWithHaskell = prev // (haskellOverlay final prev);

  # Apply check-systemd overlay
  prevWithCheckSystemd = prevWithHaskell // (checkSystemdOverlay final prevWithHaskell);

  # Fix script for aiopnsense Python 2-style except clauses (used in haPackageOverrides)
  aiopnsenseFixScript = prev.writeText "fix-aiopnsense-py2-except.py" ''
    import re, os

    pattern = re.compile(
        r"^(\s*)except ([A-Za-z][A-Za-z0-9_.]*(?:\s*,\s*[A-Za-z][A-Za-z0-9_.]*)+)\s*:",
        re.MULTILINE
    )

    for root, dirs, files in os.walk("."):
        for name in files:
            if not name.endswith(".py"):
                continue
            path = os.path.join(root, name)
            with open(path) as f:
                content = f.read()
            new_content = pattern.sub(
                lambda m: m.group(1) + "except (" + m.group(2) + "):",
                content
            )
            if new_content != content:
                with open(path, "w") as f:
                    f.write(new_content)
  '';

  # Custom Python packages for Home Assistant (Python 3.14 from nixpkgs-unstable).
  # These are not in nixpkgs, so injected via HA's packageOverrides.
  # After injection: accessible as ps.xxx in extraPackages and as
  # pkgs.home-assistant.python.pkgs.xxx for buildHomeAssistantComponent dependencies.
  haPackageOverrides = hasPy: hasPyPrev: {
    # Several packages mark disabled=true for Python 3.14 in nixpkgs-unstable,
    # but they work fine at runtime. HA 2026.x requires Python 3.14 and uses these.
    # Tests fail: asyncio.get_event_loop() raises RuntimeError in Python 3.14;
    # skip tests, the library itself functions correctly at runtime.
    reactivex = hasPyPrev.reactivex.overridePythonAttrs (_: {
      disabled = false;
      doCheck = false;
    });
    # aiounittest: redundant in Python 3.10+ (stdlib has IsolatedAsyncioTestCase)
    # but still works; needed as nativeBuildInput by yalexs (august/yale integration).
    # Test failures: asyncio.get_event_loop() raises RuntimeError in Python 3.14
    # without active event loop. Skip tests; the library itself is fine.
    aiounittest = hasPyPrev.aiounittest.overridePythonAttrs (_: {
      disabled = false;
      doCheck = false;
    });

    # HACS frontend (JS/HTML data package for the HACS custom component)
    hacs-frontend = hasPy.callPackage hacsFrontendDef { };
    hacs_frontend = hasPy.callPackage hacsFrontendDef { };

    # mini-racer: V8 JavaScript engine (required by Dreame Vacuum integration)
    mini_racer = hasPy.callPackage miniRacerDef { };

    # securelogging: Hubspace integration dependency
    securelogging = hasPy.buildPythonPackage rec {
      pname = "securelogging";
      version = "1.0.1";
      format = "wheel";
      src = prev.fetchPypi {
        inherit pname version format;
        dist = "py3";
        python = "py3";
        sha256 = "sha256-0URfkqVVXZRwLuwH/yU+4XvWOrpb3T5q8ew/eynhpQw=";
      };
      doCheck = false;
    };

    # aioafero: Hubspace (Afero cloud) async client
    aioafero = hasPy.buildPythonPackage rec {
      pname = "aioafero";
      version = "6.0.1";
      pyproject = true;
      src = prev.fetchPypi {
        inherit pname version;
        sha256 = "1a66e3e4e9dae32295b136e5ca87536e73f5143c16dae8bbebe421f0e895e7ac";
      };
      build-system = with hasPy; [ hatchling ];
      dependencies = with hasPy; [
        aiohttp
        beautifulsoup4
        securelogging
      ];
      doCheck = false;
    };

    # pybose: Bose SoundTouch async client
    pybose = hasPy.buildPythonPackage rec {
      pname = "pybose";
      version = "2025.8.2";
      pyproject = true;
      src = prev.fetchPypi {
        inherit pname version;
        sha256 = "47c2a4c96b9c8ca59d0f275e6feaef30bb641b4c11c97d65d8c5f036d558f28a";
      };
      build-system = with hasPy; [ setuptools ];
      dependencies = with hasPy; [
        zeroconf
        websockets
      ];
      doCheck = false;
    };

    # pywaze: Waze travel time async client
    pywaze = hasPy.buildPythonPackage rec {
      pname = "pywaze";
      version = "1.1.1";
      format = "wheel";
      src = prev.fetchPypi {
        inherit pname version format;
        dist = "py3";
        python = "py3";
        sha256 = "0hil7r00ifbyg57hgbfziv3ra25g036aph53975ny17wifq211j0";
      };
      dependencies = with hasPy; [ httpx ];
      doCheck = false;
    };

    # pykumo: Mitsubishi Kumo Cloud (mini-split AC) client
    pykumo = hasPy.buildPythonPackage rec {
      pname = "pykumo";
      version = "0.3.10";
      format = "wheel";
      src = prev.fetchPypi {
        inherit pname version format;
        dist = "py3";
        python = "py3";
        sha256 = "sha256-I1bIGd1YEtSJHhCLBh2brQtugJhjTmSGKoJpwPBBr2g=";
      };
      dependencies = with hasPy; [ requests ];
      doCheck = false;
    };

    # opower: SMUD Okta SSO redirect fix (same patch as pythonPackagesExtensions).
    # HA 2026.x uses unstable's opower 0.18.0; the SMUD redirectUrl KeyError
    # still exists in 0.18.0, so we apply the same patch here.
    opower = hasPyPrev.opower.overridePythonAttrs (oldAttrs: {
      patches = (oldAttrs.patches or [ ]) ++ [
        ./opower-smud-fix.patch
      ];
    });

    # aiopnsense: OPNsense API client (patched: Python 2-style except → Python 3)
    aiopnsense = hasPy.buildPythonPackage rec {
      pname = "aiopnsense";
      version = "1.0.4";
      pyproject = true;
      src = prev.fetchPypi {
        inherit pname version;
        hash = "sha256-jNsdOy5JjRqJefXgF2OZzCyokXaU07wAg22MnnRn5FE=";
      };
      build-system = with hasPy; [ setuptools ];
      postPatch = ''
        python3 ${aiopnsenseFixScript}
        substituteInPlace pyproject.toml \
          --replace-fail 'requires-python = ">=3.14"' 'requires-python = ">=3.13"'
      '';
      dependencies = with hasPy; [
        aiohttp
        awesomeversion
        python-dateutil
      ];
      doCheck = false;
    };
  };
in
{
  inherit (import ./dirscan.nix final prevWithCheckSystemd) dirscan;

  # Import package definitions from nix-config overlays.
  # Pass `inputs` via prev so that paths.nix (used by data-tools, text-tools)
  # can resolve flake input sources.
  inherit
    (import "${inputs.nix-config}/overlays/30-misc-tools.nix" final (prev // { inherit inputs; }))
    hammer
    linkdups
    lipotell
    ;
  inherit (import "${inputs.nix-config}/overlays/30-markless.nix" final (prev // { inherit inputs; }))
    markless
    ;
  inherit
    (import "${inputs.nix-config}/overlays/30-data-tools.nix" final (prev // { inherit inputs; }))
    tsvutils
    ;
  inherit
    (import "${inputs.nix-config}/overlays/30-text-tools.nix" final (prev // { inherit inputs; }))
    filetags
    ;

  # John Wiegley's git helper scripts (provides git-merge-changelog, etc.)
  git-scripts =
    with prev;
    stdenv.mkDerivation {
      name = "git-scripts";
      src = inputs.git-scripts;
      installPhase = ''
        mkdir -p $out/bin
        find . -maxdepth 1 \( -type f -o -type l \) -executable \
            -exec cp -pL {} $out/bin \;
      '';
      meta = with lib; {
        description = "John Wiegley's git scripts";
        license = licenses.mit;
        platforms = platforms.unix;
      };
    };

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
      d2l =
        let
          # The pythonRuntimeDepsCheckHook reads $src (the wheel zip) directly
          # and checks pinned Requires-Dist entries. d2l-1.0.3 has very old pins
          # (numpy==1.23.5, matplotlib==3.7.2, etc.) that fail against current
          # nixpkgs. Create a patched wheel with relaxed pins so the check passes.
          originalWheel = unstable.fetchurl {
            url = "https://files.pythonhosted.org/packages/8b/39/418ef003ed7ec0f2a071e24ec3f58c7b1f179ef44bec5224dcca276876e3/d2l-1.0.3-py3-none-any.whl";
            hash = "sha256-xiWgHmbrXXk6fgpvhYKx4eNd+tArXnfz0qspnQcXe6Y=";
          };
          patchedWheel =
            unstable.runCommand "d2l-1.0.3-py3-none-any.whl"
              {
                nativeBuildInputs = [
                  unstable.unzip
                  unstable.zip
                ];
              }
              ''
                unzip -q ${originalWheel} -d wheel-contents
                sed -i -E \
                  -e 's/^(Requires-Dist: numpy).*/\1/' \
                  -e 's/^(Requires-Dist: matplotlib).*/\1/' \
                  -e 's/^(Requires-Dist: requests).*/\1/' \
                  -e 's/^(Requires-Dist: pandas).*/\1/' \
                  -e '/^Requires-Dist: jupyter/d' \
                  -e '/^Requires-Dist: matplotlib-inline/d' \
                  -e '/^Requires-Dist: scipy/d' \
                  wheel-contents/d2l-1.0.3.dist-info/METADATA
                cd wheel-contents
                zip -qr $out .
              '';
        in
        unstable.python3Packages.buildPythonPackage rec {
          pname = "d2l";
          version = "1.0.3";
          format = "wheel";

          src = patchedWheel;

          dependencies = with unstable.python3Packages; [
            numpy
            matplotlib
            requests
            pandas
          ];

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
      d2l # Dive into Deep Learning companion library
    ]);

  # Extend Python package sets system-wide using pythonPackagesExtensions
  # This ensures all Python derivations (including Home Assistant's) get our custom packages
  pythonPackagesExtensions = prev.pythonPackagesExtensions or [ ] ++ [
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

      # py_lets_be_rational: IV algorithm for py_vollib (financial analysis)
      py_lets_be_rational = pyfinal.callPackage pyLetsBeRationalDef { };

      # py_vollib: Options pricing and implied volatility
      py_vollib = pyfinal.callPackage pyVollibDef { };

      # curl-cffi: libcurl bindings with browser impersonation (yahooquery dep)
      curl_cffi = pyfinal.callPackage curlCffiDef { };

      # requests-futures: Async HTTP requests (yahooquery dep)
      requests-futures = pyfinal.callPackage requestsFuturesDef { };

      # yahooquery: Yahoo Finance API wrapper (replaces broken yfinance)
      yahooquery = pyfinal.callPackage yahooqueryDef { };

      # psycopg: Skip flaky pool tests that fail in sandbox
      # test_stats_connect and test_reconnect_after_grow_failed are timing-sensitive
      psycopg = pyprev.psycopg.overridePythonAttrs (oldAttrs: {
        disabledTests = (oldAttrs.disabledTests or [ ]) ++ [
          "test_stats_connect"
          "test_reconnect_after_grow_failed"
        ];
      });

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

      # Opower SMUD login fix: SMUD changed their Okta SSO redirect flow.
      # The energy usage page no longer provides redirectUrl in query params.
      # Check for opower cookies after redirect chain before trying legacy flow.
      # See: https://github.com/tronikos/opower/issues/97
      opower = pyprev.opower.overridePythonAttrs (oldAttrs: {
        patches = (oldAttrs.patches or [ ]) ++ [
          ./opower-smud-fix.patch
        ];
      });
    })
  ];

  home-assistant-custom-components = prev.home-assistant-custom-components or { } // {
    # HACS - Home Assistant Community Store
    # Use HA's own Python package set so sitePackages path and all deps match.
    hacs = final.callPackage ./hacs.nix {
      hacs-frontend = final.home-assistant.python.pkgs."hacs-frontend";
      python3Packages = final.home-assistant.python.pkgs;
    };

    # Pentair IntelliCenter Integration
    intellicenter = final.callPackage ./intellicenter.nix { };
  };

  llama-cpp =
    (prev.llama-cpp.override {
      vulkanSupport = true; # Compiled but buggy on Asahi - don't use -ngl flag
      blasSupport = true; # Enable BLAS for optimized CPU inference
    }).overrideAttrs
      (attrs: rec {
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

      ui =
        with prev;
        buildNpmPackage (finalAttrs: {
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
    with prev;
    llama-swap.overrideAttrs (attrs: rec {
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

  # Claude Code - Disable bundled ripgrep for 16K page size (Apple Silicon / Asahi Linux)
  # The bundled ripgrep (inside the Bun SEA binary) crashes on 16K page systems due to
  # jemalloc/mmap assumptions about 4K pages. Setting USE_BUILTIN_RIPGREP=1 forces
  # Claude Code to use the system rg from PATH instead.
  # Note: despite the name, '1' triggers the system-rg path; '0'/unset uses embedded.
  claude-code = inputs.llm-agents.packages.${system}.claude-code.overrideAttrs (oldAttrs: {
    postFixup = (oldAttrs.postFixup or "") + ''
      sed -i '/^#!.*bash/a export USE_BUILTIN_RIPGREP=1' "$out/bin/claude"
    '';
  });
  claude-code-acp = inputs.llm-agents.packages.${system}.claude-code-acp;
  ccusage = inputs.llm-agents.packages.${system}.ccusage;
  droid = inputs.llm-agents.packages.${system}.droid;

  # Immich - Update to 2.4.1 for Canon CR3 thumbnail fix (PR #24587)
  # Version 2.3.1 incorrectly detects CR3 files as having 1-second duration,
  # causing them to be treated as animated GIFs and displaying "Error loading image"
  # https://github.com/immich-app/immich/issues/24559
  immich = inputs.nixpkgs-unstable.legacyPackages.${system}.immich;

  # Home Assistant - Update to latest (2026.4.1+) from nixpkgs-unstable
  # Stable nixpkgs-25.11 lags behind; unstable tracks HA releases closely.
  # HA 2026.x requires Python 3.14. Use packageOverrides to inject custom
  # packages (aiopnsense, pybose, pywaze, etc.) into HA's own Python 3.14 set.
  home-assistant = inputs.nixpkgs-unstable.legacyPackages.${system}.home-assistant.override {
    packageOverrides = haPackageOverrides;
  };

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
    patches = [ ];
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
      broken = false; # Un-break if marked broken on aarch64 with 16K pages
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
  # claude-vault: Archive Claude Code conversations into searchable SQLite
  inherit (import "${inputs.nix-config}/overlays/30-claude-vault.nix" final prev) claude-vault;
}
