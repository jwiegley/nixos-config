{ config, lib, pkgs, ... }:

{
  # Home Assistant Prometheus exporter configuration
  # Scrapes metrics from Home Assistant's built-in Prometheus endpoint
  # Requires a long-lived access token for authentication

  # SOPS secret for Home Assistant Prometheus token
  sops.secrets."prometheus/home-assistant-token" = {
    sopsFile = ../../../secrets.yaml;
    owner = "prometheus";
    group = "prometheus";
    mode = "0400";
    restartUnits = [ "prometheus.service" ];
  };

  # Disable Prometheus config check for this integration
  # The token file won't exist at build time, so we skip validation
  services.prometheus.checkConfig = false;

  # Create runtime directory for prometheus token
  systemd.tmpfiles.rules = lib.mkIf config.services.home-assistant.enable [
    "d /var/lib/prometheus-hass 0700 prometheus prometheus -"
  ];

  # Inject token loading into Prometheus service
  systemd.services.prometheus = lib.mkIf config.services.home-assistant.enable {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
    preStart = lib.mkBefore ''
      # Load Home Assistant token for scraping
      TOKEN_FILE="${config.sops.secrets."prometheus/home-assistant-token".path}"
      OUTPUT_FILE="/var/lib/prometheus-hass/token"

      # Wait for SOPS to create the token file
      for i in {1..10}; do
        if [ -f "$TOKEN_FILE" ]; then
          break
        fi
        echo "Waiting for SOPS token file... ($i/10)"
        sleep 1
      done

      # Copy token to the output file
      if [ -f "$TOKEN_FILE" ]; then
        cat "$TOKEN_FILE" > "$OUTPUT_FILE"
        chmod 600 "$OUTPUT_FILE"
        echo "Home Assistant token loaded successfully"
      else
        echo "Warning: Home Assistant token file not found at $TOKEN_FILE"
        echo "placeholder" > "$OUTPUT_FILE"
      fi
    '';
  };

  # Prometheus scrape configuration for Home Assistant
  services.prometheus.scrapeConfigs = lib.mkIf config.services.home-assistant.enable [
    {
      job_name = "home_assistant";
      scrape_interval = "60s";
      metrics_path = "/api/prometheus";
      scheme = "https";

      # Authentication using long-lived access token
      # Token file is created at Prometheus startup
      authorization = {
        type = "Bearer";
        credentials_file = "/var/lib/prometheus-hass/token";
      };

      static_configs = [{
        targets = [ "hass.vulcan.lan:443" ];
        labels = {
          instance = "vulcan";
          service = "home-assistant";
        };
      }];

      # TLS configuration to trust step-ca certificates
      tls_config = {
        ca_file = "/etc/ssl/certs/ca-bundle.crt";
        insecure_skip_verify = false;
      };
    }
  ];

  # Documentation
  environment.etc."prometheus/home-assistant-exporter-README.md" = {
    text = ''
      # Home Assistant Prometheus Exporter

      ## Overview
      This module configures Prometheus to scrape metrics from Home Assistant's
      built-in Prometheus exporter endpoint.

      ## Endpoint
      - URL: https://hass.vulcan.lan/api/prometheus
      - Authentication: Bearer token (long-lived access token)
      - Scrape interval: 60 seconds

      ## Creating a Long-Lived Access Token

      1. Access Home Assistant: https://hass.vulcan.lan
      2. Click on your profile (bottom left)
      3. Scroll down to "Long-Lived Access Tokens"
      4. Click "Create Token"
      5. Name: "Prometheus"
      6. Copy the token (shown only once!)

      ## Adding Token to Secrets

      Edit the encrypted secrets file:
      ```bash
      sops /etc/nixos/secrets.yaml
      ```

      Add the token under the prometheus section:
      ```yaml
      prometheus:
        home-assistant-token: "your_long_lived_access_token_here"
      ```

      Rebuild the configuration:
      ```bash
      sudo nixos-rebuild switch --flake '.#vulcan'
      ```

      ## Available Metrics

      Home Assistant exposes metrics for all configured entities:
      - **Sensors**: Temperature, humidity, energy usage, etc.
      - **Climate**: Thermostat state, target temperature, HVAC mode
      - **Binary Sensors**: Motion, door/window state, occupancy
      - **Locks**: Lock state (August locks, etc.)
      - **Switches & Lights**: On/off state, brightness
      - **Covers**: Position, open/closed state

      Example metrics:
      - `homeassistant_sensor_temperature_celsius{entity="sensor.kitchen_temperature"}`
      - `homeassistant_climate_current_temperature_celsius{entity="climate.nest_thermostat"}`
      - `homeassistant_sensor_state{entity="sensor.pool_intellichlor_salt_ppm"}`

      ## Querying in Prometheus

      Access Prometheus: https://prometheus.vulcan.lan

      Example queries:
      ```promql
      # Current house temperature
      homeassistant_sensor_temperature_celsius{entity=~"sensor.*_temperature"}

      # Pool salinity
      homeassistant_sensor_state{entity="sensor.pool_intellichlor_salt_ppm"}

      # Lock states
      homeassistant_lock_state{domain="lock"}

      # All Home Assistant metrics
      {__name__=~"homeassistant_.*"}
      ```

      ## Grafana Dashboards

      Access Grafana: https://grafana.vulcan.lan

      To create a dashboard for Home Assistant metrics:
      1. Go to Dashboards > New Dashboard
      2. Add Panel
      3. Select "Prometheus" as data source
      4. Use PromQL queries to visualize your metrics

      Community dashboards:
      - https://grafana.com/grafana/dashboards/11021 (Home Assistant)
      - https://grafana.com/grafana/dashboards/12049 (Home Assistant Detailed)

      ## Troubleshooting

      Check if Home Assistant exporter is responding:
      ```bash
      # Test endpoint (requires token)
      curl -H "Authorization: Bearer YOUR_TOKEN" https://hass.vulcan.lan/api/prometheus
      ```

      Check Prometheus scrape status:
      ```bash
      # Visit Prometheus web UI
      https://prometheus.vulcan.lan/targets

      # Look for "home_assistant" job
      ```

      Check Prometheus logs:
      ```bash
      sudo journalctl -u prometheus -f | grep home_assistant
      ```

      ## Filtering Metrics

      To reduce metric volume, edit the filter in:
      `/etc/nixos/modules/services/home-assistant.nix`

      Example - only expose temperature sensors:
      ```nix
      prometheus = {
        filter = {
          include_entity_globs = [
            "sensor.*_temperature"
            "climate.*"
          ];
        };
      };
      ```
    '';
    mode = "0644";
  };
}
