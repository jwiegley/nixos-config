{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Alert rules directory
  alertRulesDir = ../alerts;

  # Alert files deliberately PARKED out of the rule set. A parked file stays on disk, so
  # re-enabling it is a one-line change rather than a git revert, but Prometheus never loads
  # it. The list is shared with nagios-prometheus-mirror.nix, which does its own independent
  # readDir over the same directory -- parking here alone would leave Nagios still generating
  # a `PROM-MIRROR <alertname>` service per rule. See the file for that history.
  parkedAlertFiles = (import ../parked-alerts.nix).prometheus;

  # Auto-discover all .yaml alert files in the alerts directory, minus the parked ones
  alertFiles = builtins.filter (
    name: lib.hasSuffix ".yaml" name && !(builtins.elem name parkedAlertFiles)
  ) (builtins.attrNames (builtins.readDir alertRulesDir));

  # A parked name that does not exist is almost certainly a typo, and it would fail silently
  # (filtering nothing) -- which is how a "disabled" alert stays live.
  presentYaml = builtins.attrNames (builtins.readDir alertRulesDir);
  missingParked = builtins.filter (name: !(builtins.elem name presentYaml)) parkedAlertFiles;

  alertRuleFiles = builtins.map (file: "${alertRulesDir}/${file}") alertFiles;
in
{
  assertions = [
    {
      assertion = missingParked == [ ];
      message =
        "alerting.nix: parkedAlertFiles names a file that does not exist in "
        + "modules/monitoring/alerts: ${builtins.concatStringsSep ", " missingParked}. "
        + "A typo here silently parks nothing, leaving the rules live.";
    }
  ];

  # System-wide alerting configuration
  # Alert rules are auto-discovered from modules/monitoring/alerts/*.yaml
  # To add new alerts, just create a .yaml file in that directory.
  # To temporarily disable one, add it to parkedAlertFiles above (see the note there).
  services.prometheus.ruleFiles = alertRuleFiles;
}
