{
  config,
  lib,
  pkgs,
  ...
}:

{
  # UPS / power monitoring — closes a total blind spot.
  #
  # Until 2026-07-29 the UPS was COMPLETELY unmonitored: no exporter, no alert rule, no
  # Nagios check. `{__name__=~"nut_.*|network_ups_.*|ups_.*"}` returned zero series, and a
  # scan of all ~500 alert rules for ups/nut/battery/power/apc matched nothing about the
  # UPS. That mattered more than it sounds, for three compounding reasons:
  #
  #   1. There is an AUTOMATED SHUTDOWN PATH. modules/services/nut.nix runs a 30s poll that
  #      execs `systemctl poweroff` when status contains OB and charge < 50. The script is
  #      fail-safe, but its only trace is a single `logger -p daemon.warning` line, which
  #      nothing scrapes — so an automatic poweroff of this host would generate NO alert.
  #   2. The battery is at the end of its service life: battery.mfr.date 2022/08/13, i.e.
  #      ~4 years, at the top of APC's 3-5 year replacement window.
  #   3. ups.test.result reads "No test initiated", so the 43-minute battery.runtime figure
  #      is an unvalidated vendor estimate, never confirmed under load.
  #
  # So the machine could lose power protection silently, and the first symptom would be the
  # host disappearing. This is also cross-domain: the tank pool lives in a USB enclosure whose
  # documented 2026-06-02 failure mode is a load-induced bridge hang, and unclean power is the
  # classic trigger for exactly that.
  #
  # NOTE this is a first-class NixOS option (services.prometheus.exporters.nut), NOT a
  # bespoke script. The remediation plan classified UPS monitoring as possible scope-creep
  # requiring a new textfile collector; that was wrong, and it is why this is a small module.

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

  environment.systemPackages = [ ];
}
