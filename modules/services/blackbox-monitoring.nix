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
      startLimitBurst = 0;

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
        # Blackbox Monitoring Configuration

        ## Overview
        This module configures Prometheus blackbox_exporter for network monitoring.
        Blackbox provides real-time Prometheus metrics for comprehensive monitoring coverage.

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

    # Prometheus scrape configurations for blackbox exporter
    services.prometheus.scrapeConfigs = lib.optionals config.services.prometheus.exporters.blackbox.enable [
      # ICMP monitoring for all configured hosts
      {
        job_name = "blackbox_icmp";
        metrics_path = "/probe";
        params = {
          module = [ "icmp_ping" ];
        };
        static_configs = [{
          targets = [
            "vulcan.lan"                        # 192.168.1.2
            "hera.lan"                          # 192.168.1.4
            # "clio.lan"                          # 192.168.1.5

            # "adt-home-security.lan"             # 192.168.3.118
            "asus-bq16-pro-ap.lan"              # 192.168.3.2
            "asus-bq16-pro-node.lan"            # 192.168.3.3
            "asus-rt-ax88u.lan"                 # 192.168.3.8
            # "august-lock-front-door.lan"        # 192.168.3.12
            # "august-lock-garage-door.lan"       # 192.168.3.14
            # "august-lock-side-door.lan"         # 192.168.3.173
            # "b-hyve-sprinkler.lan"              # 192.168.3.89
            # "dreamebot-vacuum.lan"              # 192.168.3.195
            # "enphase-solar-inverter.lan"        # 192.168.3.26
            # "flume-water-meter.lan"             # 192.168.3.183
            "google-home-hub.lan"               # 192.168.3.106
            "hera-wifi.lan"                     # 192.168.3.6
            # "hubspace-porch-light.lan"          # 192.168.3.178
            "miele-dishwasher.lan"              # 192.168.3.98
            "myq-garage-door.lan"               # 192.168.3.99
            # "nest-downstairs.lan"               # 192.168.3.57
            # "nest-family-room.lan"              # 192.168.3.83
            # "nest-upstairs.lan"                 # 192.168.3.161
            "pentair-intellicenter.lan"         # 192.168.3.115
            # "pentair-intelliflo.lan"            # 192.168.3.23
            # "ring-chime-kitchen.lan"            # 192.168.3.163
            # "ring-chime-office.lan"             # 192.168.3.88
            # "ring-doorbell.lan"                 # 192.168.3.185
            # "tesla-wall-connector.lan"          # 192.168.3.119
            # "traeger-grill.lan"                 # 192.168.3.196

            "athena.lan"                        # 192.168.20.2

            "TL-WPA8630.lan"                    # 192.168.30.49

            "9.9.9.9"
            "149.112.112.112"
            "1.1.1.1"
            "1.0.0.1"
            "208.67.222.222"
            "208.67.220.220"

            "google.com"
            "cloudflare.com"
            # "amazon.com"
            # "github.com"

            "web.mit.edu"
            "www.berkeley.edu"
            "ucsd.edu"
            "twin-cities.umn.edu"
            "osuosl.org"
          ];
        }];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
          }
          # Add host group labels based on target
          {
            source_labels = [ "__param_target" ];
            target_label = "host_group";
            regex = "(192\\.168\\..*)|(127\\.0\\.0\\.1)|(localhost)";
            replacement = "local";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "host_group";
            regex = "(8\\.8\\.[48]\\.[48])|(1\\.[01]\\.0\\.[01])|(208\\.67\\.222\\.222)";
            replacement = "dns";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "host_group";
            regex = ".+\\.(com|org|net|edu)";
            replacement = "backbone";
          }
        ];
        scrape_interval = "30s";
        scrape_timeout = "10s";
      }

      # HTTP monitoring for web services
      {
        job_name = "blackbox_http";
        metrics_path = "/probe";
        params = {
          module = [ "http_2xx" ];
        };
        static_configs = [{
          targets = [
            "http://google.com"
            # "http://github.com"
          ];
        }];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
          }
          {
            target_label = "probe_type";
            replacement = "http";
          }
        ];
        scrape_interval = "60s";
        scrape_timeout = "15s";
      }

      # HTTPS monitoring for public web services
      {
        job_name = "blackbox_https";
        metrics_path = "/probe";
        params = {
          module = [ "https_2xx" ];
        };
        static_configs = [{
          targets = [
            "https://google.com"
            # "https://github.com"
          ];
        }];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
          }
          {
            target_label = "probe_type";
            replacement = "https";
          }
        ];
        scrape_interval = "60s";
        scrape_timeout = "15s";
      }

      # HTTPS monitoring for local services with step-ca certificates
      {
        job_name = "blackbox_https_local";
        metrics_path = "/probe";
        params = {
          module = [ "https_2xx_local" ];
        };
        static_configs = [{
          targets = [
            "https://cockpit.vulcan.lan"
            "https://glance.vulcan.lan"
            "https://grafana.vulcan.lan"
            "https://jellyfin.vulcan.lan"
            "https://litellm.vulcan.lan"
            "https://postgres.vulcan.lan"
            # "https://prometheus.vulcan.lan"
            "https://ragflow.vulcan.lan"
            "https://silly-tavern.vulcan.lan"
            "https://wallabag.vulcan.lan"
            "https://dns.vulcan.lan"
            "https://paperless.vulcan.lan"
            "https://paperless-ai.vulcan.lan"
            "https://hass.vulcan.lan"
          ];
        }];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
          }
          {
            target_label = "probe_type";
            replacement = "https_local";
          }
        ];
        scrape_interval = "60s";
        scrape_timeout = "15s";
      }

      # DNS query monitoring
      {
        job_name = "blackbox_dns";
        metrics_path = "/probe";
        params = {
          module = [ "dns_query" ];
        };
        static_configs = [{
          targets = [
            "192.168.1.1"
            "192.168.1.2"
            "9.9.9.9"
            "149.112.112.112"
            "1.1.1.1"
            "1.0.0.1"
            "208.67.222.222"
            "208.67.220.220"
          ];
        }];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
          }
          {
            target_label = "probe_type";
            replacement = "dns";
          }
        ];
        scrape_interval = "60s";
        scrape_timeout = "10s";
      }
    ];
  };
}
