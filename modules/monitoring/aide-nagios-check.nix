{ config, lib, pkgs, ... }:

# Nagios check for AIDE file integrity monitoring
# Monitors AIDE check results and alerts on changes or failures

{
  # Create AIDE Nagios check script
  environment.systemPackages = with pkgs; [
    (writeScriptBin "check_aide" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      # Nagios return codes
      OK=0
      WARNING=1
      CRITICAL=2
      UNKNOWN=3

      # Check if AIDE is installed
      if ! command -v ${pkgs.aide}/bin/aide &> /dev/null; then
        echo "UNKNOWN - AIDE not installed"
        exit $UNKNOWN
      fi

      # Check if database exists
      if [ ! -f /var/lib/aide/aide.db ]; then
        echo "CRITICAL - AIDE database not initialized"
        exit $CRITICAL
      fi

      # Run AIDE check and capture output
      CHECK_OUTPUT=$(${pkgs.aide}/bin/aide --check 2>&1 || true)
      AIDE_EXIT=$?

      # AIDE exit codes:
      # 0 = success (no changes)
      # 1 = new files detected
      # 2 = removed files detected
      # 3 = changed files detected
      # 4 = new + removed
      # 5 = new + changed
      # 6 = removed + changed
      # 7 = new + removed + changed
      # 14+ = errors

      case $AIDE_EXIT in
        0)
          echo "OK - AIDE check passed, no changes detected"
          exit $OK
          ;;
        1|2|3|4|5|6|7)
          # Extract summary
          ADDED=$(echo "$CHECK_OUTPUT" | grep "Added entries:" | awk '{print $3}')
          REMOVED=$(echo "$CHECK_OUTPUT" | grep "Removed entries:" | awk '{print $3}')
          CHANGED=$(echo "$CHECK_OUTPUT" | grep "Changed entries:" | awk '{print $3}')

          echo "CRITICAL - AIDE detected file changes: Added=$ADDED, Removed=$REMOVED, Changed=$CHANGED"
          exit $CRITICAL
          ;;
        *)
          echo "CRITICAL - AIDE check failed with exit code $AIDE_EXIT"
          exit $CRITICAL
          ;;
      esac
    '')
  ];

  # Note: To enable this check in Nagios, add the following to nagios.nix nagiosObjectDefs:
  #
  # define command {
  #   command_name    check_aide
  #   command_line    ${pkgs.writeScriptBin "check_aide" "..."}/bin/check_aide
  # }
  #
  # define service {
  #   use                     local-service
  #   host_name               vulcan
  #   service_description     AIDE File Integrity
  #   check_command           check_aide
  #   check_interval          60
  # }
}
