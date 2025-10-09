{
  config,
  lib,
  pkgs,
  ...
}:

let
  hacs-frontend-pkg = pkgs.python3Packages.hacs-frontend;
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
      ps.python-miio # Required for Dreame Vacuum integration
      ps.pybase64 # Required for Dreame Vacuum integration
      ps.paho-mqtt # Required for Dreame Vacuum integration
      ps.aiomqtt # Required for Traeger WiFIRE integration
      ps.mini_racer # Required for Dreame Vacuum integration (V8 JavaScript engine)
      ps.openai # Required for Extended OpenAI Conversation custom component
      ps.tiktoken # Required for Extended OpenAI Conversation (token counting)
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
          "homeassistant.components.yale_home" = "debug";
          "homeassistant.components.august" = "debug";
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
          ];

          # Optionally exclude specific entity patterns
          # exclude_entity_globs = [
          #   "sensor.weather_*"
          # ];
        };
      };

      # HomeKit Bridge integration
      # Exposes Home Assistant entities to Apple HomeKit for Siri control
      homekit = {
        # Name shown in Apple Home app
        name = "Vulcan Home Bridge";

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
          ];

          # Exclude noisy or unnecessary entities
          exclude_entity_globs = [
            "sensor.weather_*"
            "sensor.*_battery" # Battery sensors often clutter HomeKit
            "binary_sensor.*_connectivity" # Connectivity sensors
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
