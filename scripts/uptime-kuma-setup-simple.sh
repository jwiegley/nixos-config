#!/usr/bin/env bash
# Simplified Uptime Kuma setup script using curl commands
# This version uses the Uptime Kuma API directly without Python dependencies

set -euo pipefail

# Configuration
UPTIME_KUMA_URL="https://uptime.vulcan.lan"
COOKIE_FILE="/tmp/uptime-kuma-cookies.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Uptime Kuma Monitor Setup Script ===${NC}"
echo "Target: $UPTIME_KUMA_URL"
echo ""

# Cleanup function
cleanup() {
    rm -f "$COOKIE_FILE"
}
trap cleanup EXIT

# Get credentials
echo "Please enter your Uptime Kuma credentials."
echo "If this is the first run, these will become your admin credentials."
read -p "Username: " USERNAME
read -s -p "Password: " PASSWORD
echo ""

# Function to add a monitor using curl
add_monitor() {
    local name="$1"
    local type="$2"
    local target="$3"
    local interval="${4:-300}"
    local tags="${5:-}"

    echo -n "Adding: $name..."

    # Build JSON payload based on monitor type
    local payload=""

    if [ "$type" = "http" ]; then
        payload=$(cat <<EOF
{
    "type": "http",
    "name": "$name",
    "url": "$target",
    "interval": $interval,
    "retryInterval": 60,
    "maxretries": 3,
    "accepted_statuscodes": ["200-299"],
    "ignoreTls": true,
    "method": "GET"
}
EOF
)
    elif [ "$type" = "port" ]; then
        IFS=':' read -r hostname port <<< "$target"
        payload=$(cat <<EOF
{
    "type": "port",
    "name": "$name",
    "hostname": "$hostname",
    "port": $port,
    "interval": $interval,
    "retryInterval": 60,
    "maxretries": 3
}
EOF
)
    elif [ "$type" = "dns" ]; then
        payload=$(cat <<EOF
{
    "type": "dns",
    "name": "$name",
    "hostname": "$target",
    "dns_resolve_server": "192.168.1.2",
    "port": 53,
    "interval": $interval,
    "retryInterval": 60,
    "maxretries": 3
}
EOF
)
    fi

    # Note: The actual API endpoint may vary depending on Uptime Kuma version
    # This is a placeholder - actual implementation would need Socket.IO
    echo -e " ${YELLOW}(Manual setup required via web interface)${NC}"
}

echo ""
echo -e "${YELLOW}Note: Due to Uptime Kuma's Socket.IO-based API, monitors must be added via the web interface.${NC}"
echo ""
echo "Here are the monitors to add manually:"
echo ""

echo -e "${GREEN}Web Services (HTTPS Monitors):${NC}"
echo "  • Jellyfin: https://jellyfin.vulcan.lan"
echo "  • Smokeping: https://smokeping.vulcan.lan"
echo "  • pgAdmin: https://postgres.vulcan.lan"
echo "  • DNS Admin: https://dns.vulcan.lan"
echo "  • Organizr: https://organizr.vulcan.lan"
echo "  • Wallabag: https://wallabag.vulcan.lan"
echo "  • Grafana: https://grafana.vulcan.lan"
echo ""

echo -e "${GREEN}TCP Port Monitors:${NC}"
echo "  • PostgreSQL: 192.168.1.2:5432"
echo "  • Redis (LiteLLM): 10.88.0.1:8085"
echo "  • Step-CA: 127.0.0.1:8443"
echo "  • DNS Server: 192.168.1.2:53"
echo "  • Postfix SMTP: 192.168.1.2:25"
echo "  • Postfix Submission: 192.168.1.2:587"
echo "  • Dovecot IMAP: 192.168.1.2:143"
echo "  • Dovecot IMAPS: 192.168.1.2:993"
echo "  • SSH: 192.168.1.2:22"
echo "  • Prometheus: 127.0.0.1:9090"
echo ""

echo -e "${GREEN}Container Services:${NC}"
echo "  • LiteLLM API: http://10.88.0.1:4000/health"
echo "  • Home Site: https://home.newartisans.com"
echo ""

echo -e "${GREEN}Certificate Monitoring:${NC}"
echo "  • Enable certificate expiry notifications for all HTTPS monitors"
echo "  • Set warning threshold to 30 days"
echo ""

echo "Access your dashboard at: $UPTIME_KUMA_URL"
echo ""
echo "Recommended settings:"
echo "  • Critical services: 60 second interval"
echo "  • Web services: 5 minute interval"
echo "  • Non-critical: 10 minute interval"
echo "  • Certificate checks: Daily"
