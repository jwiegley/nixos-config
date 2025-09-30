{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.chainweb-exporters;

  chainwebExporterDir = "/etc/nixos/chainweb-node-exporter";

  # Python environment with required packages
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    prometheus-client
    requests
    urllib3
  ]);

  # Helper function to create a systemd service for each node
  mkExporterService = name: nodeCfg: {
    name = "chainweb-node-exporter-${name}";
    value = {
      description = "Kadena Chainweb Node Exporter for ${name}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "johnw";
        Group = "johnw";
        WorkingDirectory = chainwebExporterDir;

        # Run the Python script directly with the Nix-provided Python environment
        ExecStart = "${pythonEnv}/bin/python3 ${chainwebExporterDir}/kadena_exporter.py"
          + " --api-url ${nodeCfg.apiUrl}"
          + " --port ${toString nodeCfg.port}"
          + optionalString (nodeCfg.scrapeInterval != null) " --scrape-interval ${toString nodeCfg.scrapeInterval}"
          + optionalString (nodeCfg.timeout != null) " --timeout ${toString nodeCfg.timeout}";

        # Restart configuration
        Restart = "always";
        RestartSec = "10s";
        StartLimitIntervalSec = 0;

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ ];

        # Network access is required for API calls and serving metrics
        PrivateNetwork = false;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];

        # Logging
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };

  # Extract all configured ports
  exporterPorts = attrValues (mapAttrs (name: nodeCfg: nodeCfg.port) cfg.nodes);
in
{
  options.services.chainweb-exporters = {
    enable = mkEnableOption "Kadena Chainweb Node Exporters";

    nodes = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          apiUrl = mkOption {
            type = types.str;
            description = "API URL for the chainweb node";
            example = "https://api.chainweb.com/chainweb/0.0/mainnet01/cut";
          };

          port = mkOption {
            type = types.port;
            description = "Port to expose metrics on";
            example = 9101;
          };

          scrapeInterval = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Interval between API calls in seconds (defaults to 15)";
          };

          timeout = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "API request timeout in seconds (defaults to 1)";
          };
        };
      });
      default = {};
      description = "Configuration for chainweb node exporters";
      example = literalExpression ''
        {
          mainnet01 = {
            apiUrl = "https://api.chainweb.com/chainweb/0.0/mainnet01/cut";
            port = 9101;
          };
          mainnet02 = {
            apiUrl = "https://api.chainweb.com/chainweb/0.0/mainnet02/cut";
            port = 9102;
          };
        }
      '';
    };
  };

  config = mkIf (cfg.enable && cfg.nodes != {}) {
    # Create a systemd service for each configured node
    systemd.services = listToAttrs (mapAttrsToList mkExporterService cfg.nodes);

    # Open firewall ports for all exporters (localhost only for now)
    networking.firewall.interfaces."lo" = {
      allowedTCPPorts = exporterPorts;
    };

    # Helper script to check all exporters
    environment.systemPackages = with pkgs; [
      (writeShellScriptBin "check-chainweb-exporters" ''
        echo "=== Chainweb Exporters Status ==="
        echo ""

        # Check each exporter service
        ${concatStringsSep "\n" (mapAttrsToList (name: nodeCfg: ''
          echo "--- ${name} (port ${toString nodeCfg.port}) ---"
          systemctl status chainweb-node-exporter-${name} --no-pager | head -5
          echo ""
          echo "Metrics:"
          curl -s localhost:${toString nodeCfg.port}/metrics | grep -E '^kadena_|^# HELP|^# TYPE' | head -10 || echo "Failed to fetch metrics"
          echo ""
        '') cfg.nodes)}

        echo "=== Recent Logs (all exporters) ==="
        ${concatStringsSep "\n" (mapAttrsToList (name: _: ''
          echo "--- ${name} ---"
          journalctl -u chainweb-node-exporter-${name} -n 5 --no-pager
          echo ""
        '') cfg.nodes)}
      '')
    ];
  };
}