{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # ATD (at daemon) - Job Scheduling Service
  # ============================================================================

  # Enable the at daemon for scheduled job execution
  services.atd = {
    enable = true;
    # Keep restrictive permissions - only root and atd group can submit jobs
    allowEveryone = false;
  };

  # Service hardening and reliability
  systemd.services.atd = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startLimitIntervalSec = 0;
    startLimitBurst = 0;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };
}
