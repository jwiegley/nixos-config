{
  config,
  lib,
  pkgs,
  ...
}:

let
  # ==========================================================================
  # Port-Drift Detector — listening-socket posture vs the curated registry
  #
  # Design: docs/MONITORING_DEFERRED_SPECS.md "Port-Drift Detector" chapter.
  #
  # Motivation (the pre-implementation state this module closed): nothing on
  # vulcan continuously reconciled the live listening-socket set against
  # docs/ports.txt. The registry is hand-maintained and disciplined, but it is
  # a *document*, not an *invariant* — a misconfigured service that suddenly
  # binds a NEW wildcard (0.0.0.0/::) port (the canonical "I just exposed
  # something to the LAN" event) produced zero signal. THIS file is that
  # reconciler; it has been deployed and running since 2026-06-10.
  #
  # This collector parses docs/ports.txt into the set of registered ports +
  # their declared binding scope, snapshots `ss -tlnH`/`-ulnH` (addresses only;
  # NO -p, so no process names / PIDs ever touch the .prom file — least
  # privilege per the spec's security section), classifies each live bind into
  # a scope (wildcard4/wildcard6/loopback/specific), applies an ephemeral-port
  # floor (>=32768, the kernel ip_local_port_range default low bound) to drop
  # per-connection churn, and emits aggregate gauges.
  #
  # Pager semantics (the high-signal class): a wildcard listener on a
  # NON-ephemeral port whose port number is ENTIRELY ABSENT from the registry.
  # That is "a new externally-bound socket nobody declared." Loopback->wildcard
  # *widening* of an already-registered port (e.g. rootless podman port-forward
  # processes like pasta/slirp4netns surfacing a container's 0.0.0.0 bind on the
  # host while the registry calls the port loopback-only) is INFO ONLY — it is
  # an expected artifact of the rootless networking model, measured live on
  # 6383/6385 (container Redis) and 8084 (Open WebUI), all firewall-closed and
  # nginx-proxied. Folding those into the pager would chronically false-fire.
  # As of 2026-07-27 the gauge reads 4, not 3: port 2022 (Eternal Terminal,
  # added 2026-06-29) also counts as widened. That one is a registry-notation
  # artifact rather than a rootless one — it genuinely binds 0.0.0.0/::, but
  # docs/ports.txt:16 declares it per-interface ("end0 wlp1s0f0"), which the
  # section-1 parser does not read as a wildcard declaration. Same INFO-only
  # treatment applies: it is firewall-scoped to those two LAN interfaces.
  #
  # Metrics exposed (flat, low cardinality):
  #   port_drift_unexpected_wildcard_listeners{proto}    — PAGES (port not in registry)
  #   port_drift_widened_listeners{proto}                — info (registered loopback now wildcard)
  #   port_drift_unexpected_loopback_listeners{proto}    — info (non-ephemeral loopback not in registry)
  #   port_registry_stale_entries                        — lint (registered port, no live listener)
  #   port_drift_exporter_run_timestamp_seconds          — staleness watchdog
  #   port_drift_unexpected_wildcard_listener_info{port,proto}  — capped@10 forensic offender series
  #   port_drift_offenders_truncated                     — 1 iff offender list exceeded the cap
  #
  # The registry is pinned at BUILD time from the store (immutable: the gauge
  # reflects the *deployed* registry, matching the asymmetric-routing
  # "what's deployed" philosophy) rather than read live, so a mid-day
  # docs/ports.txt edit cannot skew the lint until the next rebuild.
  # ==========================================================================

  # Store-copy of the registry (immutable). Reflects the deployed ports.txt.
  portsRegistry = ../../../docs/ports.txt;

  port-drift-exporter = pkgs.writeShellApplication {
    name = "port-drift-exporter";
    runtimeInputs = with pkgs; [
      iproute2
      coreutils
      gnugrep
      gnused # used by the section-3 port-extraction pipeline; do not rely on the inherited unit PATH
      gawk
    ];
    text = ''
            TEXTFILE_DIR="/var/lib/prometheus-node-exporter-textfiles"
            OUTPUT_FILE="$TEXTFILE_DIR/port_drift.prom"
            TEMP_FILE="$OUTPUT_FILE.$$"
            REG="${portsRegistry}"
            EPHEMERAL_FLOOR=32768   # kernel ip_local_port_range default low bound

            mkdir -p "$TEXTFILE_DIR"

            # ---------------------------------------------------------------------
            # 1. Parse the registry. For each numeric leading-token line, accumulate
            #    the set of declared scope tokens across the interface columns that
            #    precede the human description. We track two things per port:
            #      REGISTERED[$port]=1            -> the port exists in the registry
            #      WILDCARD_OK[$port]=1           -> declared 0.0.0.0 / :: / * for it
            #    Interface vocabulary observed live: 0.0.0.0  ::  *  127.0.0.1  ::1
            #    container  <specific-ip>.  Description begins at the first token that
            #    is none of these, so we break out of the column scan there.
            # ---------------------------------------------------------------------
            declare -A REGISTERED
            declare -A WILDCARD_OK
            while read -r port rest; do
              # Skip comments and blanks.
              case "$port" in ""|\#*) continue ;; esac
              # Leading token must be a bare port number.
              case "$port" in *[!0-9]*) continue ;; esac
              REGISTERED[$port]=1
              # shellcheck disable=SC2086
              set -- $rest
              for tok in "$@"; do
                case "$tok" in
                  0.0.0.0|"::"|"*") WILDCARD_OK[$port]=1 ;;
                  127.0.0.1|"::1"|container) : ;;
                  # A specific IP (e.g. 10.99.1.1, 192.168.3.16) is still an iface column.
                  [0-9]*.[0-9]*.[0-9]*.[0-9]*) : ;;
                  # First non-interface token => description starts here. Stop scanning.
                  *) break ;;
                esac
              done
            done < "$REG"

            # ---------------------------------------------------------------------
            # 2. Snapshot + classify live listeners. Addresses only (no -p): we never
            #    write process names. Field 4 of `ss -H` is the local addr:port.
            #    classify() maps the address part to a scope.
            #
            #    DUAL-STACK DEDUP: a service that binds both 0.0.0.0 and [::] (or
            #    127.0.0.1 and [::1]) appears as TWO rows for ONE logical port. We
            #    first reduce each (proto,port) to the WIDEST scope observed
            #    (wildcard > loopback) in the SEEN map, then tally ONCE per distinct
            #    port. This is the IPv6/dual-stack dedup the spec calls for — without
            #    it, 6385 (Redis, binds 0.0.0.0 + [::]) and 8317 (sshd-session, binds
            #    127.0.0.1 + [::1]) would each be counted twice.
            # ---------------------------------------------------------------------
            uw_tcp=0; uw_udp=0          # unexpected wildcard (port absent from registry)  -> PAGES
            wid_tcp=0; wid_udp=0        # widened: registered loopback-only now binds wildcard -> info
            ulo_tcp=0; ulo_udp=0        # unexpected loopback (non-ephemeral, port absent)     -> info

            # Forensic offender list for the wildcard PAGER class (capped).
            OFFENDER_CAP=10
            offenders=""
            offender_n=0
            truncated=0

            add_offender() { # $1=port $2=proto
              if [ "$offender_n" -lt "$OFFENDER_CAP" ]; then
                offenders="$offenders$1 $2
      "
                offender_n=$((offender_n + 1))
              else
                truncated=1
              fi
            }

            classify() {
              case "$1" in
                0.0.0.0) echo w ;;
                "[::]"|"::") echo w ;;
                127.0.0.1) echo lo ;;
                "[::1]"|"::1") echo lo ;;
                *) echo spec ;;   # specific-IP / bridge / link-local: not drift-relevant
              esac
            }

            for proto in tcp udp; do
              if [ "$proto" = tcp ]; then flag=-tlnH; else flag=-ulnH; fi
              # SEEN[$port] holds the widest class seen for this port (w beats lo).
              declare -A SEEN
              # Field 4 = local addr:port. Strip a trailing :PORT after the last
              # colon; this also handles bracketed IPv6 and link-local "[..]%iface:port".
              while read -r la; do
                [ -n "$la" ] || continue
                port="''${la##*:}"
                addr="''${la%:*}"
                case "$port" in ""|*[!0-9]*) continue ;; esac
                scope=$(classify "$addr")
                case "$scope" in
                  w)
                    # Wildcard. Apply the ephemeral floor (matter/hass CASE-session
                    # UDP churn + any ephemeral wildcard TCP are >=32768 → ignored).
                    [ "$port" -ge "$EPHEMERAL_FLOOR" ] && continue
                    SEEN[$port]=w ;;
                  lo)
                    # Loopback. Ephemeral high ports are per-process churn → ignore.
                    [ "$port" -ge "$EPHEMERAL_FLOOR" ] && continue
                    # Do not let a loopback row downgrade a wildcard one for the same port.
                    [ "''${SEEN[$port]:-}" = w ] || SEEN[$port]=lo ;;
                  *) : ;;
                esac
              done < <(ss "$flag" 2>/dev/null | awk '{print $4}')

              # Tally once per distinct port for this proto.
              for port in "''${!SEEN[@]}"; do
                case "''${SEEN[$port]}" in
                  w)
                    if [ "''${REGISTERED[$port]:-}" = 1 ]; then
                      # Declared. Wildcard-declared = no drift; loopback-only = WIDENING (info).
                      if [ "''${WILDCARD_OK[$port]:-}" != 1 ]; then
                        if [ "$proto" = tcp ]; then wid_tcp=$((wid_tcp + 1)); else wid_udp=$((wid_udp + 1)); fi
                      fi
                    else
                      # Port absent from the registry entirely -> the PAGER signal.
                      if [ "$proto" = tcp ]; then uw_tcp=$((uw_tcp + 1)); else uw_udp=$((uw_udp + 1)); fi
                      add_offender "$port" "$proto"
                    fi ;;
                  lo)
                    if [ "''${REGISTERED[$port]:-}" != 1 ]; then
                      if [ "$proto" = tcp ]; then ulo_tcp=$((ulo_tcp + 1)); else ulo_udp=$((ulo_udp + 1)); fi
                    fi ;;
                esac
              done
              unset SEEN
            done

            # ---------------------------------------------------------------------
            # 3. Reverse-drift lint: registered ports with NO live listener.
            #    Build the live-port set once, then count registry keys missing from it.
            # ---------------------------------------------------------------------
            # `|| true`: grep exits 1 when nothing matches, and under
            # errexit+pipefail that would abort the whole run before the
            # atomic emit. An empty live set then counts every registered
            # port as stale — loud, visible failure instead of a silent one.
            live_ports=$( { ss -tlnH; ss -ulnH; } 2>/dev/null \
              | awk '{print $4}' \
              | sed -E 's/^.*:([0-9]+)$/\1/' \
              | grep -E '^[0-9]+$' \
              | sort -un || true )
            stale=0
            for p in "''${!REGISTERED[@]}"; do
              if ! printf '%s\n' "$live_ports" | grep -qx "$p"; then
                stale=$((stale + 1))
              fi
            done

            # ---------------------------------------------------------------------
            # 4. Atomic emit. Timestamp is written even on a partial parse so that
            #    staleness (not silence) is the failure mode.
            # ---------------------------------------------------------------------
            {
              echo "# HELP port_drift_unexpected_wildcard_listeners Wildcard (0.0.0.0/::) listeners on a non-ephemeral port absent from docs/ports.txt"
              echo "# TYPE port_drift_unexpected_wildcard_listeners gauge"
              echo "port_drift_unexpected_wildcard_listeners{proto=\"tcp\"} $uw_tcp"
              echo "port_drift_unexpected_wildcard_listeners{proto=\"udp\"} $uw_udp"
              echo "# HELP port_drift_widened_listeners Registered loopback-only ports now binding wildcard (rootless port-forward artifact; info)"
              echo "# TYPE port_drift_widened_listeners gauge"
              echo "port_drift_widened_listeners{proto=\"tcp\"} $wid_tcp"
              echo "port_drift_widened_listeners{proto=\"udp\"} $wid_udp"
              echo "# HELP port_drift_unexpected_loopback_listeners Non-ephemeral loopback listeners absent from docs/ports.txt (info)"
              echo "# TYPE port_drift_unexpected_loopback_listeners gauge"
              echo "port_drift_unexpected_loopback_listeners{proto=\"tcp\"} $ulo_tcp"
              echo "port_drift_unexpected_loopback_listeners{proto=\"udp\"} $ulo_udp"
              echo "# HELP port_registry_stale_entries Registered ports with no live listener (lint)"
              echo "# TYPE port_registry_stale_entries gauge"
              echo "port_registry_stale_entries $stale"
              echo "# HELP port_drift_offenders_truncated 1 iff the unexpected-wildcard offender list exceeded its cap"
              echo "# TYPE port_drift_offenders_truncated gauge"
              echo "port_drift_offenders_truncated $truncated"
              echo "# HELP port_drift_unexpected_wildcard_listener_info Forensic per-port marker for unexpected wildcard listeners (capped, normally empty)"
              echo "# TYPE port_drift_unexpected_wildcard_listener_info gauge"
              if [ -n "$offenders" ]; then
                printf '%s' "$offenders" | while read -r op opr; do
                  [ -n "$op" ] || continue
                  echo "port_drift_unexpected_wildcard_listener_info{port=\"$op\",proto=\"$opr\"} 1"
                done
              fi
              echo "# HELP port_drift_exporter_run_timestamp_seconds Unix time of last successful port-drift scan"
              echo "# TYPE port_drift_exporter_run_timestamp_seconds gauge"
              echo "port_drift_exporter_run_timestamp_seconds $(date +%s)"
            } > "$TEMP_FILE"

            mv "$TEMP_FILE" "$OUTPUT_FILE"
            chmod 644 "$OUTPUT_FILE"
    '';
  };
in
{
  # ============================================================================
  # Port-Drift Prometheus Exporter
  # Wildcard-listener tripwire + ports.txt registry lint (textfile collector).
  # ============================================================================

  systemd.timers."port-drift-exporter" = {
    description = "Port-Drift Detector Exporter Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Unit = "port-drift-exporter.service";
    };
  };

  systemd.services."port-drift-exporter" = {
    description = "Port-Drift Detector Exporter (listening sockets vs docs/ports.txt)";
    after = [ "prometheus-node-exporter.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe port-drift-exporter}";
      # `ss` lists all listening sockets' addresses for any user; we omit -p
      # (no process introspection), so root is not strictly required, but we
      # keep User=root for a reliable full-table snapshot and parity with the
      # asymmetric-routing template. No process names/PIDs are ever emitted.
      User = "root";
      Group = "root";
      # Security hardening.
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      ReadWritePaths = [ "/var/lib/prometheus-node-exporter-textfiles" ];
    };
  };
}
