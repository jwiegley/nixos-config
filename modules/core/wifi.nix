{ config, lib, pkgs, ... }:

{
  # Declare SOPS secrets for WiFi credentials
  sops.secrets."wifi/ssid" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.secrets."wifi/psk" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # Create environment files with proper variable names for NetworkManager
  # The SOPS secrets contain just the values, but NetworkManager's environmentFiles
  # expects VAR=value format, so we create wrapper files
  environment.etc."NetworkManager/wifi-credentials.env" = {
    mode = "0400";
    text = "";  # Will be populated by systemd service
  };

  # Systemd service to prepare WiFi credentials in environment file format
  systemd.services.prepare-wifi-credentials = {
    description = "Prepare WiFi credentials for NetworkManager";
    wantedBy = [ "multi-user.target" ];
    before = [ "NetworkManager.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Load credentials from SOPS secrets
      LoadCredential = [
        "ssid:${config.sops.secrets."wifi/ssid".path}"
        "psk:${config.sops.secrets."wifi/psk".path}"
      ];
    };

    script = ''
      # Create environment file with proper format for NetworkManager
      {
        echo "WIFI_SSID=$(cat "$CREDENTIALS_DIRECTORY/ssid")"
        echo "WIFI_PSK=$(cat "$CREDENTIALS_DIRECTORY/psk")"
      } > /etc/NetworkManager/wifi-credentials.env

      chmod 0400 /etc/NetworkManager/wifi-credentials.env
    '';
  };

  # Configure NetworkManager to automatically connect to WiFi
  networking.networkmanager = {
    ensureProfiles = {
      # Environment file containing WiFi credentials
      environmentFiles = [
        "/etc/NetworkManager/wifi-credentials.env"
      ];

      # Declarative WiFi profile
      profiles = {
        "home-wifi" = {
          connection = {
            id = "home-wifi";
            uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
            type = "wifi";
            autoconnect = true;
            autoconnect-priority = 10;  # Lower than Ethernet (default 0), but will auto-connect
          };
          wifi = {
            mode = "infrastructure";
            ssid = "$WIFI_SSID";  # Variable substituted from environment file
          };
          wifi-security = {
            auth-alg = "open";
            key-mgmt = "wpa-psk";
            psk = "$WIFI_PSK";  # Variable substituted from environment file
          };
          ipv4 = {
            method = "auto";  # DHCP
          };
          ipv6 = {
            method = "auto";
            addr-gen-mode = "stable-privacy";
          };
        };
      };
    };
  };
}
