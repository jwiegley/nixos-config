{
  config,
  lib,
  ...
}:

let
  port = 9114;
  user = "mqtt-exporter";
in
{
  # ---------------------------------------------------------------------------
  # MQTT -> Prometheus bridge.
  #
  # Closes the one genuine gap in the house messaging setup: until this existed
  # there were ZERO MQTT-derived series and zero MQTT scrape jobs in Prometheus,
  # so nothing published to the broker was observable, alertable or graphable.
  # Devices could talk to each other, and nobody could measure it.
  #
  # WHY AN EXPORTER RATHER THAN A DIFFERENT BROKER. A message broker's own
  # Prometheus support -- RabbitMQ's plugin, mosquitto's $SYS tree -- reports on
  # the BROKER: connection counts, message rates, queue depth. It does not turn
  # message *payloads* into metrics. A sensor publishing {"temperature": 21.4}
  # yields "one message passed through" and no temperature series. Translating
  # payloads is a separate job, and this is the thing that does it.
  #
  # The mapping lives here rather than on the devices, which is the property that
  # makes it useful: a commercial sensor or a phone app that cannot be modified
  # still becomes metrics, because the translation happens on this side.
  # ---------------------------------------------------------------------------

  # Read-only broker account. Follows the same rule as the awtrix user in
  # modules/services/mosquitto.nix: its own identity, least privilege, rather
  # than borrowing `homeassistant` which holds `readwrite #` over everything.
  # An exporter has no business publishing at all, so the ACL grants only `read`.
  sops.secrets."mqtt/exporter-password" = {
    owner = "mosquitto";
    group = "mosquitto";
    mode = "0400";
    restartUnits = [ "mosquitto.service" ];
  };

  # mqtt-exporter reads its password from the environment variable MQTT_PASSWORD
  # and NOTHING else -- it has no config file, no command-line flag, and (checked
  # against the 1.9.0 source, mqtt_exporter/settings.py) no MQTT_PASSWORD_FILE
  # form. So the secret has to reach it as an env var, and the only way to do
  # that without writing it into the world-readable Nix store is to render an
  # EnvironmentFile from the SOPS value at activation time.
  #
  # Ownership is why this is a template rather than a second `sops.secrets`
  # entry: the declaration above is 0400 mosquitto:mosquitto by design, so the
  # exporter's own user cannot read it.
  sops.templates."mqtt-exporter.env" = {
    content = ''
      MQTT_PASSWORD=${config.sops.placeholder."mqtt/exporter-password"}
    '';
    owner = user;
    group = user;
    mode = "0400";
    restartUnits = [ "prometheus-mqtt-exporter.service" ];
  };

  users.users.${user} = {
    isSystemUser = true;
    group = user;
    description = "Prometheus MQTT exporter";
  };
  users.groups.${user} = { };

  services.prometheus.exporters.mqtt = {
    enable = true;
    inherit port user;
    group = user;
    listenAddress = "127.0.0.1";

    mqttAddress = "127.0.0.1";
    mqttPort = 1883;
    mqttUsername = user;
    environmentFile = config.sops.templates."mqtt-exporter.env".path;

    # Subscribe to everything. The broker ACL is what actually bounds this, and
    # a firehose is the point -- the stated goal is to observe traffic between
    # any two devices, which means not deciding in advance what is interesting.
    mqttTopic = "#";

    # These patterns are fnmatch GLOBS, not MQTT topic filters -- the exporter
    # matches with fnmatch.fnmatch(topic, pattern) (main.py:474). In fnmatch `#`
    # is an ORDINARY CHARACTER, so the MQTT-style "homeassistant/#" matches only
    # a topic literally named that and silently filters nothing. Use `*`, which
    # in fnmatch spans `/` and so covers the whole subtree.
    #
    # What is dropped and why -- these are retained CONFIGURATION documents that
    # the exporter faithfully flattens into one metric per JSON field:
    #
    #   homeassistant/*  -- MQTT discovery documents plus HASS.Agent attribute
    #     blobs. Republished on every device announce, so they also churn.
    #   awtrixNG/state/capabilities -- the device's GPIO pin map (matrix, RTC and
    #     strapping pins). A static hardware description that cannot change
    #     without new hardware, and on its own the single largest source here.
    #
    # Together these were 246 of 452 series. The remaining state/device,
    # state/settings and state/audio topics are kept: they are small, and they
    # carry the real telemetry (uptime, heap, RSSI, battery, temperature) mixed
    # in with the settings. The ceiling to stay under is MAX_METRICS (default
    # 2000), past which the exporter stops registering new metrics entirely.
    mqttIgnoredTopics = [
      "homeassistant/*"
      "awtrixNG/state/capabilities"
    ];

    prometheusPrefix = "mqtt_";

    # Keep the originating topic as a label; without it every device's readings
    # collapse into one indistinguishable series.
    topicLabel = "topic";

    logLevel = "INFO";
  };

  # EXPOSE_LAST_SEEN has no option in the upstream NixOS module, so it is set
  # directly. The exporter compares it against the exact string "True"
  # (settings.py: `os.getenv("EXPOSE_LAST_SEEN", "False") == "True"`), so the
  # capitalisation here is load-bearing -- "true" silently means false.
  systemd.services.prometheus-mqtt-exporter = {
    after = [ "mosquitto.service" ];
    wants = [ "mosquitto.service" ];
    environment.EXPOSE_LAST_SEEN = "True";
  };

  services.prometheus.scrapeConfigs = lib.mkIf config.services.prometheus.enable [
    {
      job_name = "mqtt";
      scrape_interval = "30s";
      static_configs = [
        {
          targets = [ "127.0.0.1:${toString port}" ];
          labels.service = "mqtt";
        }
      ];
    }
  ];
}
