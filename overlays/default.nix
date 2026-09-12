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

  # Apply Haskell overlay first to get patched haskellPackages
  prevWithHaskell = prev // (haskellOverlay final prev);

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
    # pywizlight: pin to 0.6.3. HA 2026.7.2's wiz component requires
    # pywizlight==0.6.3 (its manifest pins exactly that) and calls
    # self._device.state.pilotResult / .get_brightness(). nixpkgs bumped
    # pywizlight to 0.6.4 (landed here at the 2026-07-20 switch), whose
    # bulb.state is now a list → wiz light/sensor/number platforms crash at
    # setup with "AttributeError: 'list' object has no attribute
    # 'get_brightness'/'pilotResult'/'get_speed'", leaving every light.wiz_*
    # entity `unavailable` (broke the meeting desk-lamp automation).
    # doCheck=false: 0.6.3 is a known-good release; skip the 0.6.4-era test
    # suite against 0.6.3 source. Unpin once nixpkgs' HA is 0.6.4-compatible.
    pywizlight = hasPyPrev.pywizlight.overridePythonAttrs (old: rec {
      version = "0.6.3";
      src = prev.fetchFromGitHub {
        owner = "sbidy";
        repo = "pywizlight";
        tag = "v${version}";
        hash = "sha256-rCoWdqvFLSLNBAHeFJ6f9kZpIg4WyE8VJLpmsYl+gJM=";
      };
      doCheck = false;
    });
    # thinqconnect's local X509Req fix was REMOVED on 2026-09-08: nixpkgs now carries
    # the same fix itself, as csr-generation-fix.patch on python3xxPackages.thinqconnect
    # (verified by reading the patch, not inferred from its name -- it makes the same
    # OpenSSL.crypto.X509Req -> cryptography x509.CertificateSigningRequestBuilder
    # rewrite, and additionally corrects install_requires from pyOpenSSL to
    # cryptography, which the local version did not).
    #
    # Keeping ours would not have been merely redundant, it BROKE the build: the local
    # transform asserted that it found `from OpenSSL import crypto`, and by the time it
    # ran the upstream patch had already replaced that import, so the assert fired --
    # "thinqconnect x509 fix: 'from OpenSSL import crypto' anchor not found". That
    # loud-failure design worked exactly as intended; this is the drop it called for.
    # (overlays/thinqconnect-x509req-fix.py deleted with it.)

    # Several packages mark disabled=true for Python 3.14 in nixpkgs-unstable,
    # but they work fine at runtime. HA 2026.x requires Python 3.14 and uses these.
    # Tests fail: asyncio.get_event_loop() raises RuntimeError in Python 3.14;
    # skip tests, the library itself functions correctly at runtime.
    reactivex = hasPyPrev.reactivex.overridePythonAttrs (_: {
      disabled = false;
      doCheck = false;
    });
    # aioimaplib: two tests fail under Python 3.14, and the fault is in CPython's
    # stdlib rather than in this library. test_imapserver_imaplib.py drives
    # aioimaplib's mock IMAP *server* using the stdlib `imaplib` client, and 3.14's
    # imaplib now requires three arguments where the test supplies two:
    #     elif command == 'STORE':
    #         message_set, op, flags = args
    #     ValueError: not enough values to unpack (expected 3, got 2)
    # The traceback bottoms out inside imaplib itself, not aioimaplib.
    #
    # SAFE TO SKIP because Home Assistant never travels that path: the Mail and
    # Packages integration uses aioimaplib's own async client (IMAP4_SSL), while
    # these two tests exercise the stdlib synchronous client against the test
    # server. 148 of 150 tests still run -- this is not doCheck = false.
    #
    # Scoped deliberately: "test_store" alone would already match both by substring,
    # and both names are listed so the intent is legible. Checked that no OTHER test
    # in the suite contains "store", so nothing else is silently deselected.
    #
    # test_imapserver_imaplib2.py::test_idle is excluded separately, and by exact node
    # id rather than by name, for two reasons. It is FLAKY, not broken: it passed on
    # the run before this override existed and failed with TimeoutError on the next,
    # with nothing changed but test selection -- an IDLE test racing a timeout on a
    # loaded aarch64 builder. And "test_idle" as a disabledTests substring would also
    # swallow test_idle_start__exits_queue_get_without_timeout_error and
    # test_idle_start__exits_queueget_with_keepalive_without_timeout_error, which are
    # aioimaplib's own ASYNC tests -- exactly the client path Home Assistant uses, and
    # the last thing that should be silently skipped. disabledTestPaths routes any
    # entry containing "::" to pytest --deselect=, so this removes that one test only.
    aioimaplib = hasPyPrev.aioimaplib.overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ [
        "test_store"
        "test_store_and_search_by_keyword"
      ];
      disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
        "tests/test_imapserver_imaplib2.py::test_idle"
      ];
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
    #
    # 9.0.1, not the 6.0.1 that stood here until 2026-08-10.
    # custom_components/hubspace 8.0.0 calls AferoAuth.for_login(), which does
    # not exist before 9.x, so on 6.0.1 the config flow raised AttributeError and
    # Home Assistant surfaced its generic "Unknown error occurred" the moment the
    # password was submitted. Nothing was wrong with the credentials -- the flow
    # never got as far as checking them.
    #
    # NOTE for anyone chasing this later: nixpkgs does NOT package aioafero at
    # all, in either channel. This derivation is its only source on the host, so
    # the pinned nixpkgs-unstable input is irrelevant here and must not be moved
    # on its account.
    aioafero = hasPy.buildPythonPackage rec {
      pname = "aioafero";
      version = "9.0.1";
      pyproject = true;
      src = prev.fetchPypi {
        inherit pname version;
        sha256 = "5493d3a6709a47e0c499df999b430a207e0bd606533fe6bd9e0b59d8ba12106d";
      };

      # 9.0.1 raises its floor to aiohttp>=3.14.3 while Home Assistant pins
      # aiohttp==3.14.1 EXACTLY (HA core's package_constraints.txt). With
      # pythonRuntimeDepsCheckHook active, a bare version bump fails the BUILD
      # ("aiohttp>=3.14.3 not satisfied by version 3.14.1") -- fail-closed, so a
      # mistake here cannot reach the running system.
      #
      # Lowering aioafero's floor rather than raising HA's aiohttp is deliberate:
      # upstream's changelog gives CVE hygiene, not an API change, as the reason
      # for the bump, and 3.14.2/3.14.3 are bugfix-only with no new public API.
      # Moving HA's aiohttp instead would diverge from a pin HA asserts exactly,
      # which is the one change in this area that could break HA itself.
      # Patching the metadata keeps the override visible in the diff rather than
      # hiding it behind dontCheckRuntimeDeps.
      #
      # REVISIT when HA's own aiohttp reaches 3.14.3: delete this postPatch.
      postPatch = ''
        substituteInPlace pyproject.toml \
          --replace-fail '"aiohttp>=3.14.3"' '"aiohttp>=3.14.1"'
      '';

      build-system = with hasPy; [ hatchling ];
      # Unchanged from 6.0.1 -- 9.0.1 introduces no new dependencies.
      dependencies = with hasPy; [
        aiohttp
        beautifulsoup4
        securelogging
      ];
      doCheck = false;
    };

    # pybose: Bose SoundTouch async client
    #
    # PACKAGE_VERSION is load-bearing. Upstream's setup.py reads the version from the
    # environment and falls back to a placeholder:
    #     version = os.getenv("PACKAGE_VERSION", "0.0.0")
    # Their release pipeline sets it; a plain sdist build does not, so the built
    # metadata says 0.0.0 while this derivation declares 2025.8.2. nixpkgs gained a
    # check comparing the two and fails the build on a mismatch:
    #     The 'pybose' derivation has version '2025.8.2' but .dist-info/METADATA
    #     specifies version '0.0.0'.
    # Setting the variable uses upstream's own mechanism, so the metadata comes out
    # correct at the source rather than being rewritten afterwards.
    #
    # NOT pyprojectVersionPatchHook, which is the obvious-looking fix and does not
    # work here: that hook edits pyproject.toml, and this sdist has none (setup.py
    # plus setup.cfg only). It fails with FileNotFoundError: 'pyproject.toml'.
    #
    # This is the failure that kept nixpkgs-unstable pinned at 241313f4 from
    # 2026-07-25 to 2026-09-08 -- the version check landed in the 2026-07-23 bump.
    pybose = hasPy.buildPythonPackage rec {
      pname = "pybose";
      version = "2025.8.2";
      pyproject = true;
      src = prev.fetchPypi {
        inherit pname version;
        sha256 = "47c2a4c96b9c8ca59d0f275e6feaef30bb641b4c11c97d65d8c5f036d558f28a";
      };
      env.PACKAGE_VERSION = version;
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
    # HA 2026.x uses unstable's opower — 0.18.6 as of 2026-07-27 (this note
    # originally said 0.18.0); the SMUD redirectUrl KeyError still exists
    # upstream, so we apply the same patch here.
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
  inherit (import ./dirscan.nix final prevWithHaskell) dirscan;

  # Sherlock — read-only database query tool for AI assistants
  inherit (import ./sherlock.nix final prev) sherlock-db;

  # org-jw — Org-mode data tools (semantic search via `org db search`)
  org-jw = inputs.org-jw.packages.${system}.default;

  # sacramento-cluster-ics — Google Sheet → RFC 5545 .ics files
  sac-cluster-ics = inputs.sacramento-cluster-ics.packages.${system}.default;

  # PostgreSQL extensions taken from the unstable pin but BUILT AGAINST
  # THE STABLE postgresql_17 that actually runs here.
  #
  # WHY THESE EXIST. Immich runs `ALTER EXTENSION ... UPDATE` on startup, so it
  # migrates its own catalog to the newest versions the running server offers. While
  # nixos-7bp had postgres on the unstable 17.11 build (2026-08-31 20:58 -> 2026-09-01
  # 20:46) it upgraded the immich database to vchord 1.1.1 and vector 0.8.6. Restoring
  # the stable binaries left the CATALOG ahead of the .so files, and immich refuses to
  # start:
  #     The database currently has VectorChord 1.1.1 activated, but the Postgres
  #     instance only has 0.5.3 available.
  # Postgres itself starts fine -- an extension only fails when something loads it --
  # which is why the restart looked clean and immich broke minutes later.
  #
  # That is the residue of the routing regression that could NOT be undone by fixing
  # the routing: swapping which binaries run is reversible, letting an application
  # migrate a database is not.
  #
  # WHY `.override { postgresql = ...; }` RATHER THAN THE WHOLE UNSTABLE PACKAGE.
  # Taking unstable's prebuilt extension would link it against unstable's 17.11. Same
  # PG major, so it would very likely load -- but "very likely" is not a property to
  # rely on for a photo library. Overriding rebuilds the newer sources against the
  # exact postgresql this host runs, so there is no ABI question left to be wrong about.
  #
  # THESE ARE NOT WIRED IN BY THE OVERLAY. postgresql.withPackages closes over the
  # package's own fixpoint, so replacing `postgresql_17.pkgs` here would not reach it.
  # pgvector_0_8_6 is installed cluster-wide by modules/services/databases.nix (it backs
  # more than Immich -- sherlock's entry_embeddings uses it too); vectorchord_1_1_1 is
  # added by modules/services/immich.nix. They must be supplied from exactly ONE place
  # each: services.postgresql.package.withPackages and services.postgresql.extensions
  # ACCUMULATE into one buildEnv, so listing a package in both yields
  # "two given paths contain a conflicting subpath" on lib/vector.so.
  #
  # RETIRE THESE when nixos-25.11 ships vchord >= 1.1.1 and pgvector >= 0.8.6, or when
  # the host moves to a nixpkgs that does. They are a catch-up shim, not a preference
  # for newer extensions.
  vectorchord_1_1_1 =
    inputs.nixpkgs-user.legacyPackages.${system}.postgresql_17.pkgs.vectorchord.override
      { postgresql = final.postgresql_17; };

  pgvector_0_8_6 = inputs.nixpkgs-user.legacyPackages.${system}.postgresql_17.pkgs.pgvector.override {
    postgresql = final.postgresql_17;
  };

  # Technitium DNS: stable is pinned at 14.0.0, four minor releases behind. Taken
  # from nixpkgs-user (15.4.0) rather than waiting for the stable channel.
  #
  # WHY THE PACKAGE ONLY, NOT THE MODULE. The stable and nixpkgs-user NixOS modules
  # were diffed before this change and their contract is identical: the same
  # `ExecStart = "${cfg.package}/bin/technitium-dns-server $STATE_DIRECTORY"`, the same
  # DynamicUser=true and StateDirectory=technitium-dns-server. Only the newer module
  # adds WorkingDirectory=%S/..., which modules/services/dns.nix already mkForce-nulls.
  # So swapping the package alone is sufficient and leaves the unit definition
  # entirely on the stable module this host has been running.
  #
  # .NET 10 IS BUNDLED, which is the one upgrade note that mattered. Technitium's 15.0
  # release notes say "you must install .NET 10 Runtime manually before upgrading" --
  # that applies to hand-installed servers. This derivation carries
  # dotnet-aspnetcore-runtime 10.0.11 as a dependency (verified, not assumed: the
  # package's `dotnet-runtime.version` evaluates to 10.0.11 against 9.0.17 on stable),
  # so there is no manual step and no runtime to drift out from under it.
  #
  # UPGRADE IS REVERSIBLE. Nothing in the 15.0-15.4 notes documents a one-way config
  # migration or declares downgrade to 14.x unsupported; upstream states existing
  # installations "work the same after the upgrade". Rollback is therefore an ordinary
  # generation switch. A verified-restorable filesystem backup was taken immediately
  # before the first deploy regardless.
  #
  # TWO BEHAVIOUR CHANGES TO KNOW ABOUT, neither breaking here: 15.3 drops the `Delete`
  # permission from the DNS Administrators group by default and reimplements the
  # built-in internal zones per RFC 6303/6761 (this host's reverse zones are
  # user-created, not built-in, and were confirmed intact after the switch); 15.2
  # renamed the Settings API field reverseProxyNetworkACL -> dnsReverseProxyNetworkACL,
  # which the dns-exporter does not read -- it calls api/user/checkForUpdate and the
  # dashboard stats endpoints.
  #
  # RETIRE THIS when nixos-25.11 ships technitium-dns-server >= 15.4.0.
  technitium-dns-server = inputs.nixpkgs-user.legacyPackages.${system}.technitium-dns-server;

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

  # The ai overlay leaves Linux llama-cpp unchanged. Apply only Vulcan's
  # Asahi backend choices here.
  llama-cpp = prev.llama-cpp.override {
    vulkanSupport = false;
    blasSupport = true;
  };

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

  # Immich comes from its OWN pinned input, not the shared nixpkgs-unstable one.
  #
  # It rode nixpkgs-unstable until 2026-09-08, when bumping that input to upgrade
  # Home Assistant would also have carried Immich 3.0.3 -> 3.1.0 as a side effect.
  # Immich migrates its extension catalog on startup and that migration does not
  # reverse when the package is rolled back, so it is the one package here that
  # must never move incidentally. flake.nix's nixpkgs-immich entry carries the full
  # rationale and the procedure for upgrading it deliberately.
  immich = inputs.nixpkgs-immich.legacyPackages.${system}.immich;

  # The CLI comes from the SAME pinned input as the server, deliberately.
  # Immich's CLI talks to the server's REST API and upstream expects the two to
  # be on the same release; taking it from nixpkgs (2.7.5) or nixpkgs-user
  # (3.1.0) would pair a mismatched client with the pinned 3.0.3 server, and the
  # pin exists precisely so this pairing cannot drift silently. Sourcing both
  # from one input means a deliberate immich bump moves the CLI with it and
  # nothing else can.
  immich-cli = inputs.nixpkgs-immich.legacyPackages.${system}.immich-cli;

  # Home Assistant - Update to latest from nixpkgs-unstable (2026.7.2 as of
  # 2026-07-27; this note originally anchored on 2026.4.1+)
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
  # cozempic: Context cleaning for Claude Code
  inherit (import ./30-cozempic.nix final prev) cozempic;

  # agent-deck (tmux TUI for AI coding agents) is now provided by nix-config's
  # portable AI overlay, applied ahead of this overlay in flake.nix. The former
  # local mirror (an ai-nix-pin workaround) was dropped when ai-nix was folded
  # into nix-config.

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
  # for the full design. The systemd unit has since landed in
  # modules/services/hermes-mcp.nix (enabled at hosts/vulcan/default.nix:205).
  hermes-mcp = final.callPackage ../pkgs/hermes-mcp { };

  # Node-RED — bump to upstream maintenance release 4.1.10.
  # See overlays/node-red.nix for the rationale and bump instructions.
  inherit (import ./node-red.nix final prev) node-red;
}
