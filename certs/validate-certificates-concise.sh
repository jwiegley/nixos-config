#!/usr/bin/env bash

set -euo pipefail

# Configuration
NGINX_CERT_DIR="/var/lib/nginx-certs"
STEP_CA_DIR="/var/lib/step-ca-state/certs"
POSTGRESQL_CERT_DIR="/var/lib/postgresql/certs"
WARNING_DAYS=30
CRITICAL_DAYS=7

# Initialize counters
total_certs=0
expired_certs=0
critical_certs=0
warning_certs=0
ok_certs=0
declare -a attention_required=()

# Function to check certificate expiration
check_certificate_status() {
    local cert_path="$1"
    local cert_name="$2"

    if [[ ! -f "$cert_path" ]]; then
        attention_required+=("✗ $cert_name: FILE NOT FOUND")
        return 1
    fi

    # Check if certificate is valid
    openssl x509 -in "$cert_path" -noout -checkend 0 >/dev/null 2>&1
    local is_valid=$?

    # Calculate days until expiration
    local end_date=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    local end_epoch=$(date -d "$end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$end_date" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    local days_remaining=$(( (end_epoch - now_epoch) / 86400 ))

    total_certs=$((total_certs + 1))

    if [[ $is_valid -ne 0 ]]; then
        expired_certs=$((expired_certs + 1))
        attention_required+=("✗ $cert_name: EXPIRED")
    elif [[ $days_remaining -le $CRITICAL_DAYS ]]; then
        critical_certs=$((critical_certs + 1))
        attention_required+=("✗ $cert_name: expires in $days_remaining days")
    elif [[ $days_remaining -le $WARNING_DAYS ]]; then
        warning_certs=$((warning_certs + 1))
        attention_required+=("⚠ $cert_name: expires in $days_remaining days")
    else
        ok_certs=$((ok_certs + 1))
    fi
}

# Check all certificates
for cert_file in "$NGINX_CERT_DIR"/*.crt "$STEP_CA_DIR"/*.crt "$POSTGRESQL_CERT_DIR"/*.crt; do
    if [[ ! -f "$cert_file" ]]; then
        continue
    fi

    cert_name=$(basename "$cert_file" .crt)
    # Skip chain files
    if [[ "$cert_name" == *"chain"* || "$cert_name" == *"fullchain"* ]]; then
        continue
    fi

    # Determine certificate location for display
    if [[ "$cert_file" == *"nginx-certs"* ]]; then
        display_name="nginx/$cert_name"
    elif [[ "$cert_file" == *"step-ca"* ]]; then
        display_name="ca/$cert_name"
    elif [[ "$cert_file" == *"postgresql"* ]]; then
        display_name="postgres/$cert_name"
    else
        display_name="$cert_name"
    fi

    check_certificate_status "$cert_file" "$display_name"
done

# Output concise report
echo "Certificate Status Summary:"
echo "  ✓ Valid: $ok_certs certificates"
if [[ $warning_certs -gt 0 ]]; then
    echo "  ⚠ Warning (${WARNING_DAYS}d): $warning_certs certificates"
fi
if [[ $critical_certs -gt 0 ]]; then
    echo "  ✗ Critical (<${CRITICAL_DAYS}d): $critical_certs certificates"
fi
if [[ $expired_certs -gt 0 ]]; then
    echo "  ✗ Expired: $expired_certs certificates"
fi

# Only show attention required section if there are issues
if [[ ${#attention_required[@]} -gt 0 ]]; then
    echo ""
    echo "Attention Required:"
    for item in "${attention_required[@]}"; do
        echo "  $item"
    done
fi

# Exit with appropriate code
if [[ $expired_certs -gt 0 || $critical_certs -gt 0 ]]; then
    exit 2
elif [[ $warning_certs -gt 0 ]]; then
    exit 1
else
    exit 0
fi
