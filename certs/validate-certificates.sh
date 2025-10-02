#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NGINX_CERT_DIR="/var/lib/nginx-certs"
STEP_CA_DIR="/var/lib/step-ca-state/certs"
POSTGRESQL_CERT_DIR="/var/lib/postgresql/certs"
WARNING_DAYS=30  # Warn if certificate expires within this many days
CRITICAL_DAYS=7   # Critical if certificate expires within this many days

echo "=========================================="
echo "     Certificate Validation Report        "
echo "=========================================="
echo ""
echo "Checking certificates on $(date)"
echo "Warning threshold: ${WARNING_DAYS} days"
echo "Critical threshold: ${CRITICAL_DAYS} days"
echo ""

# Function to check certificate validity and expiration
check_certificate() {
    local cert_path="$1"
    local cert_name="$2"
    local cert_type="${3:-Service}"

    if [[ ! -f "$cert_path" ]]; then
        echo -e "${RED}✗ $cert_name ($cert_type)${NC}"
        echo "  Status: FILE NOT FOUND"
        return 1
    fi

    # Get certificate details
    local subject=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/subject=//')
    local issuer=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/issuer=//')
    local start_date=$(openssl x509 -in "$cert_path" -noout -startdate 2>/dev/null | cut -d= -f2)
    local end_date=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)

    # Check if certificate is valid
    openssl x509 -in "$cert_path" -noout -checkend 0 >/dev/null 2>&1
    local is_valid=$?

    # Calculate days until expiration
    local end_epoch=$(date -d "$end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$end_date" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    local days_remaining=$(( (end_epoch - now_epoch) / 86400 ))

    # Determine status
    local status_color=""
    local status_text=""
    if [[ $is_valid -ne 0 ]]; then
        status_color=$RED
        status_text="EXPIRED"
    elif [[ $days_remaining -le $CRITICAL_DAYS ]]; then
        status_color=$RED
        status_text="CRITICAL (expires in $days_remaining days)"
    elif [[ $days_remaining -le $WARNING_DAYS ]]; then
        status_color=$YELLOW
        status_text="WARNING (expires in $days_remaining days)"
    else
        status_color=$GREEN
        status_text="OK (expires in $days_remaining days)"
    fi

    # Display results
    echo -e "${status_color}● $cert_name ($cert_type)${NC}"
    echo "  Status: $status_text"
    echo "  Path: $cert_path"
    echo "  Subject: $subject"
    echo "  Issuer: $issuer"
    echo "  Valid from: $start_date"
    echo "  Valid until: $end_date"

    # Check certificate chain
    if [[ "$cert_type" != "CA" ]]; then
        # Check if certificate file contains the full chain (multiple certificates)
        local cert_count=$(grep -c "BEGIN CERTIFICATE" "$cert_path")
        if [[ $cert_count -gt 1 ]]; then
            echo "  Chain: Fullchain included ($cert_count certificates in file)"
        else
            echo -e "  Chain: ${YELLOW}Warning - Only server certificate present (missing intermediate)${NC}"
        fi

        # Verify certificate chain if CA certificates exist
        if [[ -f "$STEP_CA_DIR/intermediate_ca.crt" ]]; then
            openssl verify -CAfile "$STEP_CA_DIR/root_ca.crt" -untrusted "$STEP_CA_DIR/intermediate_ca.crt" "$cert_path" >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                echo "  Verification: Valid (verified against local CA)"
            else
                echo -e "  Verification: ${YELLOW}Could not verify against CA${NC}"
            fi
        fi
    fi

    # Check key file if it exists
    local key_path="${cert_path%.crt}.key"
    if [[ -f "$key_path" ]]; then
        # Verify certificate and key match
        local cert_modulus=$(openssl x509 -in "$cert_path" -noout -modulus 2>/dev/null | md5sum | cut -d' ' -f1)
        local key_modulus=$(openssl rsa -in "$key_path" -noout -modulus 2>/dev/null | md5sum | cut -d' ' -f1)

        if [[ "$cert_modulus" == "$key_modulus" ]]; then
            echo "  Key: Present and matches certificate"
        else
            echo -e "  Key: ${RED}Key does not match certificate!${NC}"
        fi
    else
        echo "  Key: Not found (expected at $key_path)"
    fi

    echo ""
}

# Function to check certificate connectivity
check_tls_endpoint() {
    local hostname="$1"
    local port="${2:-443}"

    echo -e "${BLUE}Checking TLS endpoint: $hostname:$port${NC}"

    # Try to connect and get certificate
    timeout 3 openssl s_client -connect "$hostname:$port" -servername "$hostname" </dev/null 2>/dev/null | \
        openssl x509 -noout -dates 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}✓ TLS connection successful${NC}"
    else
        echo -e "  ${YELLOW}⚠ Could not establish TLS connection${NC}"
    fi
    echo ""
}

# Check Certificate Authority certificates
echo -e "${BLUE}=== Certificate Authority ===${NC}"
echo ""
check_certificate "$STEP_CA_DIR/root_ca.crt" "Root CA" "CA"
check_certificate "$STEP_CA_DIR/intermediate_ca.crt" "Intermediate CA" "CA"

# Check Nginx service certificates
echo -e "${BLUE}=== Nginx Service Certificates ===${NC}"
echo ""

for cert_file in "$NGINX_CERT_DIR"/*.crt; do
    if [[ -f "$cert_file" ]]; then
        cert_name=$(basename "$cert_file" .crt)
        # Skip chain files
        if [[ "$cert_name" == *"chain"* || "$cert_name" == *"fullchain"* ]]; then
            continue
        fi
        check_certificate "$cert_file" "$cert_name" "Nginx"
    fi
done

# Check PostgreSQL certificates
echo -e "${BLUE}=== PostgreSQL Service Certificates ===${NC}"
echo ""

if [[ -d "$POSTGRESQL_CERT_DIR" ]]; then
    # Check server certificate
    check_certificate "$POSTGRESQL_CERT_DIR/server.crt" "PostgreSQL Server" "PostgreSQL"

    # Check for CRL if exists
    if [[ -f "$POSTGRESQL_CERT_DIR/crl.pem" ]]; then
        echo -e "${BLUE}Certificate Revocation List (CRL):${NC}"
        # Check if CRL is valid
        if openssl crl -in "$POSTGRESQL_CERT_DIR/crl.pem" -noout 2>/dev/null; then
            crl_lastupdate=$(openssl crl -in "$POSTGRESQL_CERT_DIR/crl.pem" -noout -lastupdate 2>/dev/null | cut -d= -f2)
            crl_nextupdate=$(openssl crl -in "$POSTGRESQL_CERT_DIR/crl.pem" -noout -nextupdate 2>/dev/null | cut -d= -f2)
            echo "  Status: Valid"
            echo "  Last Update: $crl_lastupdate"
            echo "  Next Update: $crl_nextupdate"
        else
            echo -e "  Status: ${YELLOW}Invalid or unreadable CRL${NC}"
        fi
        echo ""
    fi

    # Check for client certificates if any exist
    for cert_file in "$POSTGRESQL_CERT_DIR"/*.crt; do
        if [[ -f "$cert_file" ]]; then
            cert_name=$(basename "$cert_file" .crt)
            # Skip server certificate and chain files
            if [[ "$cert_name" != "server" && "$cert_name" != *"chain"* && "$cert_name" != *"ca"* ]]; then
                check_certificate "$cert_file" "PostgreSQL Client: $cert_name" "PostgreSQL"
            fi
        fi
    done
else
    echo -e "${YELLOW}PostgreSQL certificate directory not found at $POSTGRESQL_CERT_DIR${NC}"
    echo ""
fi

# Check live endpoints (optional)
echo -e "${BLUE}=== Live Endpoint Checks ===${NC}"
echo ""
echo "Checking local services (this may take a moment)..."
echo ""

# Check step-ca endpoint
check_tls_endpoint "localhost" "8443"

# Check PostgreSQL endpoint (if running and accessible)
echo -e "${BLUE}Checking PostgreSQL TLS endpoint${NC}"
if systemctl is-active postgresql >/dev/null 2>&1; then
    # PostgreSQL listens on multiple addresses, check the primary one
    timeout 3 openssl s_client -connect "localhost:5432" -starttls postgres </dev/null 2>/dev/null | \
        openssl x509 -noout -dates 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}✓ PostgreSQL TLS connection successful${NC}"
    else
        # Try without STARTTLS for direct SSL connections
        timeout 3 openssl s_client -connect "localhost:5432" </dev/null 2>/dev/null | \
            openssl x509 -noout -dates 2>/dev/null

        if [[ $? -eq 0 ]]; then
            echo -e "  ${GREEN}✓ PostgreSQL TLS connection successful (direct SSL)${NC}"
        else
            echo -e "  ${YELLOW}⚠ Could not establish TLS connection to PostgreSQL${NC}"
            echo "    Note: This might be normal if PostgreSQL requires client certificates"
        fi
    fi
else
    echo -e "  ${YELLOW}⚠ PostgreSQL service is not running${NC}"
fi
echo ""


# Check common service endpoints
for domain in jellyfin.vulcan.lan litellm.vulcan.lan organizr.vulcan.lan postgres.vulcan.lan wallabag.vulcan.lan dns.vulcan.lan; do
    # Check if domain resolves
    if nslookup "$domain" >/dev/null 2>&1; then
        check_tls_endpoint "$domain" "443"
    else
        echo -e "${YELLOW}Skipping $domain (does not resolve)${NC}"
        echo ""
    fi
done

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo ""

# Count certificates by status
total_certs=0
expired_certs=0
critical_certs=0
warning_certs=0
ok_certs=0

for cert_file in "$NGINX_CERT_DIR"/*.crt "$STEP_CA_DIR"/*.crt "$POSTGRESQL_CERT_DIR"/*.crt; do
    if [[ ! -f "$cert_file" ]]; then
        continue
    fi

    cert_name=$(basename "$cert_file" .crt)
    if [[ "$cert_name" == *"chain"* || "$cert_name" == *"fullchain"* ]]; then
        continue
    fi

    total_certs=$((total_certs + 1))

    # Check expiration
    openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        expired_certs=$((expired_certs + 1))
    elif openssl x509 -in "$cert_file" -noout -checkend $((CRITICAL_DAYS * 86400)) >/dev/null 2>&1; then
        if openssl x509 -in "$cert_file" -noout -checkend $((WARNING_DAYS * 86400)) >/dev/null 2>&1; then
            ok_certs=$((ok_certs + 1))
        else
            warning_certs=$((warning_certs + 1))
        fi
    else
        critical_certs=$((critical_certs + 1))
    fi
done

echo "Total certificates checked: $total_certs"
echo -e "${GREEN}✓ Valid certificates: $ok_certs${NC}"
if [[ $warning_certs -gt 0 ]]; then
    echo -e "${YELLOW}⚠ Warning certificates: $warning_certs${NC}"
fi
if [[ $critical_certs -gt 0 ]]; then
    echo -e "${RED}✗ Critical certificates: $critical_certs${NC}"
fi
if [[ $expired_certs -gt 0 ]]; then
    echo -e "${RED}✗ Expired certificates: $expired_certs${NC}"
fi

echo ""
echo "=========================================="

# Exit with appropriate code
if [[ $expired_certs -gt 0 || $critical_certs -gt 0 ]]; then
    exit 2
elif [[ $warning_certs -gt 0 ]]; then
    exit 1
else
    exit 0
fi