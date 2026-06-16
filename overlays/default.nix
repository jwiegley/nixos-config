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
  vthermApiDef = import ./vtherm-api.nix;
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

  # Inject `myLib` (mkScriptPackage / mkSimpleGitHubBinary helpers) from
  # nix-config's 00-lib.nix overlay so 30-data-tools, 30-misc-tools, and
  # 30-user-scripts can reference prev.myLib when imported below.
  myLibOverlay = import "${inputs.nix-config}/overlays/00-lib.nix";
  prevWithMyLib =
    prevWithCheckSystemd // (myLibOverlay final prevWithCheckSystemd) // { inherit inputs; };

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

    # homekit-audio-proxy: Audio proxy for HomeKit integrations (missing from nixpkgs)
    homekit-audio-proxy = hasPy.buildPythonPackage rec {
      pname = "homekit-audio-proxy";
      version = "1.2.1";
      format = "wheel";
      src = prev.fetchurl {
        url = "https://files.pythonhosted.org/packages/3f/f1/a44abfc486b5e7feccfbf4d7ec85421d5465b1fcc42416df8c5039dae222/homekit_audio_proxy-1.2.1-py3-none-any.whl";
        hash = "sha256-sa8Z6JeyZRIa71I7+r9dJH2w0AJxXc1RrVidddAIFOo=";
      };
      dependencies = with hasPy; [ cryptography ];
      doCheck = false;
    };

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

    # pyalarmdotcomajax: Event-driven async Python client for Alarm.com.
    # Paired with alarmdotcom v4.0.1-beta.2 (push-based rewrite). We initially
    # auth'd on v3.0.15/0.5.13 because v0.6.x has an MFA-cookie acquisition bug
    # (pyalarmdotcom/alarmdotcom#534); the existing session lets v0.6.x skip that
    # broken codepath. v3.0.15 itself was unusable because its entity code calls
    # _friendly_name_internal which HA 2026.5.x removed.
    pyalarmdotcomajax = hasPy.buildPythonPackage rec {
      pname = "pyalarmdotcomajax";
      version = "0.6.0b9";
      pyproject = true;
      src = prev.fetchPypi {
        inherit pname version;
        hash = "sha256-rgO/SJ/mORK4YIqzaEjWAt0HJ2dOs7I64jUFCSA1/Lc=";
      };
      build-system = with hasPy; [
        setuptools
        setuptools-scm
      ];
      # setuptools-scm needs an explicit version outside a git checkout
      env.SETUPTOOLS_SCM_PRETEND_VERSION = version;
      # Upstream pins pyhumps~=3.8.0 but nixpkgs ships 3.9.0 (API-compatible).
      pythonRelaxDeps = [ "pyhumps" ];
      dependencies = with hasPy; [
        aiohttp
        beautifulsoup4
        mashumaro
        phonenumbers
        python-dateutil
        pyhumps
        typer
      ];
      doCheck = false;
    };

    # vtherm_api: Developer-facing API for the Versatile Thermostat custom component
    vtherm_api = hasPy.callPackage vthermApiDef { };
  };
in
{
  inherit (import ./dirscan.nix final prevWithCheckSystemd) dirscan;

  # Sherlock — read-only database query tool for AI assistants
  inherit (import ./sherlock.nix final prev) sherlock-db;

  # org-jw — Org-mode data tools (semantic search via `org db search`)
  org-jw = inputs.org-jw.packages.${system}.default;

  # sacramento-cluster-ics — Google Sheet → RFC 5545 .ics files
  sac-cluster-ics = inputs.sacramento-cluster-ics.packages.${system}.default;

  # Import package definitions from nix-config overlays.
  # Pass `inputs` via prev so that paths.nix (used by data-tools, text-tools)
  # can resolve flake input sources.
  inherit (import "${inputs.nix-config}/overlays/30-misc-tools.nix" final prevWithMyLib)
    hammer
    linkdups
    lipotell
    ;
  inherit (import "${inputs.nix-config}/overlays/30-markless.nix" final (prev // { inherit inputs; }))
    markless
    ;
  inherit (import "${inputs.nix-config}/overlays/30-data-tools.nix" final prevWithMyLib)
    tsvutils
    ;
  inherit
    (import "${inputs.nix-config}/overlays/30-text-tools.nix" final (prev // { inherit inputs; }))
    filetags
    ;
  inherit (import "${inputs.nix-config}/overlays/30-user-scripts.nix" final prevWithMyLib)
    nix-scripts
    ;

  # AI MCP servers — mirror nix-config's overlays/30-ai-mcp.nix so Claude Code's
  # context-hub (chub-mcp) and pal MCP servers resolve their nix-profile
  # binaries. nix-config is imported flake=false here, so its own
  # `pal-mcp-server` flake input (a Mac-local git+file:// path) is absent;
  # inject the source through the same `inputs.pal-mcp-server` slot the overlay
  # expects, fetched from GitHub instead. We only pull context-hub and
  # pal-mcp-server (their derivations are reused verbatim from nix-config).
  inherit
    (import "${inputs.nix-config}/overlays/30-ai-mcp.nix" final (
      prevWithMyLib
      // {
        inputs = inputs // {
          pal-mcp-server = prev.fetchFromGitHub {
            owner = "BeehiveInnovations";
            repo = "pal-mcp-server";
            rev = "v9.8.2";
            hash = "sha256-/YkoqnWdhrtlfUZ0tiKDAwobDGKR443nB2W92hhHP7Y=";
          };
        };
      }
    ))
    context-hub
    pal-mcp-server
    ;

  # mcp-server-sequential-thinking: nix-config overrideAttrs's a base nixpkgs
  # package that this channel lacks, so take it from nixpkgs-unstable (which
  # has it), the same way JupyterLab/Immich pull newer packages from unstable.
  mcp-server-sequential-thinking =
    inputs.nixpkgs-unstable.legacyPackages.${system}.mcp-server-sequential-thinking;

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

    # waste_collection_schedule v2.24.0 (nixpkgs has 2.10.0) — adds Sacramento County, CA
    # source. Called via the HA python set so deps resolve against the same instances
    # the rest of HA uses (manifestRequirementsCheckHook is strict about this).
    # curl-cffi attribute has a dash, which isn't a valid function-arg identifier;
    # pass it explicitly so the .nix file can name its arg curl_cffi.
    waste_collection_schedule =
      final.home-assistant.python.pkgs.callPackage ./waste_collection_schedule.nix
        {
          curl_cffi = final.home-assistant.python.pkgs."curl-cffi";
        };
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
  home-assistant =
    let
      base = inputs.nixpkgs-unstable.legacyPackages.${system}.home-assistant.override {
        packageOverrides = haPackageOverrides;
      };
    in
    # Compat shim for a passthru rename in the 2026-05-31 nixpkgs-unstable bump:
    # home-assistant's `python` passthru (the interpreter, whose `.pkgs` was the
    # HA python set) became `python3Packages`. Our `buildHomeAssistantComponent`
    # comes from the stable 25.11 channel and still calls
    # `home-assistant.python.pkgs.buildPythonPackage` (and `.python.interpreter`
    # via the manifest-requirements hook); several overlay/module call sites also
    # use `home-assistant.python.pkgs.*` directly. Re-expose `.python` as the
    # backing interpreter with `.pkgs` repointed at the new set so both the old
    # and new idioms resolve — restoring the exact pre-bump behavior.
    # Remove once the stable HA tooling also speaks `.python3Packages` (e.g.
    # buildHomeAssistantComponent sourced from unstable, or stable bumped past the
    # rename) and the remaining `.python.pkgs` call sites are migrated.
    base.overrideAttrs (old: {
      passthru = old.passthru // {
        python = base.python3Packages.python // {
          pkgs = base.python3Packages;
        };
      };
    });

  # Radicale - Override with jwiegley's fork for vCard 4.0 support
  # https://github.com/jwiegley/Radicale
  # Uses the vobject overlay defined in pythonPackagesExtensions above
  radicale = final.callPackage radicaleVcard4Def { };

  # Rspamd - upgraded to 4.0.1 (2026-04-05) which contains the upstream fix
  # for the "invalid option '%.' to 'lua_pushfstring'" panic that previously
  # forced a 3.14.0 -> 3.13.2 downgrade. Root cause was lua_redis.c:765 using
  # the unsupported `%.2f` precision specifier with lua_pushfstring; fixed in
  # rspamd commit 04f1118f5 (Dec 2025), first landed in 3.14.3, present in
  # 3.14.3 / 4.0.0 / 4.0.1. On vulcan this triggered twice in May 2026 when
  # transient Redis timeouts caused all four proxy workers to hit the bug.
  rspamd = prev.rspamd.overrideAttrs (oldAttrs: {
    version = "4.0.1";
    src = prev.fetchFromGitHub {
      owner = "rspamd";
      repo = "rspamd";
      rev = "4.0.1";
      hash = "sha256-8hpplpo57DnOUT1T8jcfGRyIoWySfqrOFrMgH1tept8=";
    };
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

  # cozempic: Context cleaning for Claude Code
  inherit (import ./30-cozempic.nix final prev) cozempic;

  # stock-trader: Python overrides for pip-only deps not in nixpkgs.
  # See pkgs/stock-trader.deps.md for the audit that drives this list.
  # Scoped to the stock-trader derivation only — not injected into
  # pythonPackagesExtensions (which would force every Python derivation
  # on the system to recompile).
  stock-trader-python-overrides = import ../pkgs/python-overrides {
    pkgs = final;
    python = final.python312;
  };

  # stock-trader frontend bundle: React 19 + Vite SPA built from the
  # laptop repo's web/ subdirectory. Consumed by the top-level
  # stock-trader derivation as a sibling artifact under
  # share/stock-trader/web/dist/.
  stock-trader-frontend = final.callPackage ../pkgs/stock-trader-frontend.nix {
    src = inputs.stock-trader;
    version = "0.1.0";
  };

  # stock-trader: top-level derivation. Composes the runtime Python env
  # (with overrides), the frontend bundle, and a wrapped uvicorn entry
  # point. The systemd unit in modules/services/stock-trader.nix runs
  # this package's $out/bin/stock-trader.
  stock-trader = final.callPackage ../pkgs/stock-trader.nix {
    src = inputs.stock-trader;
    version = "0.1.0";
    frontend = final.stock-trader-frontend;
    pythonOverrides = final.stock-trader-python-overrides;
  };

  # hermes-mcp: MCP server bridging OpenClaw to the Hermes Agent microVM
  # over SSE. See docs/superpowers/plans/2026-05-12-openclaw-hermes-mcp-bridge.md
  # for the full design. The systemd unit lands in Task 7.
  hermes-mcp = final.callPackage ../pkgs/hermes-mcp { };

  # Node-RED — bump to upstream maintenance release 4.1.10.
  # See overlays/node-red.nix for the rationale and bump instructions.
  inherit (import ./node-red.nix final prev) node-red;
}
