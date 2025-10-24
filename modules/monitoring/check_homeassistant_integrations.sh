#!/usr/bin/env bash
#
# Nagios check script for Home Assistant integration health
# Returns: OK=0, WARNING=1, CRITICAL=2, UNKNOWN=3
#
# Usage: check_homeassistant_integrations.sh -H <host> -t <token> [-w <warn>] [-c <crit>]
#
# Options:
#   -H    Home Assistant host (default: localhost:8123)
#   -t    Long-lived access token (required)
#   -w    Warning threshold for unavailable entities (default: 5)
#   -c    Critical threshold for unavailable entities (default: 10)
#   -s    Use HTTPS instead of HTTP
#   -i    Check specific integration(s), comma-separated (optional)
#

set -euo pipefail

# Default values
HOST="localhost:8123"
TOKEN=""
WARN_THRESHOLD=5
CRIT_THRESHOLD=10
PROTOCOL="http"
SPECIFIC_INTEGRATIONS=""

# Parse arguments
while getopts "H:t:w:c:si:h" opt; do
  case $opt in
    H) HOST="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    w) WARN_THRESHOLD="$OPTARG" ;;
    c) CRIT_THRESHOLD="$OPTARG" ;;
    s) PROTOCOL="https" ;;
    i) SPECIFIC_INTEGRATIONS="$OPTARG" ;;
    h)
      echo "Usage: $0 -H <host> -t <token> [-w <warn>] [-c <crit>] [-s] [-i <integrations>]"
      exit 0
      ;;
    *)
      echo "Invalid option: -$OPTARG" >&2
      exit 3
      ;;
  esac
done

# Validate token
if [ -z "$TOKEN" ]; then
  echo "UNKNOWN - Access token required (-t option)"
  exit 3
fi

# Build API URLs
BASE_URL="${PROTOCOL}://${HOST}"
STATES_URL="${BASE_URL}/api/states"
INTEGRATION_REGISTRY_URL="${BASE_URL}/api/config/integration_registry"

# Function to call API
call_api() {
  local url="$1"
  curl -s -f \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$url" 2>/dev/null || echo "ERROR"
}

# Check if Home Assistant is reachable
response=$(call_api "$STATES_URL")
if [ "$response" = "ERROR" ]; then
  echo "CRITICAL - Home Assistant API unreachable at ${BASE_URL}"
  exit 2
fi

# Parse entity states
unavailable_count=0
unavailable_entities=()
total_entities=0

while IFS= read -r line; do
  entity_id=$(echo "$line" | jq -r '.entity_id')
  state=$(echo "$line" | jq -r '.state')

  total_entities=$((total_entities + 1))

  if [ "$state" = "unavailable" ]; then
    unavailable_count=$((unavailable_count + 1))
    unavailable_entities+=("$entity_id")
  fi
done < <(echo "$response" | jq -c '.[]')

# Check integration registry if available
failed_integrations=()
integration_check_failed=false

integration_response=$(call_api "$INTEGRATION_REGISTRY_URL")
if [ "$integration_response" != "ERROR" ]; then
  # Check for disabled or error state integrations
  if [ -n "$SPECIFIC_INTEGRATIONS" ]; then
    # Check specific integrations
    IFS=',' read -ra INTEGRATION_LIST <<< "$SPECIFIC_INTEGRATIONS"
    for integration in "${INTEGRATION_LIST[@]}"; do
      integration_status=$(echo "$integration_response" | jq -r ".[] | select(.domain==\"$integration\") | .disabled_by" 2>/dev/null || echo "null")
      if [ "$integration_status" != "null" ] && [ "$integration_status" != "" ]; then
        failed_integrations+=("$integration (disabled)")
      fi
    done
  else
    # Check all integrations for disabled state
    while IFS= read -r domain; do
      failed_integrations+=("$domain (disabled)")
    done < <(echo "$integration_response" | jq -r '.[] | select(.disabled_by != null) | .domain' 2>/dev/null || true)
  fi
else
  integration_check_failed=true
fi

# Build performance data
perfdata="entities=${total_entities} unavailable=${unavailable_count};${WARN_THRESHOLD};${CRIT_THRESHOLD};0;${total_entities}"

# Determine status and output
status_msg="Total: ${total_entities} entities, Unavailable: ${unavailable_count}"

# Add integration failures to message
if [ ${#failed_integrations[@]} -gt 0 ]; then
  status_msg="${status_msg}, Failed integrations: ${failed_integrations[*]}"
fi

# List some unavailable entities if any
if [ ${#unavailable_entities[@]} -gt 0 ]; then
  # Show first 5 unavailable entities
  sample_unavailable=$(printf "%s, " "${unavailable_entities[@]:0:5}")
  sample_unavailable=${sample_unavailable%, }
  status_msg="${status_msg} | Unavailable: ${sample_unavailable}"

  if [ ${#unavailable_entities[@]} -gt 5 ]; then
    status_msg="${status_msg} (+$((${#unavailable_entities[@]} - 5)) more)"
  fi
fi

# Check thresholds
if [ ${#failed_integrations[@]} -gt 0 ]; then
  echo "CRITICAL - ${status_msg} | ${perfdata}"
  exit 2
elif [ "$unavailable_count" -ge "$CRIT_THRESHOLD" ]; then
  echo "CRITICAL - ${status_msg} | ${perfdata}"
  exit 2
elif [ "$unavailable_count" -ge "$WARN_THRESHOLD" ]; then
  echo "WARNING - ${status_msg} | ${perfdata}"
  exit 1
else
  echo "OK - ${status_msg} | ${perfdata}"
  exit 0
fi
