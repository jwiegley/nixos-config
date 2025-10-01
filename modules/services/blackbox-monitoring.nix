{ config, lib, pkgs, ... }:

let
  # Define host groups for better organization and configuration
  hostGroups = {
    # Local infrastructure hosts
    local = [
      "192.168.1.1"      # Router/Gateway
      "192.168.1.2"      # Vulcan
      "192.168.1.4"      # Hera
    ];

    # DNS servers
    dns = [
      "8.8.8.8"          # Google DNS Primary
      "8.8.4.4"          # Google DNS Secondary
      "1.1.1.1"          # Cloudflare DNS Primary
      "1.0.0.1"          # Cloudflare DNS Secondary
      "208.67.222.222"   # OpenDNS
    ];

    # Internet backbone/CDN
    backbone = [
      "google.com"
      "cloudflare.com"
      "amazon.com"
      "github.com"
    ];

    # Custom remote hosts (add your specific hosts here)
    remote = [
      # Add your remote hosts here
      # "example.com"
      # "remote-server.company.com"
    ];
  };

  # Flatten all hosts into a single list
  allHosts = lib.flatten (lib.attrValues hostGroups);

  # Create a blackbox configuration with multiple probe modules
  blackboxConfig = pkgs.writeText "blackbox.yml" ''
    modules:
      icmp_ping:
        prober: icmp
        timeout: 5s
        icmp:
          preferred_ip_protocol: "ip4"
          source_ip_address: ""
          payload_size: 56
          dont_fragment: false

      icmp_ping_ipv6:
        prober: icmp
        timeout: 5s
        icmp:
          preferred_ip_protocol: "ip6"
          payload_size: 56

      http_2xx:
        prober: http
        timeout: 5s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: []
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: true
          fail_if_ssl: false

      https_2xx:
        prober: http
        timeout: 5s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: []
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: true
          fail_if_ssl: false
          tls_config:
            insecure_skip_verify: false

      https_2xx_local:
        prober: http
        timeout: 5s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: []
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: true
          fail_if_ssl: false
          tls_config:
            insecure_skip_verify: false
            ca_file: /etc/ssl/certs/step-ca/root_ca.crt

      dns_query:
        prober: dns
        timeout: 5s
        dns:
          query_name: "google.com"
          query_type: "A"
          valid_rcodes:
            - NOERROR
          validate_answer_rrs:
            fail_if_matches_regexp: []
            fail_if_not_matches_regexp: []
          validate_authority_rrs:
            fail_if_matches_regexp: []
            fail_if_not_matches_regexp: []
          validate_additional_rrs:
            fail_if_matches_regexp: []
            fail_if_not_matches_regexp: []

      tcp_connect:
        prober: tcp
        timeout: 5s
        tcp:
          preferred_ip_protocol: "ip4"
  '';
in
{
  # Export host groups for use in other modules (like prometheus scrape configs)
  # This allows other modules to reference the defined hosts
  options.services.blackbox-monitoring = {
    hostGroups = lib.mkOption {
      type = lib.types.attrs;
      default = hostGroups;
      description = "Host groups for blackbox monitoring";
    };

    allHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = allHosts;
      description = "All hosts for blackbox monitoring";
    };
  };

  config = {
    # Enable blackbox exporter service
    services.prometheus.exporters.blackbox = {
      enable = true;
      port = 9115;
      configFile = blackboxConfig;

      # Open firewall port for scraping (only on localhost interface)
      openFirewall = false;  # We'll handle this manually for localhost only
    };

    # Configure firewall to allow blackbox exporter access only from localhost
    networking.firewall = {
      interfaces."lo" = {
        allowedTCPPorts = [ 9115 ];
      };
    };

    # Service to copy step-ca root certificate to accessible location
    systemd.services.setup-blackbox-ca = {
      description = "Copy step-ca root certificate for blackbox exporter";
      wantedBy = [ "multi-user.target" ];
      before = [ "prometheus-blackbox-exporter.service" ];
      after = [ "step-ca.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Copy root CA certificate to /etc/ssl/certs where it's accessible
        if [ -f /var/lib/step-ca/certs/root_ca.crt ]; then
          ${pkgs.coreutils}/bin/mkdir -p /etc/ssl/certs/step-ca
          ${pkgs.coreutils}/bin/cp /var/lib/step-ca/certs/root_ca.crt /etc/ssl/certs/step-ca/root_ca.crt
          ${pkgs.coreutils}/bin/chmod 644 /etc/ssl/certs/step-ca/root_ca.crt
          echo "Copied step-ca root certificate to /etc/ssl/certs/step-ca/ for blackbox exporter"
        fi
      '';
    };

    # Ensure blackbox exporter runs with appropriate capabilities for ICMP
    systemd.services.prometheus-blackbox-exporter = {
      wants = [ "network-online.target" "setup-blackbox-ca.service" ];
      after = [ "network-online.target" "setup-blackbox-ca.service" ];
      startLimitIntervalSec = 0;

      serviceConfig = {
        # Required for ICMP probes
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;

        # Allow reading the step-ca root certificate from /etc/ssl/certs
        # (Note: /etc is already readable, but being explicit doesn't hurt)
        BindReadOnlyPaths = [ "/etc/ssl/certs/step-ca/root_ca.crt" ];

        # Restart configuration
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Helper scripts for managing blackbox monitoring
    environment.systemPackages = with pkgs; [
      (writeShellScriptBin "check-blackbox" ''
        echo "=== Blackbox Exporter Status ==="
        systemctl is-active prometheus-blackbox-exporter && echo "Service: Active" || echo "Service: Inactive"

        echo ""
        echo "=== Blackbox Configuration Test ==="
        if ${pkgs.curl}/bin/curl -s http://localhost:9115/config >/dev/null 2>&1; then
          echo "Configuration endpoint is responding"
          echo "Available modules:"
          ${pkgs.curl}/bin/curl -s http://localhost:9115/config | \
            ${pkgs.gawk}/bin/awk '/^modules:/{next} /^[[:space:]]{4}[a-zA-Z_][a-zA-Z0-9_]*:$/{gsub(/^[[:space:]]*|:$/, "", $0); print "  " $0}'
        else
          echo "Configuration endpoint not responding"
        fi

        echo ""
        echo "=== Sample ICMP Probe Test ==="
        echo "Testing ping to 8.8.8.8..."
        timeout 10 ${pkgs.curl}/bin/curl -s \
          'http://localhost:9115/probe?module=icmp_ping&target=8.8.8.8' | \
          grep -E '(probe_success|probe_duration_seconds)' || echo "Probe failed or timed out"

        echo ""
        echo "=== Available Probe Modules ==="
        ${pkgs.curl}/bin/curl -s http://localhost:9115/config | \
          ${pkgs.gnugrep}/bin/grep -A1 -E '^\s+[a-zA-Z_]+:$' | \
          ${pkgs.gnugrep}/bin/grep -E '(prober:|^\s+[a-zA-Z_]+:$)' | \
          ${pkgs.gawk}/bin/awk '
            /^[[:space:]]*[a-zA-Z_]+:$/ {
              gsub(/[[:space:]]*:$/, "", $1);
              module = $1;
            }
            /prober:/ {
              gsub(/[[:space:]]*prober:[[:space:]]*/, "", $0);
              print "  " module ": " $0;
            }'
      '')

      (writeShellScriptBin "test-blackbox-hosts" ''
        echo "=== Testing Blackbox Monitoring for All Configured Hosts ==="

        # Test a subset of hosts to avoid overwhelming output
        TEST_HOSTS=(
          "8.8.8.8"
          "1.1.1.1"
          "google.com"
          "github.com"
        )

        for host in "''${TEST_HOSTS[@]}"; do
          echo ""
          echo "Testing: $host"
          echo -n "  ICMP: "

          # Test ICMP probe with timeout
          if timeout 5 ${pkgs.curl}/bin/curl -s \
            "http://localhost:9115/probe?module=icmp_ping&target=$host" | \
            grep -q 'probe_success 1'; then
            echo "✓ Success"
          else
            echo "✗ Failed"
          fi
        done

        echo ""
        echo "=== Host Group Summary ==="
        echo "Local hosts: ${toString (lib.length hostGroups.local)}"
        echo "DNS servers: ${toString (lib.length hostGroups.dns)}"
        echo "Backbone hosts: ${toString (lib.length hostGroups.backbone)}"
        echo "Remote hosts: ${toString (lib.length hostGroups.remote)}"
        echo "Total hosts: ${toString (lib.length allHosts)}"
      '')

      (writeShellScriptBin "blackbox-probe" ''
        # Usage: blackbox-probe <module> <target>
        # Example: blackbox-probe icmp_ping 8.8.8.8

        if [ $# -ne 2 ]; then
          echo "Usage: $0 <module> <target>"
          echo ""
          echo "Available modules:"
          ${pkgs.curl}/bin/curl -s http://localhost:9115/config | \
            ${pkgs.gawk}/bin/awk '/^modules:/{next} /^[[:space:]]{4}[a-zA-Z_][a-zA-Z0-9_]*:$/{gsub(/^[[:space:]]*|:$/, "", $0); print "  " $0}'
          exit 1
        fi

        MODULE="$1"
        TARGET="$2"

        echo "Probing $TARGET with module $MODULE..."
        ${pkgs.curl}/bin/curl -s \
          "http://localhost:9115/probe?module=$MODULE&target=$TARGET" | \
          grep -E '(probe_success|probe_duration_seconds|probe_)'
      '')
    ];

    # Documentation
    environment.etc."blackbox-monitoring/README.md" = {
      text = ''
        # Blackbox Monitoring Configuration (Complementing Smokeping)

        ## Overview
        This module configures Prometheus blackbox_exporter for network monitoring,
        working alongside existing Smokeping for comprehensive monitoring coverage.
        Blackbox provides real-time Prometheus metrics while Smokeping provides
        traditional latency trending and historical analysis.

        ## Integration with Smokeping
        - **Blackbox**: Real-time metrics, alerting, Grafana integration
        - **Smokeping**: Historical trends, traditional RRD-based visualization
        - **Complementary**: Both systems monitor similar hosts for comprehensive coverage

        ## Host Groups
        Hosts are organized into logical groups:
        - **local**: Local network infrastructure (${toString (lib.length hostGroups.local)} hosts)
        - **dns**: Public DNS servers (${toString (lib.length hostGroups.dns)} hosts)
        - **backbone**: Major internet services (${toString (lib.length hostGroups.backbone)} hosts)
        - **remote**: Custom remote hosts (${toString (lib.length hostGroups.remote)} hosts)

        Total monitored hosts: ${toString (lib.length allHosts)}

        ## Available Probe Modules
        - **icmp_ping**: IPv4 ICMP echo requests (standard ping)
        - **icmp_ping_ipv6**: IPv6 ICMP echo requests
        - **http_2xx**: HTTP endpoint checks
        - **https_2xx**: HTTPS endpoint checks with SSL validation
        - **dns_query**: DNS resolution checks
        - **tcp_connect**: TCP port connectivity checks

        ## Useful Commands
        - `check-blackbox`: Check blackbox exporter status and configuration
        - `test-blackbox-hosts`: Test monitoring for sample hosts
        - `blackbox-probe <module> <target>`: Manually test a specific probe

        ## Configuration
        - Service endpoint: http://localhost:9115
        - Configuration file: Generated from Nix configuration
        - Prometheus scrape targets: Configured in prometheus-monitoring.nix

        ## Adding Custom Hosts
        Edit the `hostGroups` in `/etc/nixos/modules/services/blackbox-monitoring.nix`
        and rebuild the system:
        ```bash
        sudo nixos-rebuild switch
        ```

        ## Security Notes
        - Blackbox exporter runs with CAP_NET_RAW for ICMP probes
        - Only accessible from localhost (127.0.0.1:9115)
        - Firewall configured to block external access
      '';
      mode = "0644";
    };

    # Expose configuration for other modules to use
    services.blackbox-monitoring = {
      inherit hostGroups allHosts;
    };
  };
}
