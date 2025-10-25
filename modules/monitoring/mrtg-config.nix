{ config, lib, pkgs, ... }:

{
  # Enable MRTG graphing for Nagios statistics
  services.mrtg-nagios = {
    enable = true;
    workDir = "/var/lib/mrtg-nagios";
    interval = 5;  # Run every 5 minutes
  };
}
