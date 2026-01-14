{
  config,
  lib,
  pkgs,
  ...
}:

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

  # Systemd service to prepare WiFi credentials in environment file format
  # Note: We do NOT use environment.etc here because it would overwrite the file
  # on every activation with an empty file. The service creates and manages the file.
  systemd.services.prepare-wifi-credentials = {
    description = "Prepare WiFi credentials for NetworkManager";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-pre.target" ];
    before = [
      "NetworkManager.service"
      "NetworkManager-ensure-profiles.service"
      "network-pre.target"
    ];
    after = [ "local-fs.target" ];

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
      # Ensure directory exists
      mkdir -p /etc/NetworkManager

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
            autoconnect-priority = 10; # Lower than Ethernet (default 0), but will auto-connect
          };
          wifi = {
            mode = "infrastructure";
            ssid = "$WIFI_SSID"; # Variable substituted from environment file
          };
          wifi-security = {
            auth-alg = "open";
            key-mgmt = "wpa-psk";
            psk = "$WIFI_PSK"; # Variable substituted from environment file
          };
          ipv4 = {
            method = "auto"; # DHCP
            never-default = true; # Never use WiFi for internet (Ethernet only)
          };
          ipv6 = {
            method = "auto";
            addr-gen-mode = "stable-privacy";
            never-default = true; # Never use WiFi for internet (Ethernet only)
          };
        };
      };
    };
  };
}
