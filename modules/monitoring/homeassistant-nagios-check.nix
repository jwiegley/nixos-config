{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Nagios check script
  checkScript = pkgs.writeScriptBin "check_homeassistant_integrations" ''
    #!${pkgs.bash}/bin/bash
    ${builtins.readFile ./check_homeassistant_integrations.sh}
  '';

  # Wrapper script that reads token from SOPS secret
  checkScriptWithToken = pkgs.writeScriptBin "check_homeassistant_integrations_wrapper" ''
    #!${pkgs.bash}/bin/bash

    # Ensure curl and jq are in PATH
    export PATH="${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:$PATH"

    # Read token from SOPS secret
    if [ -f "${config.sops.secrets."monitoring/home-assistant-token".path}" ]; then
      TOKEN=$(cat ${config.sops.secrets."monitoring/home-assistant-token".path})
      exec ${checkScript}/bin/check_homeassistant_integrations -t "$TOKEN" "$@"
    else
      echo "UNKNOWN - Access token not found in SOPS secrets"
      exit 3
    fi
  '';
in

{
  # SOPS secret for Home Assistant monitoring token
  # Note: Requires 'nagios' user to exist (created by services.nagios.enable)
  sops.secrets."monitoring/home-assistant-token" = {
    owner = "nagios";
    group = "nagios";
    mode = "0400";
  };

  # Install dependencies
  environment.systemPackages = with pkgs; [
    curl
    jq
    checkScript
    checkScriptWithToken
  ];

  # Example systemd timer for periodic checks (optional - can be used without Nagios)
  systemd.services.homeassistant-health-check = {
    description = "Home Assistant Integration Health Check";
    after = [
      "home-assistant.service"
      "sops-nix.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${checkScriptWithToken}/bin/check_homeassistant_integrations_wrapper -H 127.0.0.1:8123 -I -i august,nest,ring,enphase_envoy,flume,miele,lg_thinq,cast,withings,webostv,homekit,nws";
      User = "nagios";
      Group = "nagios";
    };
  };

  systemd.timers.homeassistant-health-check = {
    description = "Timer for Home Assistant Integration Health Check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };
}
