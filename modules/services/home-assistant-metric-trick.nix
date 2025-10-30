{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.home-assistant;
  ethernetInterface = "end0";
  ethernetIP = "192.168.1.2";
  ethernetGateway = "192.168.1.1";
  wifiInterface = "wlp1s0f0";
  wifiIP = "192.168.3.16";
  wifiGateway = "192.168.3.1";

in {
  # Temporarily swap interface route metrics during Home Assistant startup
  # This tricks python-zeroconf into selecting WiFi interface (lowest metric)
  # After HA starts and binds sockets, metrics are restored for normal operation

  config = mkIf cfg.enable {

    systemd.services."home-assistant-metric-manager" = {
      description = "Temporarily adjust routing metrics for Home Assistant WiFi binding";
      before = [ "home-assistant.service" ];

      # Ensure network interfaces and NetworkManager are ready
      after = [ "network-online.target" "NetworkManager.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Ensure this service stops AFTER home-assistant stops
      requiredBy = [ "home-assistant.service" ];

      path = with pkgs; [ iproute2 coreutils ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Don't fail if routes already configured
        SuccessExitStatus = "0 2";
      };

      # Wait for both network interfaces to be fully ready
      preStart = ''
        # Wait for both network interfaces to be up
        for i in {1..30}; do
          if ip link show ${ethernetInterface} >/dev/null 2>&1 && ip link show ${wifiInterface} >/dev/null 2>&1; then
            # Check if both interfaces have IP addresses
            if ip addr show ${ethernetInterface} | grep -q "${ethernetIP}" && ip addr show ${wifiInterface} | grep -q "${wifiIP}"; then
              echo "Both network interfaces are ready with IP addresses"
              break
            fi
          fi
          echo "Waiting for network interfaces to be ready... ($i/30)"
          sleep 1
        done

        # Ensure default routes exist before trying to modify them
        if ! ip route show | grep -q "default"; then
          echo "Warning: No default routes exist yet, skipping metric adjustment"
          exit 0
        fi
      '';

      script = ''
        echo "Checking network state before metric adjustment..."

        # Check if routes already exist with correct metrics
        if ip route show | grep -q "default via ${wifiGateway} dev ${wifiInterface}.*metric 100" && \
           ip route show | grep -q "default via ${ethernetGateway} dev ${ethernetInterface}.*metric 600"; then
          echo "Routes already configured with desired metrics, skipping adjustment"
          exit 0
        fi

        echo "Adjusting metrics: WiFi to 100 (primary), Ethernet to 600 (secondary)"

        # Delete existing routes first, then add with new metrics
        ip route del default via ${wifiGateway} dev ${wifiInterface} 2>/dev/null || true
        ip route del default via ${ethernetGateway} dev ${ethernetInterface} 2>/dev/null || true

        # Add routes with new metrics
        ip route add default via ${wifiGateway} dev ${wifiInterface} metric 100 src ${wifiIP} || true
        ip route add default via ${ethernetGateway} dev ${ethernetInterface} metric 600 src ${ethernetIP} || true

        echo "Metrics adjusted successfully"
      '';

      preStop = ''
        echo "Restoring normal metrics: Ethernet to 100 (primary), WiFi to 600 (secondary)"

        # Replace routes back to normal metrics (replace updates or adds)
        ip route replace default via ${ethernetGateway} dev ${ethernetInterface} metric 100 src ${ethernetIP}
        ip route replace default via ${wifiGateway} dev ${wifiInterface} metric 600 src ${wifiIP}

        echo "Normal metrics restored."
      '';
    };

    # Ensure Home Assistant service waits for metric swap
    systemd.services.home-assistant = {
      after = [ "home-assistant-metric-manager.service" ];
      requires = [ "home-assistant-metric-manager.service" ];
    };

    # Separate service to restore metrics after delay
    systemd.services."home-assistant-metric-restorer" = {
      description = "Restore normal routing metrics after Home Assistant binds";
      after = [ "home-assistant.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };

      script = ''
        echo "Waiting 30 seconds for Home Assistant to fully start and bind..."
        sleep 30

        echo "Restoring normal metrics: Ethernet to 100 (primary), WiFi to 600 (secondary)"
        ${pkgs.iproute2}/bin/ip route replace default via ${ethernetGateway} dev ${ethernetInterface} metric 100 src ${ethernetIP}
        ${pkgs.iproute2}/bin/ip route replace default via ${wifiGateway} dev ${wifiInterface} metric 600 src ${wifiIP}

        echo "Normal metrics restored."
      '';
    };
  };
}
