{ config, lib, pkgs, ... }:

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

  # PostgreSQL database for Home Assistant recorder
  services.postgresql = {
    ensureDatabases = [ "hass" ];
    ensureUsers = [{
      name = "hass";
      ensureDBOwnership = true;
    }];

    # Add peer authentication for hass user on local socket
    authentication = lib.mkAfter ''
      # Home Assistant local socket connection
      local   hass      hass                        peer
    '';
  };

  # Home Assistant service
  services.home-assistant = {
    enable = true;

    # Use PostgreSQL for better performance
    extraPackages = ps: with ps; [
      psycopg2  # PostgreSQL adapter
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
      "radio_browser"
      "shopping_list"

      # Network discovery
      "dhcp"
      "ssdp"
      "zeroconf"
      "upnp"

      # Mobile app support
      "mobile_app"

      # Automation and scripting
      "automation"
      "script"
      "scene"

      # Network devices
      "asuswrt"              # ASUS WiFi routers

      # Energy & Solar
      "enphase_envoy"        # Enphase Solar Inverter
      "tesla_wall_connector" # Tesla Wall Connector

      # Water monitoring
      "flume"                # Flume water meter

      # Climate control
      "nest"                 # Google Nest thermostats

      # Security & Access
      "ring"                 # Ring doorbell and chimes
      "myq"                  # MyQ garage door opener

      # Pool & Spa
      "screenlogic"          # Pentair IntelliCenter & IntelliFlo

      # Appliances
      "miele"                # Miele dishwasher

      # Casting & Display
      "cast"                 # Google Home Hub / Cast devices
    ];

    # Home Assistant configuration (YAML format)
    config = {
      # Default configuration enables several integrations
      default_config = {};

      # Basic settings
      homeassistant = {
        name = "Vulcan Home";
        latitude = "!secret latitude";
        longitude = "!secret longitude";
        elevation = "!secret elevation";
        unit_system = "metric";
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
          "192.168.1.2"  # vulcan's IP
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

      # Enable automation UI
      automation = "!include automations.yaml";

      # Enable scene UI
      scene = "!include scenes.yaml";

      # Enable script UI
      script = "!include scripts.yaml";
    };

    # Allow configuration files to be writable from the UI
    configWritable = true;
    lovelaceConfigWritable = true;
  };

  # Ensure Home Assistant can access secrets
  systemd.services.home-assistant = {
    after = [ "postgresql.service" "sops-install-secrets.service" ];
    wants = [ "postgresql.service" "sops-install-secrets.service" ];

    # Inject Yale credentials as environment variables
    serviceConfig = {
      EnvironmentFile = [
        (pkgs.writeText "home-assistant-env" ''
          YALE_USERNAME_FILE=${config.sops.secrets."home-assistant/yale-username".path}
          YALE_PASSWORD_FILE=${config.sops.secrets."home-assistant/yale-password".path}
        '')
      ];
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
  networking.firewall.interfaces."enp4s0".allowedTCPPorts = [ 8123 ];
}
