{ config, lib, pkgs, ... }:

let
  # Alert rules directory
  alertRulesDir = ../../monitoring/alerts;

  # Load all alert rules from YAML files
  alertRuleFiles = builtins.map (file: "${alertRulesDir}/${file}") [
    "system.yaml"
    "systemd.yaml"
    "database.yaml"
    "storage.yaml"
    "certificates.yaml"
    "network.yaml"
    "nextcloud.yaml"
  ];
in
{
  # Utility scripts for managing monitoring stack
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "reload-prometheus" ''
      echo "Reloading Prometheus configuration..."
      ${pkgs.systemd}/bin/systemctl reload prometheus
      echo "Prometheus configuration reloaded"
    '')

    (writeShellScriptBin "validate-alerts" ''
      echo "Validating Prometheus alert rules..."
      for file in ${toString alertRuleFiles}; do
        echo "Checking $file..."
        ${pkgs.prometheus}/bin/promtool check rules "$file" || exit 1
      done
      echo "All alert rules are valid"
    '')

    # Note: collect-restic-metrics is now provided by restic-metrics.nix
    # to avoid code duplication between CLI tool and systemd service
  ];
}
