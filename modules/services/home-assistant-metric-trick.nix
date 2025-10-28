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
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Ensure this service stops AFTER home-assistant stops
      requiredBy = [ "home-assistant.service" ];

      path = with pkgs; [ iproute2 coreutils ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        echo "Swapping metrics: WiFi to 100 (primary), Ethernet to 600 (secondary)"

        # Replace default routes with swapped metrics (replace updates or adds)
        ip route replace default via ${wifiGateway} dev ${wifiInterface} metric 100 src ${wifiIP}
        ip route replace default via ${ethernetGateway} dev ${ethernetInterface} metric 600 src ${ethernetIP}

        echo "Metrics swapped. Waiting for Home Assistant to start and bind..."
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
