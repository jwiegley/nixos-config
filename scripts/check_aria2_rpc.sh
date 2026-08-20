#!/usr/bin/env bash
#
# Health check for the aria2 RPC endpoint.
# Tests actual RPC functionality, not just HTTP response.
#
# Exit codes follow the monitoring-plugin convention (0/1/2/3) this was
# originally written against. Since Nagios was removed on 2026-08-19 no unit
# or timer in this repo runs it; it is a manual probe. Wire it to a textfile
# collector if it should be scheduled again.
#

set -euo pipefail

# Configuration
RPC_URL="${1:-https://aria.vulcan.lan/jsonrpc}"
SECRET_FILE="/run/secrets/aria2_rpc_secret"
TIMEOUT=5

# Monitoring-plugin return codes
OK=0
WARNING=1
CRITICAL=2
UNKNOWN=3

# Check if secret file exists
if [ ! -f "$SECRET_FILE" ]; then
    echo "UNKNOWN: Secret file $SECRET_FILE not found"
    exit $UNKNOWN
fi

# Read secret
SECRET=$(cat "$SECRET_FILE")

# Make RPC call
RESPONSE=$(curl -k -s --max-time "$TIMEOUT" -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"aria2.getVersion\",\"id\":\"aria2-rpc-check\",\"params\":[\"token:$SECRET\"]}" \
    2>&1) || {
    echo "CRITICAL: Failed to connect to aria2 RPC endpoint"
    exit $CRITICAL
}

# Parse response
if echo "$RESPONSE" | grep -q '"result"'; then
    # Extract version if available
    VERSION=$(echo "$RESPONSE" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$VERSION" ]; then
        echo "OK: aria2 RPC endpoint responding (version $VERSION)"
        exit $OK
    else
        echo "OK: aria2 RPC endpoint responding"
        exit $OK
    fi
elif echo "$RESPONSE" | grep -q '"error"'; then
    ERROR_MSG=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    echo "CRITICAL: aria2 RPC returned error: $ERROR_MSG"
    exit $CRITICAL
else
    echo "CRITICAL: aria2 RPC returned unexpected response: $RESPONSE"
    exit $CRITICAL
fi
