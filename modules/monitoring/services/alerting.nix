{ config, lib, pkgs, ... }:

let
  # Alert rules directory
  alertRulesDir = ../alerts;

  # Auto-discover all .yaml alert files in the alerts directory
  alertFiles = builtins.filter
    (name: lib.hasSuffix ".yaml" name)
    (builtins.attrNames (builtins.readDir alertRulesDir));

  alertRuleFiles = builtins.map (file: "${alertRulesDir}/${file}") alertFiles;
in
{
  # System-wide alerting configuration
  # Alert rules are auto-discovered from modules/monitoring/alerts/*.yaml
  # To add new alerts, just create a .yaml file in that directory
  services.prometheus.ruleFiles = alertRuleFiles;
}
