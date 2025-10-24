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
#   -I    Integration-only mode: only check if integrations are loaded (ignore entities)
#

set -euo pipefail

# Default values
HOST="localhost:8123"
TOKEN=""
WARN_THRESHOLD=5
CRIT_THRESHOLD=10
PROTOCOL="http"
SPECIFIC_INTEGRATIONS=""
INTEGRATION_ONLY_MODE=false

# Parse arguments
while getopts "H:t:w:c:si:Ih" opt; do
  case $opt in
    H) HOST="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    w) WARN_THRESHOLD="$OPTARG" ;;
    c) CRIT_THRESHOLD="$OPTARG" ;;
    s) PROTOCOL="https" ;;
    i) SPECIFIC_INTEGRATIONS="$OPTARG" ;;
    I) INTEGRATION_ONLY_MODE=true ;;
    h)
      echo "Usage: $0 -H <host> -t <token> [-w <warn>] [-c <crit>] [-s] [-i <integrations>] [-I]"
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
CONFIG_URL="${BASE_URL}/api/config"

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

# Get configuration including loaded components
config_response=$(call_api "$CONFIG_URL")
if [ "$config_response" = "ERROR" ]; then
  echo "CRITICAL - Cannot access Home Assistant configuration API"
  exit 2
fi

# Extract loaded components list
loaded_components=$(echo "$config_response" | jq -r '.components[]' 2>/dev/null)
if [ -z "$loaded_components" ]; then
  echo "CRITICAL - Cannot parse loaded components from API"
  exit 2
fi

# Integration-only mode: just check if integrations are loaded
if [ "$INTEGRATION_ONLY_MODE" = true ]; then
  missing_integrations=()
  loaded_integrations=()

  # Must specify integrations in integration-only mode
  if [ -z "$SPECIFIC_INTEGRATIONS" ]; then
    echo "UNKNOWN - Integration-only mode requires -i parameter with specific integrations"
    exit 3
  fi

  # Check each specified integration
  IFS=',' read -ra INTEGRATION_LIST <<< "$SPECIFIC_INTEGRATIONS"
  for integration in "${INTEGRATION_LIST[@]}"; do
    # Check if integration is in loaded components list
    if echo "$loaded_components" | grep -q "^${integration}$"; then
      loaded_integrations+=("$integration")
    else
      missing_integrations+=("$integration")
    fi
  done

  # Build status message
  total_checked=${#INTEGRATION_LIST[@]}
  loaded_count=${#loaded_integrations[@]}
  missing_count=${#missing_integrations[@]}

  status_msg="Integrations: ${loaded_count}/${total_checked} loaded"

  # Determine exit status
  if [ $missing_count -gt 0 ]; then
    status_msg="${status_msg}, Missing: ${missing_integrations[*]}"
    echo "CRITICAL - ${status_msg}"
    exit 2
  else
    status_msg="${status_msg} (${loaded_integrations[*]})"
    echo "OK - ${status_msg}"
    exit 0
  fi
fi

# Normal mode: Check entity availability
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

# Check if specific integrations are loaded (optional)
missing_integrations=()

if [ -n "$SPECIFIC_INTEGRATIONS" ]; then
  # Check specific integrations are loaded
  IFS=',' read -ra INTEGRATION_LIST <<< "$SPECIFIC_INTEGRATIONS"
  for integration in "${INTEGRATION_LIST[@]}"; do
    if ! echo "$loaded_components" | grep -q "^${integration}$"; then
      missing_integrations+=("$integration")
    fi
  done
fi

# Build performance data
perfdata="entities=${total_entities} unavailable=${unavailable_count};${WARN_THRESHOLD};${CRIT_THRESHOLD};0;${total_entities}"

# Determine status and output
status_msg="Total: ${total_entities} entities, Unavailable: ${unavailable_count}"

# Add missing integrations to message
if [ ${#missing_integrations[@]} -gt 0 ]; then
  status_msg="${status_msg}, Missing integrations: ${missing_integrations[*]}"
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
if [ ${#missing_integrations[@]} -gt 0 ]; then
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
