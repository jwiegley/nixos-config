{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Script to remove Nix-managed integrations from HACS installed tracking.
  # HACS cannot update Nix store symlinks: shutil.rmtree fails on symlinks in
  # Python 3.12+ and Nix store files are read-only (causing backup failures).
  # Both entries in NIX_MANAGED below stay Nix-managed: opnsense because upstream
  # lacks the Python 3.13 syntax fixes, poolmath because of poolmath-fixes.patch.
  hacsUntrackNixManaged = pkgs.writeText "hacs-untrack-nix-managed.py" ''
    import json
    NIX_MANAGED = {"travisghansen/hass-opnsense", "rsnodgrass/hass-poolmath"}
    fpath = "/var/lib/hass/.storage/hacs.repositories"
    try:
        with open(fpath) as f:
            data = json.load(f)
        repos = data.get("data", {})
        changed = False
        for repo in repos.values():
            if isinstance(repo, dict) and repo.get("full_name", "") in NIX_MANAGED:
                if repo.get("installed", False):
                    repo["installed"] = False
                    repo["version_installed"] = None
                    changed = True
        if changed:
            with open(fpath, "w") as f:
                json.dump(data, f, indent=4)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
  '';

  # Custom Home Assistant component: Multiscrape
  # Advanced web scraping for Home Assistant with multiple sensors per page
  # GitHub: https://github.com/danieldotnl/ha-multiscrape
  multiscrape = pkgs.buildHomeAssistantComponent rec {
    owner = "danieldotnl";
    domain = "multiscrape";
    version = "8.0.5";

    src = pkgs.fetchFromGitHub {
      owner = "danieldotnl";
      repo = "ha-multiscrape";
      rev = "v${version}";
      hash = "sha256-J0LeQq31zQsBnVl6X2WJTJXK6D+k9kzFgwmbCH/VTiU=";
    };

    dependencies = with pkgs.home-assistant.python.pkgs; [
      lxml
      beautifulsoup4
    ];

    meta = with pkgs.lib; {
      description = "Home Assistant custom component for scraping multiple values from a single HTTP request";
      homepage = "https://github.com/danieldotnl/ha-multiscrape";
      license = licenses.mit;
    };
  };

  # Custom Home Assistant component: Chime TTS
  # Play chime sounds before TTS announcements
  # GitHub: https://github.com/nimroddolev/chime_tts
  chime-tts = pkgs.buildHomeAssistantComponent rec {
    owner = "nimroddolev";
    domain = "chime_tts";
    version = "1.2.2";

    src = pkgs.fetchFromGitHub {
      owner = "nimroddolev";
      repo = "chime_tts";
      rev = "v${version}";
      hash = "sha256-PoAblubm3TPZ9LAYmkEEEcuND6VWnGyx2T6btgDMsDQ=";
    };

    dependencies = with pkgs.home-assistant.python.pkgs; [
      pydub
      aiofiles
    ];

    meta = with pkgs.lib; {
      description = "Home Assistant custom component for playing chime sounds before TTS announcements";
      homepage = "https://github.com/nimroddolev/chime_tts";
      license = licenses.mit;
    };
  };

  # Custom Home Assistant component: OPNsense
  # OPNsense firewall integration (HACS: travisghansen/hass-opnsense)
  # Note: v0.6.5 still has Python 2-style "except A, B:" clauses (invalid in Python 3.13);
  # all are fixed via postPatch until corrected upstream.
  hass-opnsense =
    let
      # Script to fix Python 2-style "except A, B:" -> "except (A, B):" across all files
      fixExceptSyntax = pkgs.writeText "fix-py2-except.py" ''
        import re, os

        pattern = re.compile(
            r"^(\s*)except ([A-Za-z][A-Za-z0-9_.]*(?:\s*,\s*[A-Za-z][A-Za-z0-9_.]*)+)\s*:",
            re.MULTILINE
        )

        for root, dirs, files in os.walk("custom_components/opnsense"):
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
    in
    pkgs.buildHomeAssistantComponent rec {
      owner = "travisghansen";
      domain = "opnsense";
      version = "0.6.5";

      src = pkgs.fetchFromGitHub {
        owner = "travisghansen";
        repo = "hass-opnsense";
        rev = "v${version}";
        hash = "sha256-OUFlROm1SC1Dy5aBzSG9RpQhRYeiWNKELTXG6UQHJFM=";
      };

      postPatch = ''
        python3 ${fixExceptSyntax}
      '';

      dependencies = [ pkgs.home-assistant.python.pkgs.aiopnsense ];

      meta = with pkgs.lib; {
        description = "Home Assistant custom integration for OPNsense firewall";
        homepage = "https://github.com/travisghansen/hass-opnsense";
        license = licenses.mit;
      };
    };

  # Custom Home Assistant component: Presence Simulation
  # Simulate presence by replaying historical entity states
  # GitHub: https://github.com/slashback100/presence_simulation
  presence-simulation = pkgs.buildHomeAssistantComponent rec {
    owner = "slashback100";
    domain = "presence_simulation";
    version = "5.0";

    src = pkgs.fetchFromGitHub {
      owner = "slashback100";
      repo = "presence_simulation";
      rev = "v${version}";
      hash = "sha256-47O6qzTiWnfjin0kQ14UZwMLB/XEi8bBf3MjsABnpwQ=";
    };

    # No additional Python dependencies required (uses core HA integrations)
    dependencies = [ ];

    meta = with pkgs.lib; {
      description = "Home Assistant custom component for simulating presence when away";
      homepage = "https://github.com/slashback100/presence_simulation";
      license = licenses.asl20;
    };
  };

  # Custom Home Assistant component: Pool Math (Trouble Free Pool)
  # GitHub: https://github.com/rsnodgrass/hass-poolmath
  # Pinned to v2.2.0 (latest release) + poolmath-fixes.patch, which carries two
  # fixes not yet in any upstream release (see the patch for full context):
  #   1. config_flow.py: v2.2.0 calls async_show_form(data_description=...), which
  #      is not a valid kwarg (data_description is a strings.json key), so the config
  #      flow 500s. Upstream master switched to description_placeholders=; backported.
  #   2. sensor.py: add async_added_to_hass so each entity seeds its value from the
  #      already-fetched coordinator data on add, instead of reading 'unknown' for one
  #      update_interval (~8 min) after every (re)start.
  poolmath = pkgs.buildHomeAssistantComponent rec {
    owner = "rsnodgrass";
    domain = "poolmath";
    version = "2.2.0";

    src = pkgs.fetchFromGitHub {
      owner = "rsnodgrass";
      repo = "hass-poolmath";
      rev = "v${version}";
      hash = "sha256-dFSCoubrvj0X9d6IH+7RSY06Xt7sXNRU/wPiXRbFR18=";
    };

    patches = [ ./poolmath-fixes.patch ];

    # Manifest requires only aiohttp>=3.10.0, which HA core already provides.
    dependencies = [ pkgs.home-assistant.python.pkgs.aiohttp ];

    meta = with pkgs.lib; {
      description = "Home Assistant custom integration for Pool Math (Trouble Free Pool)";
      homepage = "https://github.com/rsnodgrass/hass-poolmath";
      license = licenses.mit;
    };
  };
in

{
  # SOPS secrets for Yale/August account credentials
  sops.secrets."home-assistant/yale-username" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/yale-password" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/opnsense-url" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/opnsense-api-key" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/opnsense-api-secret" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # LG ThinQ Personal Access Token (PAT)
  sops.secrets."home-assistant/lg-thinq-token" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # Google Assistant SDK credentials
  sops.secrets."home-assistant/google-assistant-client-id" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/google-assistant-client-secret" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # PostgreSQL password for Home Assistant recorder
  sops.secrets."home-assistant/postgres-password" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
  };

  # OpenUV API key for /forecast REST sensor (separate from the openuv
  # integration's UI-stored copy; HA's YAML rest: sensor cannot read
  # integration config_entries, so we duplicate-store the key here).
  sops.secrets."home-assistant/openuv-api-key" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # Avahi service for mDNS/Bonjour discovery (required for HomeKit and Matter)
  services.avahi = {
    enable = true;
    nssmdns4 = true; # Enable NSS mDNS support for hostname resolution

    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # PostgreSQL database for Home Assistant recorder
  services.postgresql = {
    ensureDatabases = [ "hass" ];
    ensureUsers = [
      {
        name = "hass";
        ensureDBOwnership = true;
      }
    ];

    # Performance tuning for Home Assistant workload
    settings = {
      # Memory settings moved to databases.nix for consolidation
      maintenance_work_mem = "1GB"; # For VACUUM, CREATE INDEX on large vector tables

      # WAL (Write-Ahead Logging) settings for better write performance
      wal_buffers = "8MB";
      max_wal_size = "1GB";
      min_wal_size = "80MB";

      # Checkpointing for write-heavy time-series workload
      checkpoint_completion_target = "0.9"; # Spread out checkpoint I/O

      # Autovacuum tuning for high-frequency inserts/deletes
      autovacuum = "on";
      autovacuum_max_workers = "2"; # Keep background maintenance active
      autovacuum_naptime = "30s"; # Check for vacuum needs more frequently
      autovacuum_vacuum_scale_factor = "0.05"; # Vacuum earlier (5% vs 20% default)
      autovacuum_analyze_scale_factor = "0.025"; # Analyze earlier for better plans

      # Planner cost constants - favor index scans for time-series queries
      random_page_cost = "1.1"; # Lower for SSD storage
      effective_io_concurrency = "200"; # Higher for SSD

      # Statistics for better query planning
      default_statistics_target = "100"; # Better stats for time-series columns
    };
  };

  # Set PostgreSQL password for hass user from SOPS secret
  systemd.services.postgresql-hass-password = {
    description = "Set PostgreSQL password for Home Assistant user";
    after = [
      "postgresql.service"
      "sops-install-secrets.service"
    ];
    requires = [
      "postgresql.service"
      "sops-install-secrets.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      # Read password (file is owned by hass, so we need to use runuser)
      PASSWORD=$(${pkgs.util-linux}/bin/runuser -u hass -- cat ${
        config.sops.secrets."home-assistant/postgres-password".path
      })
      ${config.services.postgresql.package}/bin/psql -c "ALTER USER hass WITH PASSWORD '$PASSWORD';"
    '';
  };

  # Home Assistant service
  services.home-assistant = {
    enable = true;

    # Custom components: those from pkgs.home-assistant-custom-components (nixpkgs
    # plus overlays/default.nix) and the derivations defined in the let block above
    customComponents = with pkgs.home-assistant-custom-components; [
      # HACS with manifest check disabled
      # Fix for manifestCheckPhase error on aarch64 (Asahi)
      # Issue: frontend manifest.json files are incorrectly validated as HA component manifests
      (hacs.overrideAttrs (oldAttrs: {
        doInstallCheck = false;
      }))
      intellicenter # Pentair IntelliCenter integration
      spook # Spook - powerful toolbox for Home Assistant (services, templates, repairs)
      waste_collection_schedule # Garbage/recycling collection schedule tracking

      # Custom-packaged integrations (not in nixpkgs)
      multiscrape # Advanced web scraping with multiple sensors per page
      chime-tts # Play chime sounds before TTS announcements
      presence-simulation # Simulate presence by replaying historical entity states
      hass-opnsense # OPNsense firewall integration v0.6.5 (with Python 3.13 syntax fix)
      poolmath # Pool Math (Trouble Free Pool) v2.2.0 + poolmath-fixes.patch (config-flow + initial-state seed)
    ];

    # Extra Python packages needed by the integrations below
    # (psycopg2 is what lets the recorder use PostgreSQL)
    extraPackages = ps: [
      ps.psycopg2 # PostgreSQL adapter
      ps.grpcio # Required for Google Nest integration
      ps.aiogithubapi # Required for HACS
      ps.aiohomekit # Required for HomeKit Controller integration
      ps.python-otbr-api # Required for HomeKit Controller Thread support
      ps.python-miio # Required for Dreame Vacuum integration
      ps.pybase64 # Required for Dreame Vacuum integration
      ps.paho-mqtt # Required for Dreame Vacuum integration
      ps.aiomqtt # Required for Traeger WiFIRE integration
      ps.mini_racer # Required for Dreame Vacuum integration (V8 JavaScript engine)
      ps.aiofiles # Required for Hubspace integration
      ps.packaging # Required for Hubspace integration
      ps.aioafero # Custom package for Hubspace integration
      ps.pychromecast # Required for Bose integration
      ps.pybose # Custom package for Bose integration
      ps.pyicloud # Required for Apple iCloud integration
      ps.pyatv # Required for Apple TV integration
      ps.webcolors # Required for Local LLMs (llama_conversation) custom component
      ps.langfuse # Required for custom_conversation custom component (Langfuse tracing)
      ps.litellm # Required for custom_conversation custom component (multi-provider LLM client)
      ps.openai # Required for custom_conversation custom component (OpenAI-compatible API)
      ps.wakeonlan # Required for Wake on LAN integration
      ps.pywaze # Required for Waze Travel Time integration
      ps.pydub # Required for Chime TTS audio processing
      ps.pykumo # Required for Kumo Cloud integration (Mitsubishi mini-splits)
      ps.aiopnsense # Required for OPNsense integration
      ps.aionut # Required for Network UPS Tools (NUT) integration
      ps."homekit-audio-proxy" # Required for HomeKit Bridge (missing from nixpkgs)
      ps.awsiotpythonsdk # Required for Navien NaviLink Water Heater integration
      ps.pyalarmdotcomajax # Required for Alarm.com / ADT Control custom integration
      ps.vtherm_api # Required for Versatile Thermostat custom component (>=0.3.0)
      # Mail and Packages (HACS: moralmunky/Home-Assistant-Mail-And-Packages).
      # HACS installs it as a plain directory, so its manifest requirements are
      # never pip-installed under --skip-pip; declare the two not already in the
      # closure here (Pillow ships with HA core; beautifulsoup4 comes via the
      # multiscrape component). Without these the config flow import fails with
      # "No module named 'aioimaplib'" -> UI "Invalid handler specified".
      ps.aioimaplib # Required for Mail and Packages — async IMAP client
      ps.dateparser # Required for Mail and Packages — email date parsing
    ];

    # Components that don't require YAML configuration
    extraComponents = [
      # Core integrations
      "analytics"
      "default_config"
      "met"
      "mqtt" # MQTT client for HASS.Agent and other IoT devices
      "sql" # SQL sensor platform — water-attribution fixture totals from flume-data DB

      # Calendar and scheduling
      "google" # Google Calendar integration (requires gcal_sync)
      "workday" # Binary sensor for workday/holiday detection

      # Yale/August lock integration. Upstream redirected yale_home -> yale in
      # 2024-08 and later dropped the yale_home alias entirely; this config
      # caught up at the HA 2026.4.1 upgrade.
      "yale"
      "august"

      # Useful utilities
      "google_translate"
      "google_assistant_sdk" # Google Assistant SDK for voice control and automation
      "radio_browser"
      "shopping_list"

      # Network discovery
      "dhcp"
      "ssdp"
      "zeroconf"
      "upnp"

      # Performance
      "isal" # Fast compression for websockets

      # Mobile app support
      "mobile_app"

      # Automation and scripting
      "automation"
      "script"
      "scene"

      # Wake on LAN
      "wake_on_lan"

      # Network devices
      "asuswrt" # ASUS WiFi routers
      "tplink" # TP-Link Smart Home (Kasa/Tapo devices)
      # OPNsense firewall - use the Nix-managed hass-opnsense custom component instead
      # Built-in integration has JSON parsing issues with newer OPNsense versions

      # Lighting
      "wiz" # WiZ WiFi smart bulbs (Signify/Philips) — local push, requires pywizlight

      # Energy & Solar
      "enphase_envoy" # Enphase Solar Inverter
      "tesla_wall_connector" # Tesla Wall Connector

      # UPS / Power backup
      "nut" # Network UPS Tools — APC BR1000MS via local upsd on 127.0.0.1:3493

      # Water monitoring
      "flume" # Flume water meter

      # Climate control
      "nest" # Google Nest thermostats

      # Security & Access
      "ring" # Ring doorbell and chimes

      # Pool & Spa
      "screenlogic" # Pentair IntelliCenter & IntelliFlo

      # Appliances
      "miele" # Miele dishwasher
      "lg_thinq" # LG ThinQ smart appliances

      # Casting & Display
      "cast" # Google Home Hub / Cast devices
      "vlc_telnet" # VLC media player via telnet (for desktop TTS)

      # Health & Fitness
      "withings" # Withings digital scale and health devices

      # Vehicles
      "bmw_connected_drive" # BMW ConnectedDrive vehicle integration

      # Smart TVs
      "webostv" # LG webOS Smart TV

      # HomeKit Bridge
      "homekit" # Expose Home Assistant entities to Apple HomeKit/Siri
      "infrared" # Infrared remote control support (provides infrared_protocols)

      # Utility Data
      "opower" # Energy usage from utility companies (SMUD)

      # Financial
      "simplefin" # SimpleFIN bank/financial account balances (requires simplefin4py; --skip-pip needs it listed here)

      # Weather
      "accuweather" # AccuWeather weather forecasts
      "nws" # National Weather Service (NOAA) weather forecasts
      "openuv" # OpenUV API for UV index data (requires pyopenuv)

      # Metrics export
      "influxdb" # InfluxDB integration for pushing metrics to VictoriaMetrics

      # AI / MCP
      "mcp_server" # Model Context Protocol Server (exposes HA to AI assistants like Claude)

      # Matter
      "matter" # Matter/CHIP SDK device integration (via python-matter-server)

      # Voice Assistant pipeline (Wyoming protocol bridges STT/TTS/wakeword)
      "wyoming" # Wyoming protocol client (talks to wyoming-openai on :10300)
      "assist_pipeline" # Voice pipeline orchestration
      "stt" # Speech-to-text platform
      "tts" # Text-to-speech platform
    ];

    # Home Assistant configuration (YAML format)
    config = {
      # Default configuration enables several integrations
      default_config = { };

      # Basic settings
      homeassistant = {
        name = "Vulcan Home";
        latitude = "!secret latitude";
        longitude = "!secret longitude";
        elevation = "!secret elevation";
        unit_system = "us_customary";
        time_zone = "America/Los_Angeles";
        currency = "USD";
        country = "US";

        # Internal/external URLs for reverse proxy
        internal_url = "https://hass.vulcan.lan";
        external_url = "https://hass.vulcan.lan";

        # Authentication providers: username/password only. (Trust for the nginx
        # reverse proxy is configured under http: below, not here.)
        auth_providers = [
          {
            type = "homeassistant";
          }
        ];

        # Enable packages for modular configuration
        # Allows loading additional config from /var/lib/hass/packages/*.yaml
        packages = "!include_dir_named packages";
      };

      # OpenUV daily forecast — one /forecast pull per day at 05:00 (driven by the
      # HA automation openuv_forecast_refresh, created per Task 4 of
      # docs/superpowers/plans/2026-05-12-openuv-pool-time.md). Exposes the hourly
      # UV array as sensor.openuv_forecast.attributes.result for Node-RED consumption.
      rest = [
        {
          scan_interval = 86400;
          resource = "https://api.openuv.io/api/v1/forecast";
          params = {
            lat = "!secret latitude";
            lng = "!secret longitude";
          };
          headers = {
            "x-access-token" = "!secret openuv_api_key";
          };
          sensor = [
            {
              name = "OpenUV Forecast";
              unique_id = "openuv_forecast";
              value_template = "{{ value_json.result | map(attribute='uv') | max | round(1) }}";
              json_attributes = [ "result" ];
            }
          ];
        }
      ];

      # HTTP configuration for reverse proxy
      http = {
        # Use X-Forwarded-For headers from nginx
        use_x_forwarded_for = true;
        trusted_proxies = [
          "127.0.0.1"
          "::1"
          "192.168.1.2" # vulcan's Ethernet IP
          "192.168.3.16" # vulcan's WiFi IP
        ];

        # Bind to loopback (nginx proxy) and OpenClaw VM bridge
        server_host = [
          "127.0.0.1"
          "10.99.0.1" # OpenClaw microVM bridge gateway
        ];
        server_port = 8123;
      };

      # Recorder - using PostgreSQL for better performance and memory efficiency
      recorder = {
        # Don't specify db_url here - the service's preStart injects it into
        # /var/lib/hass/configuration.yaml (see the awk block further below)
        # This allows us to inject the SOPS-managed password securely

        auto_purge = true;
        purge_keep_days = 30;
        commit_interval = 5; # Increased from 1 to improve performance

        # Database optimization
        auto_repack = true; # Automatically repack database to reclaim space and improve performance

        # Exclude noisy sensors to reduce database size and memory usage
        exclude = {
          domains = [
            "updater" # Don't record update checks
            "button" # One-time actions, no history value
            "event" # Temporary events, no history value
            "update" # Update availability rarely changes
          ];

          # Explicit entity exclusions for high-frequency entities
          # These are entities that update very frequently and don't need history
          entities = [
            # iCloud3 high-frequency diagnostic sensors
            "sensor.john_iphone_info"
            "sensor.john_iphone_next_update"
            "sensor.john_iphone_last_update"
            "sensor.nasim_iphone_info"
            "sensor.nasim_iphone_next_update"
            "sensor.nasim_iphone_last_update"

            # Mac Studio sensors
            "sensor.johns_mac_studio_frontmost_app"
            "sensor.clio_2_frontmost_app"

            # Smart plug voltage sensors (keep power/current)
            "sensor.smart_plug_tv_voltage"

            # ASUS router device trackers (keep OPNsense trackers for person detection)
            "device_tracker.asus_john_iphone"
            "device_tracker.asus_nasim_iphone"
          ];

          entity_globs = [
            "sensor.weather_*"

            # Enphase: Exclude individual inverter/panel sensors (keep aggregate sensors)
            "sensor.inverter_*"
            "sensor.envoy_*_micro*" # Additional Enphase microinverter sensors

            # Dreame Vacuum: Exclude per-room cleaning configuration entities
            "select.*_room_*"
            "sensor.*_room_*"
            "switch.*_room_*"

            # Dreame Vacuum: Exclude cameras, maps, and non-essential sensors (battery optimization)
            "camera.*dreame*" # All map cameras
            "sensor.*dreame*map*" # Map-related sensors
            "sensor.*dreame*_info" # Diagnostic info sensors
            "sensor.*dreame*_last_clean*" # Cleaning history timestamps
            "sensor.*dreame*_total_clean*" # Cumulative statistics
            "sensor.*dreame*_cleaning_time*" # Time statistics
            "sensor.*dreame*_cleaning_area*" # Area statistics
            "sensor.*dreame*_main_brush*" # Consumable sensors (if not needed)
            "sensor.*dreame*_side_brush*" # Consumable sensors (if not needed)
            "sensor.*dreame*_filter*" # Consumable sensors (if not needed)
            "sensor.*dreame*_sensor_dirty*" # Consumable sensors (if not needed)
            "sensor.*dreame*_mop*" # Mop-related sensors (if not needed)
            "binary_sensor.*dreame*_mop*" # Mop-related binary sensors

            # iCloud3: Exclude high-frequency diagnostic/status sensors
            "sensor.icloud3_event_log"
            "sensor.*_info" # Device info updates constantly
            "sensor.*_next_update" # Next update time changes constantly
            "sensor.*_last_update" # Last update time changes constantly
            "sensor.*_last_located" # Last location time changes constantly

            # Device trackers: Exclude most network devices (keep person trackers only)
            "device_tracker.*_last_update_trigger"
            "device_tracker.enphase_*" # Solar inverter network presence
            "device_tracker.dreame_*" # Vacuum network presence
            "device_tracker.espressif_*" # Generic ESP devices
            "device_tracker.98_03_8e_*" # MAC address trackers (network devices)

            # Smart plugs: Exclude high-frequency voltage sensors (keep power/current)
            "sensor.*_voltage" # Voltage rarely changes, updates constantly

            # OPNsense router: Exclude high-frequency monitoring sensors
            "sensor.router_cpu_*" # CPU usage updates every few seconds
            "sensor.router_temp_*" # Temperature sensors update constantly
            "sensor.router_system_load_*" # System load updates constantly

            # Mac Studio: Exclude constantly changing app/storage sensors
            "sensor.*_frontmost_app" # Active app changes constantly
            "sensor.*_storage" # Storage updates frequently

            # Battery sensors: Already tracked, but exclude some verbose ones
            "sensor.*_battery_temperature"

            # Network: Exclude high-frequency bandwidth sensors
            "sensor.*_throughput*"
            "sensor.*_bandwidth*"
          ];

          # Exclude internal Home Assistant events that bloat the database
          event_types = [
            "service_registered" # Internal service registration
            "component_loaded" # Internal component loading
            "entity_registry_updated" # UI entity registry changes
            "panels_updated" # UI panel updates
            "device_registry_updated" # Device registry changes (rarely useful)
          ];
        };
      };

      # History - inherits entity filter from recorder automatically
      # The deprecated include/exclude/use_include_order options have been removed
      # History now uses recorder's exclusions, so no separate filtering is needed
      history = { };

      # Logger - reduce logging verbosity to minimize I/O and memory overhead
      logger = {
        default = "warning"; # Changed from "info" to reduce log volume
        logs = {
          # Keep core at warning level for important messages only
          "homeassistant.core" = "warning";

          # Suppress noisy integrations (keep at error level)
          "homeassistant.components.recorder" = "error"; # Recorder internal operations
          "homeassistant.components.websocket_api" = "error"; # WebSocket chatter
          "homeassistant.components.http" = "error"; # HTTP request logging

          # Keep important components at warning level for troubleshooting
          "homeassistant.components.automation" = "warning";
          "homeassistant.components.script" = "warning";

          # Suppress integration-specific errors (Phase 4 optimization)
          "homeassistant.components.miele" = "error"; # Miele ValueError with unavailable states

          # TP-Link Kasa smart plug timeout errors (192.168.3.25, 192.168.3.177)
          # Devices intermittently timeout - suppress to critical to reduce log noise
          "kasa.smart.smartdevice" = "critical";
          "kasa" = "error"; # Other Kasa module errors

          # Ring doorbell subscription warnings (~15/hour without subscription)
          "ring_doorbell.doorbot" = "error"; # Subscription warning spam
          "pubnub" = "error"; # Ring doorbell PubNub connector errors

          # Template warnings for weather forecasts
          # NWS doesn't provide detailed_description field
          "homeassistant.helpers.template" = "error";
        };
      };

      # OPNsense firewall integration
      # The built-in integration has issues with newer OPNsense versions (25.7+)
      # Using the custom component "travisghansen/hass-opnsense" managed via Nix (see customComponents above)
      # Configure via UI: Settings > Devices & Services > Add Integration > OPNsense

      # Enable automation UI
      automation = "!include automations.yaml";

      # Enable scene UI
      scene = "!include scenes.yaml";

      # Enable script UI
      script = "!include scripts.yaml";

      # Live-tunable calibration parameters for the temperature-compensated
      # pool salt virtual sensor (sensor.pool_salt_temp_compensated). Exposed
      # as input_number helpers so calibrating against titration needs no
      # rebuild — adjust them from the UI:
      #   alpha  = conductivity temperature coefficient (~0.02 /°C for NaCl);
      #            fit it from a warm-vs-cold reading of the same water.
      #   scale  = slope m of the two-point linear fit to titration.
      #   offset = intercept b (ppm) of the two-point linear fit to titration.
      input_number = {
        pool_salt_alpha = {
          name = "Pool Salt Temp Coefficient";
          min = 0;
          max = 0.05;
          step = 0.001;
          initial = 0.02;
          mode = "box";
          icon = "mdi:thermometer-lines";
        };
        pool_salt_scale = {
          name = "Pool Salt Calibration Scale";
          min = 0.5;
          max = 2.0;
          step = 0.01;
          initial = 1.35; # single-point cal 2026-05-29: titration 4800 / compensated-25°C 3558 (α=0.02). Corrects prior 1.25 (that was wrongly computed vs RAW 3800, not the compensated value).
          mode = "box";
          icon = "mdi:multiplication";
        };
        pool_salt_offset = {
          name = "Pool Salt Calibration Offset";
          min = -1000;
          max = 1000;
          step = 10;
          initial = 0;
          unit_of_measurement = "ppm";
          mode = "box";
          icon = "mdi:plus-minus-variant";
        };
      };

      # Template sensors for presence detection
      # These combine person entity states to determine if anyone is home
      template = [
        {
          binary_sensor = [
            {
              name = "Anyone Home";
              unique_id = "anyone_home";
              state = "{{ is_state('person.john_wiegley', 'home') or is_state('person.nasim_wiegley', 'home') }}";
              device_class = "occupancy";
              icon = "mdi:home-account";
            }
            {
              name = "Everyone Away";
              unique_id = "everyone_away";
              state = "{{ is_state('person.john_wiegley', 'not_home') and is_state('person.nasim_wiegley', 'not_home') }}";
              device_class = "occupancy";
              icon = "mdi:home-off";
            }
            {
              name = "John Home";
              unique_id = "john_home";
              state = "{{ is_state('person.john_wiegley', 'home') }}";
              device_class = "occupancy";
              icon = "mdi:account";
            }
            {
              name = "Nasim Home";
              unique_id = "nasim_home";
              state = "{{ is_state('person.nasim_wiegley', 'home') }}";
              device_class = "occupancy";
              icon = "mdi:account";
            }
            {
              name = "John Home Composite";
              unique_id = "john_home_composite";
              state = "{{ is_state('device_tracker.opnsense_john_iphone', 'home') or is_state('device_tracker.asus_john_iphone', 'home') }}";
              device_class = "occupancy";
              icon = "mdi:account-network";
              attributes = {
                sources = "device_tracker.router_john_iphone, device_tracker.asus_john_iphone";
                opnsense_state = "{{ states('device_tracker.opnsense_john_iphone') }}";
                asus_state = "{{ states('device_tracker.asus_john_iphone') }}";
              };
            }
            {
              name = "Nasim Home Composite";
              unique_id = "nasim_home_composite";
              state = "{{ is_state('device_tracker.opnsense_nasim_iphone', 'home') or is_state('device_tracker.asus_nasim_iphone', 'home') }}";
              device_class = "occupancy";
              icon = "mdi:account-network";
              attributes = {
                sources = "device_tracker.opnsense_nasim_iphone, device_tracker.asus_nasim_iphone";
                opnsense_state = "{{ states('device_tracker.opnsense_nasim_iphone') }}";
                asus_state = "{{ states('device_tracker.asus_nasim_iphone') }}";
              };
            }
            {
              name = "Office Vacant and Closed";
              unique_id = "office_vacant_and_closed";
              state = "{{ is_state('binary_sensor.office_presence_sensor_fp300_occupancy', 'off') and is_state('binary_sensor.office_door_sensor_p2_office_door', 'off') }}";
              icon = "mdi:door-closed-lock";
            }
            {
              # Debounced office occupancy for the Upstairs VTherm presence feature.
              # The FP300 mmWave is twitchy (sensitivity "high", 20s hold) and John
              # steps out often, so the raw sensor flaps the thermostat between
              # comfort and away. Stay "present" until the FP300 reports a genuine
              # 'off' for a continuous 15 min; 'unavailable'/'unknown' (the device's
              # frequent connectivity dropouts) count as present so they never force
              # an away setback. Point the VTherm presence sensor at this entity.
              name = "Office Occupied Debounced";
              unique_id = "office_occupied_debounced_15m";
              device_class = "occupancy";
              state = "{{ not is_state('binary_sensor.office_presence_sensor_fp300_occupancy', 'off') }}";
              delay_off = "00:15:00";
            }
          ];
        }
        {
          # Temperature-compensated, titration-calibrated pool salt reading.
          # The IntelliChlor cell reports a conductivity-derived salt ppm that
          # drifts with water temperature (warm reads high, cold reads low).
          # Stage 1 normalizes the raw reading to a 25 °C reference using the
          # standard EC compensation EC25 = EC_T / (1 + alpha*(T-25)); stage 2
          # applies a linear fit (scale m, offset b) to match silver-nitrate
          # titration. With no water replacement the output should hold steady.
          # alpha/m/b come from the input_number helpers above (UI-tunable).
          sensor = [
            {
              name = "Pool Salt (Temp-Compensated)";
              unique_id = "pool_salt_temp_compensated";
              unit_of_measurement = "ppm";
              state_class = "measurement";
              icon = "mdi:shaker-outline";
              availability = "{{ has_value('sensor.intellichlor_1_salt') and has_value('sensor.pool_last_temp') }}";
              state = ''
                {%- set raw = states('sensor.intellichlor_1_salt') | float(0) -%}
                {%- set t = states('sensor.pool_last_temp') | float(77) -%}
                {%- set unit = state_attr('sensor.pool_last_temp', 'unit_of_measurement') -%}
                {%- set tc = t if unit == '°C' else (t - 32) * 5 / 9 -%}
                {%- set alpha = states('input_number.pool_salt_alpha') | float(0.02) -%}
                {%- set m = states('input_number.pool_salt_scale') | float(1.0) -%}
                {%- set b = states('input_number.pool_salt_offset') | float(0.0) -%}
                {%- set comp = raw / (1 + alpha * (tc - 25)) -%}
                {{- ((m * comp) + b) | round(0) | int -}}
              '';
              attributes = {
                raw_salt = "{{ states('sensor.intellichlor_1_salt') }}";
                water_temp = "{{ states('sensor.pool_last_temp') }}";
                compensated_25c = ''
                  {%- set raw = states('sensor.intellichlor_1_salt') | float(0) -%}
                  {%- set t = states('sensor.pool_last_temp') | float(77) -%}
                  {%- set unit = state_attr('sensor.pool_last_temp', 'unit_of_measurement') -%}
                  {%- set tc = t if unit == '°C' else (t - 32) * 5 / 9 -%}
                  {%- set alpha = states('input_number.pool_salt_alpha') | float(0.02) -%}
                  {{- (raw / (1 + alpha * (tc - 25))) | round(0) | int -}}
                '';
              };
            }
          ];
        }
      ];

      # InfluxDB integration for pushing metrics to VictoriaMetrics
      # VictoriaMetrics accepts InfluxDB line protocol via /write endpoint
      # Connection/auth keys (host, port, database) are managed via UI after
      # HA 2026.4+ deprecation of YAML connection config (removed in 2026.9.0)
      influxdb = {
        # Pushed on every state change (HA batches writes, ~1s window as of
        # 2026.7.2); the influxdb integration has no fixed push interval to tune
        max_retries = 3;
        default_measurement = "state";

        # Include domains - aligned with previous Prometheus exporter filter
        include = {
          domains = [
            "sensor"
            "climate"
            "binary_sensor"
            "lock"
            "switch"
            "light"
            "cover"
            "fan"
            "person"
            "device_tracker"
            "media_player" # Bose speaker, LG webOS TV, etc.
            "vacuum" # Dreame robot vacuum
            "camera" # Ring doorbell cameras
            "update" # Integration and device updates
            "button" # Device buttons
          ];
        };

        # Exclude noisy entities - aligned with previous Prometheus exporter filter
        exclude = {
          entity_globs = [
            "sensor.weather_*"
            # Dreame Vacuum: Exclude per-room cleaning configuration entities
            "select.*_room_*"
            "sensor.*_room_*"
            "switch.*_room_*"
          ];
        };
      };

      # HomeKit Bridge integration
      # Exposes Home Assistant entities to Apple HomeKit for Siri control
      homekit = {
        # Name shown in Apple Home app
        name = "Vulcan Home Bridge";

        # Force HomeKit to bind completely to WiFi interface
        # ip_address controls TCP binding, advertise_ip controls mDNS
        # Both set to WiFi IP to ensure iPhone at 192.168.3.52 can discover bridge
        ip_address = "192.168.3.16";
        advertise_ip = "192.168.3.16";

        # Filter which entities to expose to HomeKit
        # Maximum 150 accessories per bridge
        filter = {
          include_domains = [
            "lock" # August/Yale locks
            "climate" # Nest thermostats
            "light" # Smart lights
            "switch" # Smart switches
            "cover" # Garage doors, blinds
            "fan" # Fans
            # Sensors removed - they clutter HomeKit and cause 100+ "Continue" prompts
            # If you need specific sensors, use include_entities instead
            "script" # ADT security system scripts
            # "vacuum" # REMOVED: Dreame vacuum - excessive HomeKit polling causes battery drain
            "media_player" # LG webOS TV
            "camera" # Ring doorbell cameras
            "button" # Doorbell buttons, etc.
          ];

          # Exclude noisy or unnecessary entities
          exclude_entity_globs = [
            "sensor.weather_*"
            "sensor.*_battery" # Battery sensors often clutter HomeKit
            "binary_sensor.*_connectivity" # Connectivity sensors
            "sensor.inverter_*" # Enphase solar inverter sensors (too many)
            "camera.*dreame*" # Dreamebot map cameras - causes excessive polling/battery drain
            "sensor.*dreame*map*" # Dreamebot map sensors
            # "sensor.*_probe_*" # Traeger grill probe sensors
            # "climate.slugify_*" # Traeger grill climate entities
          ];

          # Specific sensors/binary_sensors exposed to HomeKit (add more here):
          include_entities = [
            "sensor.upstairs_temperature"
            "sensor.downstairs_temperature"
            "sensor.family_room_temperature"
            "binary_sensor.front_door"
            # "binary_sensor.motion_sensor_hallway"
          ];
        };

        # Port for HomeKit accessory protocol (default: 21063)
        # port = 21063;
      };
    };

    # Allow configuration files to be writable from the UI
    configWritable = true;
    lovelaceConfigWritable = true;
  };

  # Ensure Home Assistant can access secrets
  systemd.services.home-assistant = {
    # Ensure all required services are ready before starting
    after = [
      "network-online.target"
      "nss-lookup.target"
      "postgresql.service"
      "postgresql-hass-password.service"
      "sops-install-secrets.service"
    ];
    wants = [
      "network-online.target"
      "nss-lookup.target"
      "postgresql.service"
      "postgresql-hass-password.service"
      "sops-install-secrets.service"
    ];
    # Restart HA when PostgreSQL restarts (e.g. during nixos-rebuild) so the
    # recorder reconnects cleanly instead of dropping state changes for hours.
    partOf = [ "postgresql.service" ];
    # Note: metric-manager dependency is handled via home-assistant-metric-trick.nix

    # Generate secrets.yaml and inject database URL into configuration.yaml
    preStart = ''
            # Remove HACS internal frontend symlinks that incorrectly appear in custom_components
            # These cause "Error loading integration" with KeyError: 'domain' because they
            # have manifest.json files without proper HA integration format
            rm -f /var/lib/hass/custom_components/frontend_es5
            rm -f /var/lib/hass/custom_components/frontend_latest

            # Ensure Nix-managed integrations are not tracked as HACS-installed.
            # HACS cannot update Nix store symlinks (shutil.rmtree fails on symlinks in
            # Python 3.12+, and Nix store files are read-only causing backup failures).
            # opnsense (travisghansen/hass-opnsense) is managed by Nix with Python 3.13
            # syntax patches that have not yet been merged upstream.
            if [ -f /var/lib/hass/.storage/hacs.repositories ]; then
              ${pkgs.python3}/bin/python3 ${hacsUntrackNixManaged}
            fi

            # Generate secrets.yaml with location data and database URL
            # Location coordinates for Sacramento, CA area
            cat > /var/lib/hass/secrets.yaml << 'EOF'
      # Auto-generated secrets file - location data
      # Update with your actual coordinates if needed
      latitude: 38.5816
      longitude: -121.4944
      elevation: 30
      EOF

            # Add PostgreSQL database URL if SOPS secret exists
            if [ -f ${config.sops.secrets."home-assistant/postgres-password".path} ]; then
              POSTGRES_PASSWORD=$(cat ${config.sops.secrets."home-assistant/postgres-password".path})
              echo "postgres_db_url: postgresql://hass:$POSTGRES_PASSWORD@localhost/hass" >> /var/lib/hass/secrets.yaml
            fi

            # Add OpenUV API key if SOPS secret exists
            if [ -f ${config.sops.secrets."home-assistant/openuv-api-key".path} ]; then
              OPENUV_API_KEY=$(cat ${config.sops.secrets."home-assistant/openuv-api-key".path})
              echo "openuv_api_key: $OPENUV_API_KEY" >> /var/lib/hass/secrets.yaml
            fi

            chmod 600 /var/lib/hass/secrets.yaml

            # Inject database URL directly into configuration.yaml
            if [ -f ${
              config.sops.secrets."home-assistant/postgres-password".path
            } ] && [ -f /var/lib/hass/configuration.yaml ]; then
              POSTGRES_PASSWORD=$(cat ${config.sops.secrets."home-assistant/postgres-password".path})

              # Remove any existing db_url line first
              grep -v "^  db_url:" /var/lib/hass/configuration.yaml > /var/lib/hass/configuration.yaml.tmp || true

              # Find the line number of "recorder:" and insert db_url after it
              ${pkgs.gawk}/bin/awk -v db_url="  db_url: postgresql://hass:$POSTGRES_PASSWORD@localhost/hass" \
                '/^recorder:/ { print; print db_url; next } { print }' \
                /var/lib/hass/configuration.yaml.tmp > /var/lib/hass/configuration.yaml.new

              # Replace original file
              mv /var/lib/hass/configuration.yaml.new /var/lib/hass/configuration.yaml
              rm -f /var/lib/hass/configuration.yaml.tmp

              chmod 600 /var/lib/hass/configuration.yaml
            fi
    '';

    # Inject the paths of the credential files as environment variables
    serviceConfig = {
      EnvironmentFile = [
        (pkgs.writeText "home-assistant-env" ''
          YALE_USERNAME_FILE=${config.sops.secrets."home-assistant/yale-username".path}
          YALE_PASSWORD_FILE=${config.sops.secrets."home-assistant/yale-password".path}
          OPNSENSE_URL_FILE=${config.sops.secrets."home-assistant/opnsense-url".path}
          OPNSENSE_API_KEY_FILE=${config.sops.secrets."home-assistant/opnsense-api-key".path}
          OPNSENSE_API_SECRET_FILE=${config.sops.secrets."home-assistant/opnsense-api-secret".path}
        '')
      ];
    };

    # Configure Python to use system CA bundle (includes step-ca root CA)
    environment = {
      SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";
    };

    # Add ffmpeg to PATH for Chime TTS audio processing
    path = [ pkgs.ffmpeg-full ];
  };

  # Fix ownership of Home Assistant state directory files
  # This ensures backup files and other writable config files have correct ownership
  # Fixes issue where UI-modified files are created as root:root instead of hass:hass
  systemd.tmpfiles.rules = [
    "d /var/lib/hass 0700 hass hass -"
    "Z /var/lib/hass 0700 hass hass -"
  ];

  # Home Assistant nginx upstream with retry logic
  # This prevents 502 errors during service restarts by retrying failed connections
  services.nginx.upstreams."home-assistant" = {
    servers = {
      "127.0.0.1:8123" = {
        max_fails = 0; # Don't mark backend as failed during temporary unavailability
      };
    };
    extraConfig = ''
      # Keep alive connections to backend for better performance
      keepalive 32;
      keepalive_timeout 60s;
    '';
  };

  # Home Assistant local access
  services.nginx.virtualHosts."hass.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/hass.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/hass.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://home-assistant/"; # Use upstream instead of direct connection
      proxyWebsockets = true;
      extraConfig = ''
        # Retry logic for temporary backend failures (service restarts)
        # This prevents 502 errors when Home Assistant is restarting
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;

        # Timeout settings for websockets
        proxy_connect_timeout 7d;
        proxy_send_timeout 7d;
        proxy_read_timeout 7d;

        # Connection pooling (required for keepalive upstream)
        # Note: proxy_http_version 1.1 is already set globally by nginx module
        proxy_set_header Connection "";
      '';
    };
  };

  # Open port 8123 on the loopback interface only (not on the LAN)
  # Access via nginx reverse proxy on port 443 (HTTPS)
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    8123 # Home Assistant web interface
  ];

  # Open firewall for local network access
  networking.firewall.allowedTCPPorts = [
    21063 # HomeKit Bridge accessory protocol
  ];

  networking.firewall.allowedUDPPorts = [
    5353 # mDNS for HomeKit/Bonjour discovery
  ];
}
