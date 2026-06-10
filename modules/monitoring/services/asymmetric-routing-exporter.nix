{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Custom Prometheus exporter for the asymmetric-routing source-policy ip rules.
  #
  # Context: the pri 50/51 source-policy rules (cross-subnet routing from
  # 192.168.1.2) silently vanished from the kernel after boot on 2026-06-09 even
  # though the fail-loud `asymmetric-routing` oneshot reported Result=success — it
  # only verifies the rules at the moment it runs (the 13:21 deploy), so it cannot
  # see later drift (NetworkManager wipes ip rules on interface events). This gauge
  # is the continuous detector: it re-checks the live kernel rule table every
  # minute and exposes 1 iff BOTH rules are present, 0 otherwise.
  #
  # Metrics exposed:
  # - asymmetric_routing_rules_present 1|0
  # - asymmetric_routing_rules_present_timestamp_seconds <epoch of last check>
  asymmetric-routing-exporter = pkgs.writeShellApplication {
    name = "asymmetric-routing-exporter";
    runtimeInputs = with pkgs; [
      iproute2
      coreutils
      gnugrep
    ];
    text = ''
            # Prometheus textfile exporter for asymmetric-routing ip-rule presence.
            # Outputs metrics to /var/lib/prometheus-node-exporter-textfiles/asymmetric_routing.prom

            TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"
            TEMP_FILE="$TEXTFILE_DIR/asymmetric_routing.prom.$$"
            OUTPUT_FILE="$TEXTFILE_DIR/asymmetric_routing.prom"

            # Ensure directory exists
            mkdir -p "$TEXTFILE_DIR"

            # Snapshot the live kernel policy-rule table once.
            rules=$(ip rule list 2>/dev/null || echo "")

            # Both source-policy rules must be present for routing to be correct.
            # These patterns mirror the verify loop in modules/core/networking.nix.
            present=1
            for prefix in 192.168.0.0/16 10.0.0.0/8; do
              if ! echo "$rules" | grep -q "from 192.168.1.2 to $prefix lookup end0_return"; then
                present=0
              fi
            done

            # Write metrics to temp file
            cat > "$TEMP_FILE" << EOF
      # HELP asymmetric_routing_rules_present Both asymmetric-routing source-policy ip rules present in kernel (1=yes, 0=no)
      # TYPE asymmetric_routing_rules_present gauge
      asymmetric_routing_rules_present $present

      # HELP asymmetric_routing_rules_present_timestamp_seconds Unix timestamp of last rule-presence check
      # TYPE asymmetric_routing_rules_present_timestamp_seconds gauge
      asymmetric_routing_rules_present_timestamp_seconds $(date +%s)
      EOF

            # Atomic move to prevent partial reads
            mv "$TEMP_FILE" "$OUTPUT_FILE"
            chmod 644 "$OUTPUT_FILE"
    '';
  };
in
{
  # ============================================================================
  # Asymmetric-Routing Prometheus Exporter
  # Custom exporter using textfile collector — continuous post-boot drift detector
  # ============================================================================

  # Systemd timer to run exporter every minute
  systemd.timers."asymmetric-routing-exporter" = {
    description = "Asymmetric-Routing ip-rule Presence Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      Unit = "asymmetric-routing-exporter.service";
    };
  };

  systemd.services."asymmetric-routing-exporter" = {
    description = "Asymmetric-Routing ip-rule Presence Exporter";
    after = [
      "asymmetric-routing.service"
      "prometheus-node-exporter.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe asymmetric-routing-exporter}";
      User = "root"; # Needs root to read the kernel ip-rule table
      Group = "root";
      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
    };
  };
}
