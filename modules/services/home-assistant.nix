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
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/yale-password" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/opnsense-url" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/opnsense-api-key" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/opnsense-api-secret" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # BMW ConnectedDrive credentials
  sops.secrets."home-assistant/bmw-username" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/bmw-password" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # LG ThinQ Personal Access Token (PAT)
  sops.secrets."home-assistant/lg-thinq-token" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # Opower/SMUD credentials for energy usage data
  sops.secrets."home-assistant/smud-username" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/smud-password" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # Google Assistant SDK credentials
  sops.secrets."home-assistant/google-assistant-client-id" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  sops.secrets."home-assistant/google-assistant-client-secret" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
  };

  # OpenAI API key for Extended OpenAI Conversation integration
  # Used for LLM-powered conversation and automation
  sops.secrets."home-assistant/openai-api-key" = {
    sopsFile = ../../secrets.yaml;
    owner = "hass";
    group = "hass";
    mode = "0400";
    restartUnits = [ "home-assistant.service" ];
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

    # Add peer authentication for hass user on local socket
    authentication = lib.mkAfter ''
      # Home Assistant local socket connection
      local   hass      hass                        peer
    '';
  };

  # Home Assistant service
  services.home-assistant = {
    enable = true;

    # Custom components installed via overlays
    customComponents = with pkgs.home-assistant-custom-components; [
      hacs # Home Assistant Community Store
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
      ps.openai # Required for Extended OpenAI Conversation custom component
      ps.tiktoken # Required for Extended OpenAI Conversation (token counting)
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

      # Recorder - using default SQLite for now (PostgreSQL connection issues)
      recorder = {
        auto_purge = true;
        purge_keep_days = 30;
        commit_interval = 1;

        # Exclude noisy sensors
        exclude = {
          domains = [
            "automation"
            "updater"
          ];
          entity_globs = [
            "sensor.weather_*"
            # Enphase: Exclude individual inverter/panel sensors (keep aggregate sensors)
            "sensor.inverter_*"
            # Dreame Vacuum: Exclude per-room cleaning configuration entities
            "select.*_room_*"
            "sensor.*_room_*"
            "switch.*_room_*"
          ];
        };
      };

      # History
      history = {
        use_include_order = true;
        include = {
          domains = [
            "lock"
            "binary_sensor"
            "sensor"
          ];
        };
      };

      # Logger
      logger = {
        default = "info";
        logs = {
          "homeassistant.core" = "info";
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

      # Prometheus exporter for metrics
      # Exposes Home Assistant metrics at /api/prometheus
      # Authentication required via long-lived access token
      prometheus = {
        # Add namespace prefix to all metrics
        # namespace = "hass";

        # Filter which entities to expose
        # By default, all supported entities are exposed
        filter = {
          # Include all sensor and climate domains (temperature, humidity, etc.)
          include_domains = [
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

          # Exclude excessive/noisy entity patterns from Prometheus metrics
          # Note: Enphase inverter sensors are excluded from recorder (HA UI)
          # but included in Prometheus for individual panel monitoring
          exclude_entity_globs = [
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
      "sops-install-secrets.service"
    ];
    wants = [
      "postgresql.service"
      "sops-install-secrets.service"
    ];

    # Inject Yale and OPNsense credentials as environment variables
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
  networking.firewall.interfaces."enp4s0".allowedTCPPorts = [
    8123 # Home Assistant web interface
    21063 # HomeKit Bridge accessory protocol
  ];

  networking.firewall.interfaces."enp4s0".allowedUDPPorts = [
    5353 # mDNS for HomeKit/Bonjour discovery
  ];
}
