{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define host groups for better organization and configuration
  hostGroups = {
    # Local infrastructure hosts
    local = [
      "192.168.1.1" # Router/Gateway
      "192.168.1.2" # Vulcan
      "192.168.1.4" # Hera
    ];

    # DNS servers
    dns = [
      "8.8.8.8" # Google DNS Primary
      "8.8.4.4" # Google DNS Secondary
      "1.1.1.1" # Cloudflare DNS Primary
      "1.0.0.1" # Cloudflare DNS Secondary
      "208.67.222.222" # OpenDNS
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

      # Long-timeout variant for the sleepy Wi-Fi IoT fleet (host_group
      # iot/iot-noping). Battery devices park their radios in power-save and
      # answer only on beacon wakeups: ring-doorbell measured 0% real loss
      # yet 1.2s avg / 2.9s max RTT, and deeper sleeps blow the 5s icmp_ping
      # budget entirely — at 5s, probe_success under-reported that healthy
      # doorbell as 31% (observed 2026-06-12). 10s keeps probe_success
      # truthful for "is it on the network at all", which is all the iot
      # rules ask (BlackboxICMPIoTDeviceDown, for: 10m); the latency rules
      # already exclude these host_groups. Routed per-target by the
      # __param_module relabel in the blackbox_icmp job — same job, so every
      # series keeps job="blackbox_icmp" and no rule expr changes.
      icmp_ping_iot:
        prober: icmp
        timeout: 10s
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

      # Permissive variant of https_2xx_local for vhosts that are alive and
      # correctly TLS-terminated but answer an anonymous GET / with 401/403
      # (auth-gated apps like Nagios) or 404 (no handler bound at /, like the
      # Loki API vhost). For these, "auth-gated-but-listening" is the healthy
      # state — the strict module would flap them to probe_success=0 forever
      # and chronically fire HostUnreachable. The cert is still validated
      # against the step-ca root, so a TLS/cert failure still trips the probe.
      # Hermes API probe. Deliberately NOT https_2xx_or_auth: that module accepts
      # 404 and 200 for any path, so it would stay green if this vhost vanished
      # and another server answered, or if routing broke. This one asserts BOTH
      # the exact status Hermes gives an unauthenticated caller AND a string only
      # Hermes emits, so a green probe means "the hermes vhost is present, reached
      # the guest, and the guest's auth layer answered" -- not merely "something
      # replied". api_server.py returns {"error": {... "code": "invalid_api_key"}}.
      # Asserting this needs no credential, so no key enters the Nix store.
      hermes_api_401:
        prober: http
        timeout: 10s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: [401]
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: false
          fail_if_ssl: false
          fail_if_body_not_matches_regexp:
            - "invalid_api_key"
          tls_config:
            insecure_skip_verify: false
            ca_file: /etc/ssl/certs/step-ca/root_ca.crt
      https_2xx_or_auth:
        prober: http
        timeout: 5s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: [200, 301, 302, 303, 307, 308, 401, 403, 404]
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: true
          fail_if_ssl: false
          tls_config:
            insecure_skip_verify: false
            ca_file: /etc/ssl/certs/step-ca/root_ca.crt

      # Plain-HTTP liveness probe for localhost-only listeners that have no
      # GET-able root or whose intended verb is POST (e.g. the Node-RED
      # /alert HTTP-In endpoint, which 404s on GET but proves the listener is
      # up). Accepts 404/405 so "the socket answered HTTP" counts as success.
      http_alive:
        prober: http
        timeout: 5s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: [200, 301, 302, 303, 307, 308, 401, 403, 404, 405]
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: false
          fail_if_ssl: false

      # Public-edge probe for the cloudflared-tunnelled vhosts
      # (data.newartisans.com, calendar.newartisans.com). Unlike the *_local
      # modules these certs are PUBLIC (Google Trust Services), so this module
      # uses the system CA bundle (no step-ca ca_file override) and validates
      # the full public path: Cloudflare edge -> tunnel -> origin nginx. 404 is
      # accepted because calendar.newartisans.com answers an anonymous GET / with
      # 404 (no handler bound at /) — the 404 still proves the tunnel + origin are
      # alive, exactly the "auth-gated-but-listening" rationale of
      # https_2xx_or_auth. A genuine outage (tunnel down, origin down, cert
      # invalid) still trips probe_success=0. (coverage plan P2, web-extra)
      https_public:
        prober: http
        timeout: 10s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: [200, 301, 302, 303, 307, 308, 401, 403, 404]
          method: GET
          preferred_ip_protocol: "ip4"
          follow_redirects: true
          fail_if_ssl: false
          tls_config:
            insecure_skip_verify: false

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

      # Internal-zone resolution correctness: query the local Technitium
      # resolver for a known internal name and assert the answer carries the
      # expected A record. Catches NXDOMAIN, SERVFAIL, wrong/poisoned answers,
      # and a dead local resolver for *.vulcan.lan — none of which the external
      # dns_query module (google.com) can see. The answer-RR text blackbox
      # validates is the miekg/dns RR .String() form (tab-separated, same as
      # dig: "vulcan.lan.\t3600\tIN\tA\t192.168.1.2"); the regex is kept
      # whitespace-permissive so a TTL/format change can't silently break it.
      dns_internal:
        prober: dns
        timeout: 5s
        dns:
          query_name: "vulcan.lan"
          query_type: "A"
          valid_rcodes:
            - NOERROR
          validate_answer_rrs:
            fail_if_matches_regexp: []
            fail_if_not_matches_regexp:
              - ".*\\bIN\\b.*\\bA\\b.*192\\.168\\.1\\.2"
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
  # This allows other modules to reference the defined hosts.
  # NOTE (2026-07-27): nothing outside this file reads these two options, and
  # the scrapeConfigs below do NOT derive from hostGroups — they carry their own
  # hand-maintained target lists. hostGroups only feeds the host counts in the
  # shipped /etc/blackbox-monitoring/README.md, so those counts describe this
  # list rather than what is actually probed.
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
      openFirewall = false; # We'll handle this manually for localhost only
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
      wants = [
        "network-online.target"
        "setup-blackbox-ca.service"
      ];
      after = [
        "network-online.target"
        "setup-blackbox-ca.service"
      ];
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
        - **icmp_ping_iot**: IPv4 ICMP with a 10s timeout for the sleepy IoT
          fleet (power-save wakeups exceed the 5s budget); auto-selected for
          host_group iot/iot-noping/iot-quiet via relabeling
        - **icmp_ping_ipv6**: IPv6 ICMP echo requests
        - **http_2xx**: HTTP endpoint checks
        - **https_2xx**: HTTPS endpoint checks with SSL validation
        - **dns_query**: DNS resolution checks
        - **tcp_connect**: TCP port connectivity checks

        ## Useful Commands
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
    services.prometheus.scrapeConfigs =
      lib.optionals config.services.prometheus.exporters.blackbox.enable
        [
          # ICMP monitoring for all configured hosts
          {
            job_name = "blackbox_icmp";
            metrics_path = "/probe";
            params = {
              module = [ "icmp_ping" ];
            };
            static_configs = [
              # Always-on hosts: local infra (host/peers + network gear) plus
              # the public DNS / internet-backbone reachability checks. These
              # are expected to be up 24/7. HostUnreachable (critical) no longer
              # owns all of them: since 2026-07-07 it excludes host_group
              # backbone/dns, which are covered instead by the aggregate
              # WANDegraded / DNSResolversDown rules in network.yaml. Targets
              # that end up with no host_group (e.g. the Quad9 addresses, which
              # the "dns" relabel regex does not match) are still owned by it.
              # host_group is attached by the relabel_configs below.
              {
                targets = [
                  "vulcan.lan" # 192.168.1.2
                  "hera.lan" # 192.168.1.4
                  # "clio.lan"                          # 192.168.1.5

                  "asus-bq16-pro-ap.lan" # 192.168.3.2
                  "asus-bq16-pro-node.lan" # 192.168.3.3
                  "asus-rt-ax88u.lan" # 192.168.3.8
                  "hera-wifi.lan" # 192.168.3.6

                  "192.168.30.49" # TL-WPA8630 powerline (Neo, vlan04). Probed by IP:
                  # its DHCP-registered forward name TL-WPA8630.lan doesn't resolve
                  # (OPNsense registers only the PTR), so a name-based probe fails even
                  # when the device is up (2026-07-21). Durable fix = a DHCP reservation
                  # on OPNsense for the extender (MAC d8:47:32:cf:49:0a) so the lease/name
                  # stay put; the .30.49 lease is sticky for this always-on device.

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
              }
              # IoT devices (host_group="iot"). These are intentionally
              # "sleepy": locks, thermostats, doorbells/chimes, sprinkler,
              # vacuum, solar inverter, water meter, dishwasher, garage door,
              # smart-home hub, pool controller, etc. They routinely drop off
              # ICMP for long stretches (low-power radios, deep sleep), so they
              # are carried in their own group and EXCLUDED from the always-on
              # HostUnreachable critical. The warning-only BlackboxICMPIoTDevice
              # Down alert (network.yaml, for: 1h) covers them and mirrors the
              # existing Nagios IoT ping coverage (the cross-stack duplication
              # on this host is intentional). The explicit host_group label here
              # is authoritative — the relabel_configs "local/dns/backbone"
              # rules below are guarded so they never overwrite it.
              {
                targets = [
                  # "adt-home-security.lan"             # 192.168.3.118
                  "august-lock-front-door.lan" # 192.168.3.12
                  "august-lock-garage-door.lan" # 192.168.3.14
                  "august-lock-side-door.lan" # 192.168.3.173
                  "b-hyve-sprinkler.lan" # 192.168.3.89
                  "dreamebot-vacuum.lan" # 192.168.3.195
                  "enphase-solar-inverter.lan" # 192.168.3.26
                  "flume-water-meter.lan" # 192.168.3.183
                  "google-home-hub.lan" # 192.168.3.106
                  "192.168.3.154" # Ecowitt GW1200B moisture-hub (power-off group). Probed by
                  # IP, not GW1200B.lan: that DHCP-registered name lapses from DNS (observed
                  # 2026-07-21 → false PowerOffSensitiveGroupMultipleDown while the device was
                  # up). Durable fix is a Technitium DHCP reservation for MAC ac:a7:04:82:c9:0c;
                  # until then the IP is stable in practice (always-on device).
                  "hubspace-porch-light.lan" # 192.168.3.178
                  "miele-dishwasher.lan" # 192.168.3.98
                  "myq-garage-door.lan" # 192.168.3.99
                  "pentair-intellicenter.lan" # 192.168.3.115
                  "pentair-intelliflo.lan" # 192.168.3.23
                  "ring-chime-kitchen.lan" # 192.168.3.163
                  "tesla-wall-connector.lan" # 192.168.3.119
                ];
                labels = {
                  host_group = "iot";
                };
              }
              # ICMP-silent IoT devices (host_group="iot-noping"). These never
              # answer ICMP at all — 0% probe_success since probing began —
              # because they firewall ping outright and/or are battery
              # deep-sleepers that never surface for an echo request. They are
              # ALSO absent from Nagios's host list (verified against
              # status.dat), so nobody has ever successfully pinged them: they
              # were originally commented out for exactly this reason, not as
              # Nagios-only coverage. We keep probing them for visibility (so a
              # newly-reachable device shows up), but they are placed in this
              # separate group so that BlackboxICMPIoTDeviceDown (network.yaml)
              # deliberately EXCLUDES them — otherwise they would be chronic
              # never-clearing warnings, violating the no-chronic-firing
              # discipline. If one of these ever starts answering ICMP, move it
              # back into the "iot" group above so it gets warning coverage.
              # UPDATE 2026-07-27: that has now happened for the office chime —
              # ring-chime-office.lan answered ~99.6% of probes over the
              # preceding 30 days, so it no longer fits "never answers ICMP"
              # and, by the rule above, belongs in the "iot" group.
              # (nest-upstairs.lan answers ~2% of the time; the other two nests
              # are still flat 0%.)
              {
                targets = [
                  "nest-downstairs.lan" # 192.168.3.57
                  "nest-family-room.lan" # 192.168.3.83
                  "nest-upstairs.lan" # 192.168.3.161
                  "ring-chime-office.lan" # 192.168.3.88
                ];
                labels = {
                  host_group = "iot-noping";
                };
              }
              # Quiet-by-design IoT devices (host_group="iot-quiet"). Unlike
              # "iot-noping" (which never answers ICMP at all), these DO answer
              # when awake but are powered-off or in deep power-save for long,
              # routine stretches by design, so a missed ping is not an
              # incident:
              #   - traeger-grill  (~78% reachable; off for days between cooks)
              #   - ring-doorbell  (~92% reachable; long power-save windows;
              #     measured 0% real loss but multi-second wakeup RTT)
              # Re-measured over the 90 days to 2026-07-27 (with the 10s
              # icmp_ping_iot module in force): traeger-grill ~92%,
              # ring-doorbell ~99.9%. Both still go quiet by design, so the
              # exclusion rationale stands, but the percentages above are the
              # older, lower figures.
              # They are still probed for visibility (a genuine extended outage
              # remains visible on dashboards) but, exactly like iot-noping, are
              # EXCLUDED from every blackbox alert — both the warning-only
              # BlackboxICMPIoTDeviceDown (which selects host_group="iot") and
              # the always-on HostUnreachable critical. This honors the
              # no-chronic-firing discipline. If one of these stops sleeping and
              # should alert again, move it back into the "iot" group above.
              {
                targets = [
                  "ring-doorbell.lan" # 192.168.3.185
                  "traeger-grill.lan" # 192.168.3.196
                ];
                labels = {
                  host_group = "iot-quiet";
                };
              }
            ];
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
              # Add host group labels based on target. Each rule keys on BOTH
              # __param_target AND the existing host_group so it only fires when
              # host_group is still empty — this preserves the authoritative
              # static label (host_group="iot") set on the IoT static_config
              # above and never clobbers it. The first capture group matches the
              # target, the second requires host_group="" (the "<sep>" between
              # the two source labels is the default ";").
              #
              # "local" now also matches .lan hostnames (not just 192.168.* IPs):
              # every local probe uses a .lan name, so the old IP-only regex
              # never attached host_group="local" to any of them. The IP forms
              # are kept so group membership for any raw-IP local target is
              # unchanged.
              {
                source_labels = [
                  "__param_target"
                  "host_group"
                ];
                target_label = "host_group";
                regex = "((192\\.168\\..*)|(127\\.0\\.0\\.1)|(localhost)|(.+\\.lan));";
                replacement = "local";
              }
              {
                source_labels = [
                  "__param_target"
                  "host_group"
                ];
                target_label = "host_group";
                regex = "((8\\.8\\.[48]\\.[48])|(1\\.[01]\\.0\\.[01])|(208\\.67\\.222\\.222));";
                replacement = "dns";
              }
              {
                source_labels = [
                  "__param_target"
                  "host_group"
                ];
                target_label = "host_group";
                regex = "(.+\\.(com|org|net|edu));";
                replacement = "backbone";
              }
              # Route the sleepy IoT fleet to the long-timeout icmp_ping_iot
              # module (see blackbox.yml above). Safe to key on host_group:
              # all three groups carry it as an authoritative static label, so this
              # never depends on the defaulting rules above. Rewriting
              # __param_module overrides the job-level params.module for just
              # these targets while keeping job="blackbox_icmp" on every
              # series — BlackboxICMPIoTDeviceDown and the latency-rule
              # exclusions select on that label and must not churn.
              {
                source_labels = [ "host_group" ];
                target_label = "__param_module";
                regex = "iot|iot-noping|iot-quiet";
                replacement = "icmp_ping_iot";
              }
            ];
            scrape_interval = "30s";
            # 12s, not the 10s default: must exceed the icmp_ping_iot module
            # timeout (10s) or the probe loses its window — blackbox caps the
            # effective deadline at min(module timeout, scrape_timeout - 0.5s
            # offset). Plain icmp_ping targets are unaffected; their 5s module
            # timeout still bounds the probe.
            scrape_timeout = "12s";
          }

          # HTTP monitoring for web services
          {
            job_name = "blackbox_http";
            metrics_path = "/probe";
            params = {
              module = [ "http_2xx" ];
            };
            static_configs = [
              {
                targets = [
                  "http://google.com"
                  # "http://github.com"
                ];
              }
            ];
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

          # OpenClaw /health probe — independent of canary, drives
          # OpenClawHttpHealthDown alert + B-floor signal for self-heal.
          {
            job_name = "blackbox_openclaw";
            metrics_path = "/probe";
            params = {
              module = [ "https_2xx_local" ];
            };
            static_configs = [
              {
                targets = [ "https://openclaw.vulcan.lan/health" ];
                labels = {
                  service = "openclaw";
                  probe = "openclaw-health";
                };
              }
            ];
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
            ];
            scrape_interval = "30s";
            scrape_timeout = "10s";
          }

          # Memory Vault REST API health (unauthenticated GET /api/health → 200).
          {
            job_name = "blackbox_memory_vault";
            metrics_path = "/probe";
            params = {
              module = [ "https_2xx_local" ];
            };
            static_configs = [
              {
                targets = [ "https://memory.vulcan.lan/api/health" ];
                labels = {
                  service = "memory-vault";
                  probe = "memory-vault-health";
                };
              }
            ];
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
            ];
            scrape_interval = "30s";
            scrape_timeout = "10s";
          }

          # HTTPS monitoring for public web services
          {
            job_name = "blackbox_https";
            metrics_path = "/probe";
            params = {
              module = [ "https_2xx" ];
            };
            static_configs = [
              {
                targets = [
                  "https://google.com"
                  # "https://github.com"
                ];
              }
            ];
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

          # Public-edge HTTPS probes for the cloudflared-tunnelled vhosts.
          # These ride the FULL public path (Cloudflare edge -> tunnel ->
          # origin nginx) so a probe failure means the public surface is down,
          # not merely a LAN-internal hiccup. Both verified live before adding:
          # data -> 200, calendar -> 404 (handled by the https_public module's
          # 404 acceptance). The dedicated PublicEdgeDown alert in network.yaml
          # pages on probe_success==0 here; the generic HostUnreachable
          # (job=~"blackbox_.*") also backstops it. (coverage plan P2, web-extra)
          {
            job_name = "blackbox_https_public";
            metrics_path = "/probe";
            params = {
              module = [ "https_public" ];
            };
            static_configs = [
              {
                targets = [
                  "https://data.newartisans.com"
                  "https://calendar.newartisans.com"
                ];
                labels = {
                  probe = "public-edge";
                };
              }
            ];
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
                replacement = "https_public";
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
            static_configs = [
              {
                targets = [
                  "https://glance.vulcan.lan"
                  "https://cockpit.vulcan.lan"
                  "https://192.168.1.1"
                  "https://dns.vulcan.lan"
                  "https://postgres.vulcan.lan"
                  "https://hass.vulcan.lan"
                  "https://nodered.vulcan.lan"
                  "https://wallabag.vulcan.lan"
                  "https://jellyfin.vulcan.lan"
                  "https://prometheus.vulcan.lan"
                  "https://victoriametrics.vulcan.lan"
                  "https://grafana.vulcan.lan"
                  "https://glances.vulcan.lan"
                  "https://alertmanager.vulcan.lan"
                  "https://speedtest.vulcan.lan"
                  "https://mailarchiver.vulcan.lan"
                  "https://teable.vulcan.lan"
                  "https://budget.vulcan.lan"
                  "https://changes.vulcan.lan"
                  "https://aria.vulcan.lan"
                  "https://openproject.vulcan.lan"
                  # DISABLED 2026-07-31: shlink has an unpatched security advisory; re-enable only after upgrading.
                  # "https://shlink.vulcan.lan"
                  # "https://shlink-api.vulcan.lan/rest/health"
                  "https://chat.vulcan.lan"
                  "https://searxng.vulcan.lan"
                  "https://vane.vulcan.lan"
                  "https://speedtracker.vulcan.lan"
                  "https://trader.vulcan.lan"

                  # Previously-unprobed vhosts (coverage plan P1, web-blackbox).
                  # Each verified anonymous-GET 2xx/3xx through the blackbox
                  # https_2xx_local module (step-ca CA) before being added here,
                  # so each currently reports probe_success=1. Auth-gated (401)
                  # and no-root-handler (404) vhosts go to blackbox_https_auth
                  # below instead. notebook.vulcan.lan is a serverAlias of
                  # jupyter (covered) and is intentionally omitted.
                  "https://atd.vulcan.lan"
                  "https://gitea.vulcan.lan"
                  "https://immich.vulcan.lan"
                  "https://jupyter.vulcan.lan"
                  "https://kiwix.vulcan.lan"
                  "https://llama-swap.vulcan.lan"
                  "https://promtail.vulcan.lan"
                  "https://qdrant.vulcan.lan"
                  "https://radicale.vulcan.lan"
                  "https://rspamd.vulcan.lan"
                  "https://vdirsyncer.vulcan.lan"
                  "https://zimit.vulcan.lan"
                ];
              }
            ];
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

          # Auth-gated / no-root-handler local vhosts. These are alive and
          # correctly TLS-terminated but answer an anonymous GET / with 401
          # (Nagios requires basic auth) or 404 (the Loki API vhost has no
          # handler at /). The https_2xx_or_auth module treats those as healthy
          # while still validating the step-ca cert, so HostUnreachable (which
          # matches job=~"blackbox_.*") only fires on a genuine outage/TLS
          # failure rather than flapping on the auth challenge. (coverage plan
          # P1, web-blackbox)
          {
            job_name = "blackbox_https_auth";
            metrics_path = "/probe";
            params = {
              module = [ "https_2xx_or_auth" ];
            };
            static_configs = [
              {
                targets = [
                  "https://nagios.vulcan.lan"
                  "https://loki.vulcan.lan"
                ];
              }
            ];
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
                replacement = "https_auth";
              }
            ];
            scrape_interval = "60s";
            scrape_timeout = "15s";
          }

          # Direct liveness probe of the hera-side llama-swap / MLX model router
          # (hera.lan:8080). This is the terminal upstream behind the host LLM
          # gateway on 127.0.0.1:4000, and thus the terminal dependency of all
          # Hermes Discord chat. GET
          # /v1/models returns HTTP 200 UNAUTHENTICATED (verified live through the
          # exporter: owned_by=llama-swap, 30 models, ~1ms once warm), so the
          # strict http_2xx module suffices — no auth, no secrets. This is a
          # LIVENESS probe of the router; per-model load correctness is covered by
          # the hermes-e2e-chat-probe content check. NOTE this is the HERA
          # instance, distinct from the vulcan-side llama-swap.vulcan.lan already
          # in blackbox_https_local. host_group is intentionally NOT set so the
          # ICMP host_group-based rules in network.yaml never match it. The
          # MLXBackendDown alert in hermes.yaml owns this target (gated by
          # `and on() up{job="darwin-hera"}==1`); the generic HostUnreachable rule
          # (network.yaml, job=~"blackbox_.*") must exclude blackbox_hera_mlx so
          # a hera reboot does not double-fire an ungated critical — that
          # exclusion has since landed (HostUnreachable now carries
          # job!="blackbox_hera_mlx"; verified 2026-07-27).
          # (coverage plan deferred: mlx-hera-probe)
          {
            job_name = "blackbox_hera_mlx";
            metrics_path = "/probe";
            params = {
              module = [ "http_2xx" ];
            };
            static_configs = [
              {
                targets = [ "http://hera.lan:8080/v1/models" ];
                labels = {
                  service = "mlx-backend";
                  probe = "hera-mlx";
                };
              }
            ];
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
                replacement = "http_remote";
              }
            ];
            scrape_interval = "30s";
            scrape_timeout = "10s";
          }

          # hera :8443 — the endpoint the AGENTS' model actually lives behind.
          #
          # Added 2026-08-01 during a live outage that the existing blackbox_hera_mlx job
          # above could not see. hera runs three services and they are not interchangeable:
          #   :8000  oMLX            -- connection-refused at the time of writing
          #   :8080  older llama-swap -- UP, serving GLM-5.2 / Meta-Llama / bge-m3 / etc.
          #   :8443  llama-swap      -- serves Qwen3.6-27B-oQ4e-mtp, i.e. the model Hermes uses
          # blackbox_hera_mlx targets :8080, so probe_success stayed 1 while :8443 returned
          # 502 and hermes_e2e_chat_ok was 0. MLXBackendDown, whose whole purpose is "terminal
          # dependency of all Hermes chat", was structurally blind to a total outage of the
          # chat backend.
          #
          # Module is https_2xx_or_auth, chosen so this needs NO API KEY in the Nix store:
          # its valid_status_codes accept 401 but not 502. A healthy hera answers /v1/models
          # with 401 when unauthenticated (auth was enabled on it 2026-07-31); a broken
          # backend answers 502 before auth is ever evaluated. So an unauthenticated probe
          # distinguishes the two exactly, and the key stays in SOPS.
          #
          # Probing /v1/models rather than /health is deliberate: /health returned 200
          # throughout the outage, because it reports the proxy's own liveness, not the
          # backend's. Probing it would have reproduced the same blind spot in a new place.
          {
            job_name = "blackbox_hera_qwen";
            metrics_path = "/probe";
            params = {
              module = [ "https_2xx_or_auth" ];
            };
            static_configs = [
              {
                targets = [ "https://hera.lan:8443/v1/models" ];
                labels = {
                  service = "mlx-backend";
                  probe = "hera-qwen";
                };
              }
            ];
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
                replacement = "https_remote";
              }
            ];
            scrape_interval = "30s";
            scrape_timeout = "10s";
          }
          # Hermes API server, published to the LAN as https://hermes.vulcan.lan
          # (vhost in modules/services/hermes-microvm.nix). That proxy is the only
          # ingress to the agent from anywhere but vulcan itself, so it gets its own
          # probe rather than relying on the generic vhost sweep.
          #
          # Module is https_2xx_or_auth so no API key lands in the Nix store:
          # /v1/models answers 401 unauthenticated (Hermes enforces its own auth,
          # which the proxy passes through rather than injecting), while a dead guest
          # or broken bridge gives 502 before auth is evaluated. 401 is accepted, 502
          # is not, so an unauthenticated probe separates "up and authenticating"
          # from "down" exactly.
          #
          # Probing /v1/models rather than / is deliberate, and the dedicated
          # hermes_api_401 module is what makes it meaningful: that module
          # requires status 401 AND the "invalid_api_key" body Hermes emits.
          # Under the generic https_2xx_or_auth the assertion would be hollow,
          # since that module accepts 404 for any path -- a misrouted probe, or
          # a vhost fallthrough to another server, would both stay green.
          #
          # THE JOB NAME IS LOAD-BEARING. It must start with "blackbox_http" so alert
          # routing lands correctly: WebServiceDown selects job=~"blackbox_http.*"
          # (critical, for 1m) and HostUnreachable EXCLUDES that same pattern. A name
          # outside it -- this job was briefly "blackbox_hermes_api" -- inverts both:
          # WebServiceDown stops matching, and HostUnreachable starts claiming "Host
          # ... is unreachable" about an HTTP endpoint on a perfectly reachable host.
          # Third time this trap has been hit in this file (cf. the blackbox_hera_qwen
          # note, and the 2026-08-01 widening of HostUnreachable's exclusion).
          {
            job_name = "blackbox_https_hermes";
            metrics_path = "/probe";
            params = {
              module = [ "hermes_api_401" ];
            };
            static_configs = [
              {
                targets = [ "https://hermes.vulcan.lan/v1/models" ];
                labels = {
                  service = "hermes-agent";
                  probe = "hermes-api";
                };
              }
            ];
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
                replacement = "hermes_api";
              }
            ];
            scrape_interval = "60s";
            scrape_timeout = "15s"; # > the module's 10s, so the module timeout binds
          }

          # Node-RED /alert HTTP-In endpoint on 127.0.0.1:1880 — the listener
          # the Alertmanager iphone-notifier receiver POSTs critical pages to.
          # GET /alert returns 404 (it is a POST-only HTTP-In node), which the
          # http_alive module accepts: a 404 still proves the listener is up
          # and accepting connections, so a dead Node-RED (= no iPhone paging)
          # is caught. The ALERT for this target is owned by the
          # meta-monitoring workstream; this only adds the probe target.
          # (coverage plan P1 #6, web-blackbox)
          {
            job_name = "blackbox_iphone_relay";
            metrics_path = "/probe";
            params = {
              module = [ "http_alive" ];
            };
            static_configs = [
              {
                targets = [ "http://127.0.0.1:1880/alert" ];
                labels = {
                  service = "nodered-alert-relay";
                };
              }
            ];
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
                replacement = "http_local";
              }
            ];
            scrape_interval = "60s";
            scrape_timeout = "10s";
          }

          # DNS query monitoring
          {
            job_name = "blackbox_dns";
            metrics_path = "/probe";
            params = {
              module = [ "dns_query" ];
            };
            static_configs = [
              {
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
              }
            ];
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

          # Internal-zone DNS resolution correctness (probes the local
          # Technitium resolver at 127.0.0.1 for vulcan.lan -> expected A record)
          {
            job_name = "blackbox_dns_internal";
            metrics_path = "/probe";
            params = {
              module = [ "dns_internal" ];
            };
            static_configs = [
              {
                targets = [
                  "127.0.0.1"
                ];
              }
            ];
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
                replacement = "dns_internal";
              }
            ];
            scrape_interval = "60s";
            scrape_timeout = "10s";
          }
        ];
  };
}
