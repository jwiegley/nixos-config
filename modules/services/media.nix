{ config, lib, pkgs, ... }:

{
  services = {
    jellyfin = {
      enable = true;
      dataDir = "/var/lib/jellyfin";
      user = "johnw";
      openFirewall = false;
    };
  };

  # Configure Jellyfin to trust nginx as a known proxy
  systemd.services.jellyfin = {
    # Set umask to allow group-read permissions on new files
    # This ensures new log files are created with 640 instead of 600
    # so promtail (in jellyfin group) can read them
    # Use mkForce to override the default 0077 umask from jellyfin module
    serviceConfig.UMask = lib.mkForce "0027";

    preStart = ''
    # Ensure config directory exists
    mkdir -p ${config.services.jellyfin.configDir}

    # Ensure jellyfin data directory is traversable by group (for promtail to reach log/)
    chmod 750 /var/lib/jellyfin

    # Ensure log directory has group read permissions for promtail
    mkdir -p /var/lib/jellyfin/log
    chmod 750 /var/lib/jellyfin/log
    find /var/lib/jellyfin/log -type f -name "*.log" -exec chmod 640 {} \;

    # Create or update network.xml to add localhost and server IP as known proxies
    NETWORK_XML="${config.services.jellyfin.configDir}/network.xml"

    if [ ! -f "$NETWORK_XML" ]; then
      # Create new network.xml with minimal configuration
      cat > "$NETWORK_XML" << 'EOF'
    <?xml version="1.0" encoding="utf-8"?>
    <NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <KnownProxies>
        <string>127.0.0.1</string>
        <string>192.168.1.2</string>
      </KnownProxies>
    </NetworkConfiguration>
    EOF
    else
      # Update existing network.xml using xmlstarlet
      # Ensure KnownProxies element exists
      if ! ${pkgs.xmlstarlet}/bin/xmlstarlet sel -t -v "//KnownProxies" "$NETWORK_XML" &>/dev/null; then
        # Create KnownProxies element
        ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
          -s "//NetworkConfiguration" -t elem -n "KnownProxies" \
          "$NETWORK_XML"
      fi

      # Add 127.0.0.1 if not present
      if ! ${pkgs.xmlstarlet}/bin/xmlstarlet sel -t -v "//KnownProxies/string[text()='127.0.0.1']" "$NETWORK_XML" &>/dev/null; then
        ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
          -s "//KnownProxies" -t elem -n "string" -v "127.0.0.1" \
          "$NETWORK_XML"
      fi

      # Add 192.168.1.2 if not present
      if ! ${pkgs.xmlstarlet}/bin/xmlstarlet sel -t -v "//KnownProxies/string[text()='192.168.1.2']" "$NETWORK_XML" &>/dev/null; then
        ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
          -s "//KnownProxies" -t elem -n "string" -v "192.168.1.2" \
          "$NETWORK_XML"
      fi
    fi
    '';
  };

  services.nginx.virtualHosts."jellyfin.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/jellyfin.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/jellyfin.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8096/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Protocol $scheme;
        proxy_set_header X-Forwarded-Host $http_host;

        # Disable buffering when the nginx proxy gets very resource heavy upon
        # streaming
        proxy_buffering off;
      '';
    };
  };

  networking.firewall.allowedTCPPorts =
    lib.mkIf config.services.jellyfin.enable [ 8096 ];
}
