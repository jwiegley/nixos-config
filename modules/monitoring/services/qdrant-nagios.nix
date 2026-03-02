{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Custom Nagios health check for Qdrant REST API
  # /healthz does not require authentication
  checkQdrantHealth = pkgs.writeShellScript "check_qdrant_health.sh" ''
    set -euo pipefail

    STATE_OK=0
    STATE_WARNING=1
    STATE_CRITICAL=2
    STATE_UNKNOWN=3

    HOST="''${1:-127.0.0.1}"
    PORT="''${2:-6333}"

    RESPONSE=$(${pkgs.curl}/bin/curl -sf \
      --connect-timeout 5 \
      --max-time 10 \
      "http://$HOST:$PORT/healthz" 2>&1) || {
      echo "CRITICAL: Qdrant health endpoint unreachable at http://$HOST:$PORT/healthz"
      exit "$STATE_CRITICAL"
    }

    # /healthz returns JSON {"title":"qdrant - version x.y.z"} when healthy
    if echo "$RESPONSE" | ${pkgs.gnugrep}/bin/grep -q '"title"'; then
      VERSION=$(echo "$RESPONSE" | ${pkgs.gnused}/bin/sed 's/.*"title":"\([^"]*\)".*/\1/')
      echo "OK: Qdrant is healthy ($VERSION)"
      exit "$STATE_OK"
    else
      echo "WARNING: Qdrant returned unexpected response: $RESPONSE"
      exit "$STATE_WARNING"
    fi
  '';

  qdrantNagiosObjectDefs = pkgs.writeText "qdrant-nagios.cfg" ''
    # ============================================================================
    # Qdrant Vector Database - Commands
    # ============================================================================

    define command {
      command_name    check_qdrant_health
      command_line    ${checkQdrantHealth} $ARG1$ $ARG2$
    }

    # ============================================================================
    # Qdrant Vector Database - Services
    # ============================================================================

    # Qdrant systemd service state
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     Qdrant Service
      check_command           check_systemd_service!qdrant.service
      service_groups          application-services
    }

    # Qdrant REST API health (direct, no auth required for /healthz)
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     Qdrant Health Check
      check_command           check_qdrant_health!127.0.0.1!6333
      service_groups          application-services
    }

    # Qdrant HTTPS virtual host (via nginx proxy)
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     Qdrant HTTPS (qdrant.vulcan.lan)
      check_command           check_https!qdrant.vulcan.lan!/healthz
      service_groups          application-services
    }

    # Qdrant SSL certificate expiry
    define service {
      use                     critical-service
      host_name               vulcan
      service_description     Qdrant SSL Certificate
      check_command           check_ssl_cert!qdrant.vulcan.lan
      service_groups          ssl-certificates
    }
  '';
in
{
  services.nagios.objectDefs = [ qdrantNagiosObjectDefs ];
}
