{ config, lib, pkgs, ... }:

let
  chainwebExporterDir = "/etc/nixos/chainweb-node-exporter";

  # Python environment with required packages
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    prometheus-client
    requests
    urllib3
  ]);
in
{
  # Systemd service for chainweb-node-exporter
  systemd.services.chainweb-node-exporter = {
    description = "Kadena Chainweb Node Exporter";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "johnw";
      Group = "johnw";
      WorkingDirectory = chainwebExporterDir;

      # Run the Python script directly with the Nix-provided Python environment
      ExecStart = "${pythonEnv}/bin/python3 ${chainwebExporterDir}/kadena_exporter.py --api-url https://api.chainweb.com/chainweb/0.0/mainnet01/cut --port 9101";

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

  # Open firewall port for the exporter (localhost only for now)
  networking.firewall.interfaces."lo" = {
    allowedTCPPorts = [ 9101 ];
  };

  # Helper script to check exporter health
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "check-chainweb-exporter" ''
      echo "=== Chainweb Exporter Status ==="
      systemctl status chainweb-node-exporter --no-pager | head -10
      echo ""
      echo "=== Current Metrics ==="
      curl -s localhost:9101/metrics | grep -E '^kadena_|^# HELP|^# TYPE' || echo "Failed to fetch metrics"
      echo ""
      echo "=== Recent Logs ==="
      journalctl -u chainweb-node-exporter -n 10 --no-pager
    '')
  ];
}
