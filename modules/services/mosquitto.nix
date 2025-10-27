{ config, lib, pkgs, ... }:

{
  # SOPS secrets for MQTT broker authentication
  sops.secrets."mqtt/hass-agent-password" = {
    owner = "mosquitto";
    group = "mosquitto";
    mode = "0400";
    restartUnits = [ "mosquitto.service" ];
  };

  sops.secrets."mqtt/homeassistant-password" = {
    owner = "mosquitto";
    group = "mosquitto";
    mode = "0400";
    restartUnits = [ "mosquitto.service" ];
  };

  # Mosquitto MQTT broker for Home Assistant and HASS.Agent integration
  services.mosquitto = {
    enable = true;

    # Single listener on all interfaces (localhost + LAN)
    # 0.0.0.0 binds to all interfaces, so both local HA and remote HASS.Agent can connect
    listeners = [
      {
        address = "0.0.0.0";
        port = 1883;

        users = {
          homeassistant = {
            # Password from SOPS secret
            passwordFile = config.sops.secrets."mqtt/homeassistant-password".path;
            acl = [ "readwrite #" ]; # Full access to all topics
          };

          hass-agent = {
            # Password from SOPS secret
            passwordFile = config.sops.secrets."mqtt/hass-agent-password".path;
            acl = [
              "readwrite hass.agent/#"  # HASS.Agent device topics
              "readwrite homeassistant/#"  # Home Assistant topics
            ];
          };
        };

        settings = {
          allow_anonymous = false;
        };
      }
    ];
  };

  # Open firewall for MQTT broker
  networking.firewall = {
    allowedTCPPorts = [
      1883  # MQTT (unencrypted, LAN only)
    ];
  };
}
