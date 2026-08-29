{
  config,
  lib,
  pkgs,
  ...
}:

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

  # Ulanzi TC001 running AWTRIX NG. Its own account rather than reusing
  # `homeassistant`, which holds `readwrite #` over every topic on the broker --
  # a display panel should not be able to write to Home Assistant's own topics.
  sops.secrets."mqtt/awtrix-password" = {
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
              "readwrite hass.agent/#" # HASS.Agent device topics
              "readwrite homeassistant/#" # Home Assistant topics
            ];
          };

          # Ulanzi TC001 / AWTRIX NG desk clock.
          #
          # The first ACL must match the device's `mqttPrefix` setting exactly.
          # AWTRIX only reads topics under <prefix>/cmd/ and only writes under
          # <prefix>/state/ and <prefix>/availability, so one subtree covers the
          # whole device interface. If mqttPrefix is left EMPTY the firmware falls
          # back to the 12-character MAC as the prefix, and this rule stops
          # matching -- set the prefix on the device before wondering why nothing
          # arrives.
          #
          # The homeassistant/ rules are narrower than the `readwrite
          # homeassistant/#` that hass-agent uses. AWTRIX needs exactly two things
          # there: publish its retained discovery document, which lands on
          # homeassistant/device/<uid>/config, and notice when Home Assistant
          # restarts so it can re-announce. If discovery silently fails to appear,
          # widening the second rule to `readwrite homeassistant/#` is the
          # diagnostic step -- but try the narrow form first, since a display
          # panel has no business writing to arbitrary HA topics.
          awtrix = {
            passwordFile = config.sops.secrets."mqtt/awtrix-password".path;
            acl = [
              "readwrite awtrixNG/#" # device command + state topics
              "readwrite homeassistant/device/#" # its MQTT discovery document
              "read homeassistant/status" # HA birth/will, to re-announce
            ];
          };

          # Prometheus MQTT exporter. READ-ONLY on purpose: an exporter observes,
          # it never publishes, so `read #` is the whole requirement. This is the
          # widest read grant on the broker and that is deliberate -- the point of
          # the exporter is to see traffic between any two devices, which means it
          # cannot be scoped to a subtree without blinding it.
          mqtt-exporter = {
            passwordFile = config.sops.secrets."mqtt/exporter-password".path;
            acl = [ "read #" ];
          };
        };

        settings = {
          allow_anonymous = false;
        };
      }
    ];
  };

  # Systemd service hardening
  systemd.services.mosquitto = {
    serviceConfig = {
      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      PrivateMounts = true;

      # System call filtering
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
      SystemCallErrorNumber = "EPERM";
      SystemCallArchitectures = "native";

      # Capabilities
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

      # Resource limits
      MemoryDenyWriteExecute = true;

      # Writable directories (mosquitto needs to write state/logs)
      ReadWritePaths = [ "/var/lib/mosquitto" ];
    };
  };

  # Open firewall for MQTT broker
  networking.firewall = {
    allowedTCPPorts = [
      1883 # MQTT (unencrypted, LAN only)
    ];
  };
}
