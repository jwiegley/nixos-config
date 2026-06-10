{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Nagios checks for the syncthing service (two-way /tank/Public <-> hera).
  # Modeled on qdrant-nagios.nix; the sync-status check additionally uses the
  # sops API key (group johnw 0440 — nagios is a member), the same credential
  # the Prometheus scrape uses. Both REST checks talk to the loopback GUI
  # listener directly, not the nginx vhost.

  # /rest/noauth/health needs no authentication and returns {"status": "OK"}.
  checkSyncthingHealth = pkgs.writeShellScript "check_syncthing_health.sh" ''
    set -euo pipefail

    STATE_OK=0
    STATE_WARNING=1
    STATE_CRITICAL=2

    HOST="''${1:-127.0.0.1}"
    PORT="''${2:-8384}"

    RESPONSE=$(${pkgs.curl}/bin/curl -sf \
      --connect-timeout 5 \
      --max-time 10 \
      "http://$HOST:$PORT/rest/noauth/health" 2>&1) || {
      echo "CRITICAL: Syncthing health endpoint unreachable at http://$HOST:$PORT/rest/noauth/health"
      exit "$STATE_CRITICAL"
    }

    if echo "$RESPONSE" | ${pkgs.jq}/bin/jq -e '.status == "OK"' >/dev/null 2>&1; then
      echo "OK: Syncthing is healthy"
      exit "$STATE_OK"
    else
      echo "WARNING: Syncthing health returned unexpected response: $RESPONSE"
      exit "$STATE_WARNING"
    fi
  '';

  # Peer connectivity + folder completion via the authenticated REST API.
  # Device-agnostic: discovers remote peers from the live config rather than
  # pinning hera's ID a second time (single source of truth stays in
  # modules/services/syncthing.nix). WARNING (not CRITICAL) states: a
  # disconnected peer usually means hera is rebooting/asleep and transfers
  # in flight are normal; nagios retry logic (standard-service) absorbs
  # transients before notifying.
  checkSyncthingSync = pkgs.writeShellScript "check_syncthing_sync.sh" ''
    set -euo pipefail

    STATE_OK=0
    STATE_WARNING=1
    STATE_CRITICAL=2
    STATE_UNKNOWN=3

    HOST="127.0.0.1"
    PORT="8384"
    JQ=${pkgs.jq}/bin/jq

    API_KEY=$(cat ${config.sops.secrets."syncthing/api-key".path} 2>/dev/null) || {
      echo "UNKNOWN: cannot read syncthing API key"
      exit "$STATE_UNKNOWN"
    }

    # The key must never appear on a process argv (/proc cmdline is
    # world-readable): printf is a bash builtin, and curl reads the header
    # from the 0600 temp file via -H @file.
    umask 0077
    HDR_DIR=$(mktemp -d)
    trap 'rm -rf "$HDR_DIR"' EXIT
    printf 'X-API-Key: %s\n' "$API_KEY" > "$HDR_DIR/headers"

    api() {
      ${pkgs.curl}/bin/curl -sf --connect-timeout 5 --max-time 10 \
        -H "@$HDR_DIR/headers" "http://$HOST:$PORT$1"
    }

    MY_ID=$(api /rest/system/status | $JQ -r .myID) || {
      echo "CRITICAL: Syncthing REST API unreachable"
      exit "$STATE_CRITICAL"
    }

    # Remote peers and their connection state.
    CONNS=$(api /rest/system/connections)
    DISCONNECTED=$($JQ -r --arg me "$MY_ID" \
      '.connections | to_entries
       | map(select(.key != $me and (.value.connected | not)) | .key)
       | join(",")' <<<"$CONNS")
    CONNECTED_COUNT=$($JQ -r --arg me "$MY_ID" \
      '.connections | to_entries
       | map(select(.key != $me and .value.connected)) | length' <<<"$CONNS")

    # Local pending work for the shared folder.
    DBSTATUS=$(api "/rest/db/status?folder=tank-public") || {
      echo "CRITICAL: folder tank-public not present in the running config"
      exit "$STATE_CRITICAL"
    }
    NEED=$($JQ -r '.needTotalItems' <<<"$DBSTATUS")
    STATE=$($JQ -r '.state' <<<"$DBSTATUS")

    if [ -n "$DISCONNECTED" ]; then
      echo "WARNING: peer(s) disconnected: $DISCONNECTED (folder state: $STATE)"
      exit "$STATE_WARNING"
    fi

    if [ "$NEED" -gt 0 ]; then
      echo "WARNING: tank-public syncing - $NEED items pending (state: $STATE)"
      exit "$STATE_WARNING"
    fi

    echo "OK: tank-public in sync, $CONNECTED_COUNT peer(s) connected (state: $STATE)"
    exit "$STATE_OK"
  '';

  syncthingNagiosObjectDefs = pkgs.writeText "syncthing-nagios.cfg" ''
    # ============================================================================
    # Syncthing (two-way /tank/Public <-> hera) - Commands
    # ============================================================================

    define command {
      command_name    check_syncthing_health
      command_line    ${checkSyncthingHealth} $ARG1$ $ARG2$
    }

    define command {
      command_name    check_syncthing_sync
      command_line    ${checkSyncthingSync}
    }

    # ============================================================================
    # Syncthing - Services
    # ============================================================================

    # systemd unit state, gated on the /tank/Public mount: the unit carries
    # ConditionPathIsMountPoint=/tank/Public, so the plain systemd check
    # would false-CRITICAL whenever tank is unavailable (nagios.nix:1340).
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     Syncthing Service
      check_command           check_systemd_service_conditional!syncthing.service!/tank/Public
      service_groups          application-services
    }

    # REST health endpoint (no auth required for /rest/noauth/health)
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     Syncthing Health Check
      check_command           check_syncthing_health!127.0.0.1!8384
      service_groups          application-services
    }

    # Peer connectivity + folder completion (authenticated REST)
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     Syncthing Sync Status
      check_command           check_syncthing_sync
      service_groups          application-services
    }

    # HTTPS virtual host (via nginx proxy; anonymous GET serves the login page)
    define service {
      use                     standard-service
      host_name               vulcan
      service_description     Syncthing HTTPS (syncthing.vulcan.lan)
      check_command           check_https!syncthing.vulcan.lan!/
      service_groups          application-services
    }

    # SSL certificate expiry (step-ca cert, renewed by nginx-cert-renewal;
    # daily-service matches every other ssl-certificates entry)
    define service {
      use                     daily-service
      host_name               vulcan
      service_description     Syncthing SSL Certificate
      check_command           check_ssl_cert!syncthing.vulcan.lan
      service_groups          ssl-certificates
    }
  '';
in
{
  services.nagios.objectDefs = [ syncthingNagiosObjectDefs ];
}
