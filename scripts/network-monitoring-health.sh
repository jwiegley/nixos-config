#!/usr/bin/env bash

# Network Monitoring Health Check Script
# Comprehensive health check for blackbox exporter and network monitoring

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if a service is running
check_service() {
    local service=$1
    if systemctl is-active "$service" >/dev/null 2>&1; then
        print_success "$service is running"
        return 0
    else
        print_error "$service is not running"
        return 1
    fi
}

# Test network connectivity to a host
test_connectivity() {
    local host=$1
    local description=$2

    # Test with blackbox exporter if available
    if curl -s "http://localhost:9115/probe?module=icmp_ping&target=$host" >/dev/null 2>&1; then
        local result=$(curl -s "http://localhost:9115/probe?module=icmp_ping&target=$host" | grep "probe_success" | awk '{print $2}')
        local duration=$(curl -s "http://localhost:9115/probe?module=icmp_ping&target=$host" | grep "probe_duration_seconds" | awk '{print $2}')

        if [[ "$result" == "1" ]]; then
            print_success "$description ($host) - ${duration}s"
        else
            print_error "$description ($host) - unreachable"
        fi
    else
        # Fallback to ping
        if ping -c1 -W2 "$host" >/dev/null 2>&1; then
            print_success "$description ($host) - reachable via ping"
        else
            print_error "$description ($host) - unreachable"
        fi
    fi
}

# Main health check
main() {
    echo "Network Monitoring Health Check"
    echo "==============================="

    print_header "Service Status"
    check_service "prometheus"
    check_service "prometheus-blackbox-exporter"
    check_service "grafana"

    print_header "Blackbox Exporter Configuration"
    if curl -s http://localhost:9115/config >/dev/null 2>&1; then
        local modules=$(curl -s http://localhost:9115/config | jq -r '.modules | keys[]' 2>/dev/null | wc -l)
        print_success "Blackbox exporter responding with $modules probe modules"

        echo "Available modules:"
        curl -s http://localhost:9115/config | jq -r '.modules | to_entries[] | "  \(.key): \(.value.prober)"' 2>/dev/null || print_warning "Could not parse modules"
    else
        print_error "Blackbox exporter not responding on localhost:9115"
    fi

    print_header "Network Connectivity Tests"
    test_connectivity "8.8.8.8" "Google DNS"
    test_connectivity "1.1.1.1" "Cloudflare DNS"
    test_connectivity "google.com" "Google.com"
    test_connectivity "github.com" "GitHub"

    print_header "Prometheus Targets"
    if curl -s http://localhost:9090/api/v1/targets >/dev/null 2>&1; then
        local targets=$(curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job | startswith("blackbox")) | "\(.labels.job): \(.health)"' 2>/dev/null)
        if [[ -n "$targets" ]]; then
            echo "Blackbox targets:"
            echo "$targets" | while IFS= read -r line; do
                if [[ "$line" =~ "up" ]]; then
                    print_success "$line"
                else
                    print_error "$line"
                fi
            done
        else
            print_warning "No blackbox targets found in Prometheus"
        fi
    else
        print_error "Cannot connect to Prometheus on localhost:9090"
    fi

    print_header "Active Network Alerts"
    if curl -s http://localhost:9090/api/v1/alerts >/dev/null 2>&1; then
        local alerts=$(curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.category == "network") | "\(.labels.alertname): \(.state)"' 2>/dev/null)
        if [[ -n "$alerts" ]]; then
            echo "Network alerts:"
            echo "$alerts" | while IFS= read -r line; do
                if [[ "$line" =~ "firing" ]]; then
                    print_error "$line"
                else
                    print_warning "$line"
                fi
            done
        else
            print_success "No active network alerts"
        fi
    else
        print_error "Cannot query alerts from Prometheus"
    fi

    print_header "Grafana Dashboard Access"
    if curl -s http://localhost:3000/api/health >/dev/null 2>&1; then
        print_success "Grafana is accessible on localhost:3000"

        # Check if HTTPS access is working
        if curl -ks https://grafana.vulcan.lan/api/health >/dev/null 2>&1; then
            print_success "Grafana HTTPS access working (grafana.vulcan.lan)"
        else
            print_warning "Grafana HTTPS access not working (check DNS/certificates)"
        fi
    else
        print_error "Grafana not accessible on localhost:3000"
    fi

    print_header "Summary"
    echo "Health check completed. Check the output above for any issues."
    echo "For detailed monitoring, visit:"
    echo "  - Prometheus: http://localhost:9090"
    echo "  - Grafana: http://localhost:3000 or https://grafana.vulcan.lan"
    echo "  - Blackbox Exporter: http://localhost:9115"
    echo ""
    echo "Useful commands:"
    echo "  - blackbox-probe <module> <target>: Manual probe testing"
}

# Run the health check
main "$@"