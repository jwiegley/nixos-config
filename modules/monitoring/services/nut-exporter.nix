{
  config,
  lib,
  pkgs,
  ...
}:

{
  # UPS / power monitoring. Feeds the rules in modules/monitoring/alerts/ups.yaml, which
  # carries the why: the measured baseline, the battery's age, and the automated
  # `systemctl poweroff` path in modules/services/nut.nix that this exporter makes visible.

  services.prometheus.exporters.nut = {
    enable = true;
    # Port 9199 is the upstream default. Verified free before use, per CLAUDE.md: not present
    # in docs/ports.txt and `ss -tunlp` showed nothing bound. Registered there in the same
    # commit.
    port = 9199;
    listenAddress = "127.0.0.1";
    nutServer = "127.0.0.1";
    # No nutUser/passwordPath on purpose. upsd here permits anonymous reads — confirmed both
    # by the upstream option docs ("Default NUT configs usually permit reading variables
    # without authentication") and empirically, since `upsc apc` returns the full variable
    # set with no credentials. Adding a user would mean provisioning a third NUT password in
    # SOPS for no gain, and the existing upsmon/homeassistant users are for control and the
    # HA integration respectively, not for scraping.
    # nutVariables MUST be set explicitly. The upstream option documentation says "If no
    # variables are set, all numeric variables will be exported automatically" -- that is
    # NOT true for this exporter build. Left empty it emits a built-in DEFAULT SUBSET of 8
    # metric families, and battery.runtime is missing from it even though upsc reports it as
    # a plain number (2601). A runtime-based alert would therefore have been dead on arrival.
    # Verified by diffing `upsc apc` against the exporter's /ups_metrics output.
    # ups.status is required for the flag-labelled series (OB/LB/RB/FSD/...).
    nutVariables = [
      "battery.charge"
      "battery.runtime"
      "battery.voltage"
      "ups.load"
      "ups.status"
      "input.voltage"
    ];
  };

  services.prometheus.scrapeConfigs = [
    {
      job_name = "nut";
      static_configs = [
        {
          targets = [ "127.0.0.1:9199" ];
          labels = {
            service = "ups";
            instance = "vulcan";
          };
        }
      ];
      # CRITICAL: metrics_path MUST be /ups_metrics, not the default /metrics.
      # This exporter (DRuggeri/nut_exporter) serves its OWN Go runtime metrics on /metrics
      # and the actual UPS variables on /ups_metrics. Scraping the default path yields
      # HTTP 200 with go_* metrics and ZERO UPS data -- a target that is permanently `up`
      # while collecting nothing, which is exactly the green-but-useless failure this whole
      # effort exists to remove. Verified empirically: /metrics has 0 network_ups_* lines,
      # /ups_metrics has 22.
      metrics_path = "/ups_metrics";
      # The UPS is a slow-changing device and upsd polls the USB HID at its own cadence;
      # 30s is plenty and avoids hammering the driver.
      scrape_interval = "30s";
    }
  ];
}
