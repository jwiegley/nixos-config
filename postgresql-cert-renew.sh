#!/usr/bin/env bash

# Script to generate/renew PostgreSQL SSL certificate using step-ca
# This script is called by systemd services for initial setup and renewal

set -euo pipefail

# Configuration
DOMAIN="postgresql.vulcan.lan"
POSTGRES_VERSION="16"
POSTGRES_DATA="/var/lib/postgresql/${POSTGRES_VERSION}"
CA_ROOT="/var/lib/step-ca-state/certs/root_ca.crt"
CERT_VALIDITY="720h"  # 30 days

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== PostgreSQL Certificate Management ===${NC}"
echo "Domain: $DOMAIN"
echo "PostgreSQL data directory: $POSTGRES_DATA"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Check if step-ca is available
if ! systemctl is-active --quiet step-ca; then
    echo -e "${YELLOW}Warning: step-ca service is not active. Starting it...${NC}"
    systemctl start step-ca
    sleep 2
fi

# Ensure PostgreSQL data directory exists
if [ ! -d "$POSTGRES_DATA" ]; then
    echo -e "${RED}Error: PostgreSQL data directory not found: $POSTGRES_DATA${NC}"
    echo "PostgreSQL may not be initialized yet."
    exit 1
fi

# Create temporary directory for certificate generation
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "\n${YELLOW}Step 1: Generating private key...${NC}"
openssl genrsa -out "$TEMP_DIR/server.key" 2048 2>/dev/null || {
    echo -e "${RED}Error: Failed to generate private key${NC}"
    exit 1
}
echo "  ✓ Private key generated"

echo -e "\n${YELLOW}Step 2: Creating Certificate Signing Request...${NC}"

# Build SAN list for PostgreSQL
# Include the main domain, localhost, and IP addresses
SAN_LIST="DNS:${DOMAIN},DNS:vulcan,DNS:vulcan.lan,DNS:localhost,IP:127.0.0.1,IP:192.168.1.10"

# Add Tailscale IP if available
if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    TAILSCALE_IP=$(ip addr show tailscale0 | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$TAILSCALE_IP" ]; then
        SAN_LIST="${SAN_LIST},IP:${TAILSCALE_IP}"
        echo "  Including Tailscale IP: $TAILSCALE_IP"
    fi
fi

echo "  SANs: $SAN_LIST"

# Create CSR config
cat > "${TEMP_DIR}/csr.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${SAN_LIST}
EOF

# Create CSR
openssl req -new -key "$TEMP_DIR/server.key" -out "$TEMP_DIR/server.csr" \
    -subj "/CN=${DOMAIN}/O=Vulcan PostgreSQL/C=US" \
    -config "${TEMP_DIR}/csr.conf" || {
    echo -e "${RED}Error: Failed to create CSR${NC}"
    exit 1
}
echo "  ✓ CSR created"

echo -e "\n${YELLOW}Step 3: Signing certificate with step-ca...${NC}"

# Check if intermediate CA exists and use it, otherwise use root CA
if [ -f /var/lib/step-ca-state/certs/intermediate_ca.crt ] && [ -f /var/lib/step-ca-state/secrets/intermediate_ca_key ]; then
    echo "  Using intermediate CA for signing..."
    step certificate sign "$TEMP_DIR/server.csr" \
        /var/lib/step-ca-state/certs/intermediate_ca.crt \
        /var/lib/step-ca-state/secrets/intermediate_ca_key \
        --profile leaf \
        --not-after "$CERT_VALIDITY" \
        --bundle \
        > "$TEMP_DIR/server.crt" || {
        echo -e "${RED}Error: Failed to sign certificate${NC}"
        exit 1
    }
else
    echo -e "${RED}Error: CA certificates not found${NC}"
    echo "Please ensure step-ca is properly initialized"
    exit 1
fi
echo "  ✓ Certificate signed (valid for $CERT_VALIDITY)"

echo -e "\n${YELLOW}Step 4: Installing certificates...${NC}"

# Backup existing certificates if they exist
if [ -f "$POSTGRES_DATA/server.crt" ]; then
    echo "  Backing up existing certificates..."
    cp "$POSTGRES_DATA/server.crt" "$POSTGRES_DATA/server.crt.bak.$(date +%Y%m%d-%H%M%S)"
    [ -f "$POSTGRES_DATA/server.key" ] && cp "$POSTGRES_DATA/server.key" "$POSTGRES_DATA/server.key.bak.$(date +%Y%m%d-%H%M%S)"
fi

# Install new certificate and key
cp "$TEMP_DIR/server.crt" "$POSTGRES_DATA/server.crt"
cp "$TEMP_DIR/server.key" "$POSTGRES_DATA/server.key"

# Copy root CA certificate for client certificate validation
cp "$CA_ROOT" "$POSTGRES_DATA/root_ca.crt"

# Set proper ownership and permissions
chown postgres:postgres "$POSTGRES_DATA/server.crt" "$POSTGRES_DATA/server.key" "$POSTGRES_DATA/root_ca.crt"
chmod 644 "$POSTGRES_DATA/server.crt" "$POSTGRES_DATA/root_ca.crt"
chmod 600 "$POSTGRES_DATA/server.key"

echo "  ✓ Certificates installed to $POSTGRES_DATA"

echo -e "\n${YELLOW}Step 5: Verifying certificate...${NC}"

# Verify certificate chain
echo -n "  Certificate chain verification: "
if openssl verify -CAfile "$CA_ROOT" "$POSTGRES_DATA/server.crt" 2>/dev/null | grep -q "OK"; then
    echo -e "${GREEN}✓ VALID${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    echo "  Warning: Certificate chain verification failed!"
fi

# Show certificate details
echo ""
echo "Certificate details:"
openssl x509 -in "$POSTGRES_DATA/server.crt" -noout -subject | sed 's/^/  /'
openssl x509 -in "$POSTGRES_DATA/server.crt" -noout -startdate | sed 's/^/  /'
openssl x509 -in "$POSTGRES_DATA/server.crt" -noout -enddate | sed 's/^/  /'

# Check if PostgreSQL is running and needs reload
if systemctl is-active --quiet postgresql; then
    echo -e "\n${YELLOW}Step 6: Reloading PostgreSQL configuration...${NC}"
    # Note: The reload will be handled by the systemd service
    echo "  PostgreSQL reload will be triggered by systemd"
else
    echo -e "\n${YELLOW}PostgreSQL is not running. Certificates will be used on next start.${NC}"
fi

echo -e "\n${GREEN}=== Certificate management completed successfully ===${NC}"
echo ""
echo "To test the SSL connection:"
echo "  psql \"postgresql://username@192.168.1.10:5432/dbname?sslmode=require\""
echo ""
echo "To view certificate info from PostgreSQL:"
echo "  psql -c \"SELECT name, setting FROM pg_settings WHERE name LIKE 'ssl%';\""