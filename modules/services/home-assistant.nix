{
  config,
  lib,
  pkgs,
  ...
}:

let
  hacs-frontend-pkg = pkgs.python3Packages.hacs-frontend;

  # Custom Python packages for Hubspace integration
  securelogging = pkgs.python3Packages.buildPythonPackage rec {
    pname = "securelogging";
    version = "1.0.1";
    format = "wheel";

    src = pkgs.fetchPypi {
      inherit pname version format;
      dist = "py3";
      python = "py3";
      sha256 = "sha256-0URfkqVVXZRwLuwH/yU+4XvWOrpb3T5q8ew/eynhpQw=";
    };

    doCheck = false; # Skip tests for simplicity
  };

  aioafero = pkgs.python3Packages.buildPythonPackage rec {
    pname = "aioafero";
    version = "6.0.1";
    pyproject = true;

    src = pkgs.fetchPypi {
      inherit pname version;
      sha256 = "1a66e3e4e9dae32295b136e5ca87536e73f5143c16dae8bbebe421f0e895e7ac";
    };

    build-system = with pkgs.python3Packages; [
      hatchling
    ];

    dependencies = with pkgs.python3Packages; [
      aiohttp
      beautifulsoup4
      securelogging
    ];

    doCheck = false; # Skip tests to avoid test dependencies
  };

  # Custom Python package for Bose integration
  pybose = pkgs.python3Packages.buildPythonPackage rec {
    pname = "pybose";
    version = "2025.8.2";
    pyproject = true;

    src = pkgs.fetchPypi {
      inherit pname version;
      sha256 = "47c2a4c96b9c8ca59d0f275e6feaef30bb641b4c11c97d65d8c5f036d558f28a";
    };

    build-system = with pkgs.python3Packages; [
      setuptools
    ];

    dependencies = with pkgs.python3Packages; [
      zeroconf
      websockets
    ];

    doCheck = false; # Skip tests to avoid test dependencies
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

  # BMW ConnectedDrive credentials
  sops.secrets."home-assistant/bmw-username" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/bmw-password" = {
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

  # Opower/SMUD credentials for energy usage data
  sops.secrets."home-assistant/smud-username" = {
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/smud-password" = {
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

  # Avahi service for mDNS/Bonjour discovery (required for HomeKit)
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
      # Memory settings - tune for time-series data
      shared_buffers = "256MB"; # Increased from 128MB default for better caching
      effective_cache_size = "1GB"; # Hint to query planner about available cache
      work_mem = "16MB"; # Increased for better sort/hash operations
      maintenance_work_mem = "128MB"; # For VACUUM, CREATE INDEX, etc.

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
    after = [ "postgresql.service" "sops-install-secrets.service" ];
    requires = [ "postgresql.service" "sops-install-secrets.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      # Read password (file is owned by hass, so we need to use runuser)
      PASSWORD=$(${pkgs.util-linux}/bin/runuser -u hass -- cat ${config.sops.secrets."home-assistant/postgres-password".path})
      ${config.services.postgresql.package}/bin/psql -c "ALTER USER hass WITH PASSWORD '$PASSWORD';"
    '';
  };

  # Home Assistant service
  services.home-assistant = {
    enable = true;

    # Custom components installed via overlays
    customComponents = with pkgs.home-assistant-custom-components; [
      # HACS with manifest check disabled
      # Fix for manifestCheckPhase error on aarch64 (Asahi)
      # Issue: frontend manifest.json files are incorrectly validated as HA component manifests
      (hacs.overrideAttrs (oldAttrs: {
        doInstallCheck = false;
      }))
      intellicenter # Pentair IntelliCenter integration
    ];

    # Use PostgreSQL for better performance
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
      aioafero # Custom package for Hubspace integration
      ps.pychromecast # Required for Bose integration
      pybose # Custom package for Bose integration
      ps.pyicloud # Required for Apple iCloud integration
      ps.webcolors # Required for Local LLMs (llama_conversation) custom component
    ];

    # Components that don't require YAML configuration
    extraComponents = [
      # Core integrations
      "analytics"
      "default_config"
      "met"

      # Yale/August lock integration
      "yale_home"
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

      # Network devices
      "asuswrt" # ASUS WiFi routers
      "tplink" # TP-Link Smart Home (Kasa/Tapo devices)
      # OPNsense firewall - use HACS custom component instead
      # Built-in integration has JSON parsing issues with newer OPNsense versions

      # Energy & Solar
      "enphase_envoy" # Enphase Solar Inverter
      "tesla_wall_connector" # Tesla Wall Connector

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

      # Health & Fitness
      "withings" # Withings digital scale and health devices

      # Vehicles
      "bmw_connected_drive" # BMW ConnectedDrive vehicle integration

      # Smart TVs
      "webostv" # LG webOS Smart TV

      # HomeKit Bridge
      "homekit" # Expose Home Assistant entities to Apple HomeKit/Siri

      # Utility Data
      "opower" # Energy usage from utility companies (SMUD)

      # Weather
      "accuweather" # AccuWeather weather forecasts
      "nws" # National Weather Service (NOAA) weather forecasts
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

        # Trust the nginx reverse proxy
        auth_providers = [
          {
            type = "homeassistant";
          }
        ];

        # Enable packages for modular configuration
        # Allows loading additional config from /var/lib/hass/packages/*.yaml
        packages = "!include_dir_named packages";
      };

      # HTTP configuration for reverse proxy
      http = {
        # Use X-Forwarded-For headers from nginx
        use_x_forwarded_for = true;
        trusted_proxies = [
          "127.0.0.1"
          "::1"
          "192.168.1.2" # vulcan's IP
        ];

        # Disable direct HTTP access (use nginx proxy)
        server_host = "127.0.0.1";
        server_port = 8123;
      };

      # Recorder - using PostgreSQL for better performance and memory efficiency
      recorder = {
        # Don't specify db_url here - it will be set via environment variable
        # This allows us to inject the SOPS-managed password securely

        auto_purge = true;
        purge_keep_days = 30;
        commit_interval = 5; # Reduced from 1 to improve performance

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

      # History - controls what entities are shown in UI history
      # This should generally match recorder exclusions for consistency
      history = {
        use_include_order = true;

        # Include important domains for UI history
        include = {
          domains = [
            "lock" # Door locks
            "binary_sensor" # Motion, door/window sensors
            "sensor" # Most sensors
            "climate" # Thermostats
            "light" # Lights
            "switch" # Switches
            "cover" # Garage doors, blinds
            "fan" # Fans
            "person" # Person presence
            "device_tracker" # Location tracking (filtered below)
            "media_player" # Media devices
            "vacuum" # Vacuum cleaners
            "camera" # Cameras
            "weather" # Weather (aggregate only)
          ];
        };

        # Exclude the same noisy entities as recorder for UI performance
        exclude = {
          # Explicit entity exclusions (same as recorder)
          entities = [
            "sensor.john_iphone_info"
            "sensor.john_iphone_next_update"
            "sensor.john_iphone_last_update"
            "sensor.nasim_iphone_info"
            "sensor.nasim_iphone_next_update"
            "sensor.nasim_iphone_last_update"
            "sensor.johns_mac_studio_frontmost_app"
            "sensor.clio_2_frontmost_app"
            "sensor.smart_plug_tv_voltage"
            "device_tracker.asus_john_iphone"
            "device_tracker.asus_nasim_iphone"
          ];

          entity_globs = [
            # Same exclusions as recorder to keep UI responsive
            "sensor.weather_*" # Weather detail sensors (keep weather.* entity)
            "sensor.*_info" # High-frequency info sensors
            "sensor.*_next_update"
            "sensor.*_last_update"
            "sensor.*_last_located"
            "sensor.*_voltage" # Voltage sensors
            "sensor.router_cpu_*" # Router monitoring
            "sensor.router_temp_*"
            "sensor.router_system_load_*"
            "sensor.*_frontmost_app" # Mac Studio app tracking
            "sensor.*_storage" # Storage sensors
            "device_tracker.enphase_*" # Network device trackers
            "device_tracker.dreame_*"
            "device_tracker.espressif_*"
            "device_tracker.98_03_8e_*" # MAC address trackers
          ];
        };
      };

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
          "kasa.smart.smartdevice" = "error"; # TP-Link Kasa session closed errors
          "pubnub" = "error"; # Ring doorbell PubNub connector errors
        };
      };

      # OPNsense firewall integration
      # The built-in integration has issues with newer OPNsense versions (25.7+)
      # Use the HACS custom component "travisghansen/hass-opnsense" instead:
      # 1. Install HACS: https://hacs.xyz/docs/setup/download
      # 2. Add custom repository in HACS: https://github.com/travisghansen/hass-opnsense
      # 3. Install the integration via HACS
      # 4. Configure via UI: Settings > Devices & Services > Add Integration > OPNsense
      # Built-in YAML configuration disabled:
      # opnsense = {
      #   url = "!secret opnsense_url";
      #   api_key = "!secret opnsense_api_key";
      #   api_secret = "!secret opnsense_api_secret";
      #   verify_ssl = true;
      # };

      # Enable automation UI
      automation = "!include automations.yaml";

      # Enable scene UI
      scene = "!include scenes.yaml";

      # Enable script UI
      script = "!include scripts.yaml";

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
          ];
        }
      ];

      # HomeKit Bridge integration
      # Exposes Home Assistant entities to Apple HomeKit for Siri control
      homekit = {
        # Name shown in Apple Home app
        name = "Vulcan Home Bridge";

        # Advertise on the main network interface IP
        # This ensures iPhone/iPad on the local network can connect
        ip_address = "192.168.1.2";

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
            "sensor" # Temperature, humidity sensors
            "binary_sensor" # Motion, door/window sensors
            "script" # ADT security system scripts
            "vacuum" # Dreame robot vacuum
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
            # "sensor.*_probe_*" # Traeger grill probe sensors
            # "climate.slugify_*" # Traeger grill climate entities
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
    after = [
      "postgresql.service"
      "postgresql-hass-password.service"
      "sops-install-secrets.service"
    ];
    wants = [
      "postgresql.service"
      "postgresql-hass-password.service"
      "sops-install-secrets.service"
    ];

    # Generate secrets.yaml and inject database URL into configuration.yaml
    preStart = ''
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

      chmod 600 /var/lib/hass/secrets.yaml

      # Inject database URL directly into configuration.yaml
      if [ -f ${config.sops.secrets."home-assistant/postgres-password".path} ] && [ -f /var/lib/hass/configuration.yaml ]; then
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

    # Inject credentials as environment variables
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
  };

  # Fix ownership of Home Assistant state directory files
  # This ensures backup files and other writable config files have correct ownership
  # Fixes issue where UI-modified files are created as root:root instead of hass:hass
  systemd.tmpfiles.rules = [
    "d /var/lib/hass 0700 hass hass -"
    "Z /var/lib/hass 0700 hass hass -"
  ];

  # Home Assistant local access
  services.nginx.virtualHosts."hass.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/hass.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/hass.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:8123/";
      proxyWebsockets = true;
      extraConfig = ''
        # Timeout settings for websockets
        proxy_connect_timeout 7d;
        proxy_send_timeout 7d;
        proxy_read_timeout 7d;
      '';
    };
  };

  # Open firewall for local network access only
  # Access via nginx reverse proxy on port 443 (HTTPS)
  networking.firewall.interfaces."end0".allowedTCPPorts = [
    8123 # Home Assistant web interface
    21063 # HomeKit Bridge accessory protocol
  ];

  networking.firewall.interfaces."end0".allowedUDPPorts = [
    5353 # mDNS for HomeKit/Bonjour discovery
  ];
}
