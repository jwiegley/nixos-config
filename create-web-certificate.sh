#!/usr/bin/env bash

# Script to create, sign and verify a web certificate using step-ca private CA
# Usage: ./create-web-certificate.sh <domain> [output-dir] [additional-sans...]

set -euo pipefail

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# CA paths - using step-ca-state which appears to be the active CA
CA_DIR="/var/lib/step-ca-state"
CA_CERTS_DIR="$CA_DIR/certs"
CA_SECRETS_DIR="$CA_DIR/secrets"

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <domain> [output-dir] [additional-sans...]"
    echo ""
    echo "Creates a TLS certificate for the specified domain using step-ca"
    echo ""
    echo "Arguments:"
    echo "  domain         - Primary domain name (e.g., example.com)"
    echo "  output-dir     - Directory to save certificates (default: current directory)"
    echo "  additional-sans - Additional Subject Alternative Names"
    echo ""
    echo "Examples:"
    echo "  $0 example.com"
    echo "  $0 example.com /etc/nginx/certs"
    echo "  $0 example.com . www.example.com api.example.com"
    echo ""
    exit 1
fi

DOMAIN="$1"
OUTPUT_DIR="${2:-.}"
shift 2 2>/dev/null || shift 1

# Additional SANs from remaining arguments
ADDITIONAL_SANS=("$@")

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# File paths
KEY_FILE="$OUTPUT_DIR/${DOMAIN}.key"
CERT_FILE="$OUTPUT_DIR/${DOMAIN}.crt"
CHAIN_FILE="$OUTPUT_DIR/${DOMAIN}.chain.crt"
FULLCHAIN_FILE="$OUTPUT_DIR/${DOMAIN}.fullchain.crt"
CSR_FILE="/tmp/${DOMAIN}.csr"

echo -e "${GREEN}=== Creating TLS Certificate for $DOMAIN ===${NC}"
echo "Output directory: $OUTPUT_DIR"

# Step 1: Generate private key
echo -e "\n${YELLOW}Step 1: Generating private key...${NC}"
if [ -f "$KEY_FILE" ]; then
    echo -e "${YELLOW}  Warning: Key file already exists. Backing up...${NC}"
    cp "$KEY_FILE" "${KEY_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
fi

openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null || {
    echo -e "${RED}Error: Failed to generate private key${NC}"
    exit 1
}
chmod 600 "$KEY_FILE"
echo "  ✓ Private key generated: $KEY_FILE"

# Step 2: Create CSR with SANs
echo -e "\n${YELLOW}Step 2: Creating Certificate Signing Request...${NC}"

# Build the SAN list
SAN_LIST="DNS:${DOMAIN}"
for san in "${ADDITIONAL_SANS[@]}"; do
    if [ -n "$san" ]; then
        # Check if it's an IP address
        if [[ $san =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            SAN_LIST="${SAN_LIST},IP:${san}"
        else
            SAN_LIST="${SAN_LIST},DNS:${san}"
        fi
    fi
done
echo "  Subject Alternative Names: $SAN_LIST"

# Create CSR config
cat > "${CSR_FILE}.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = ${SAN_LIST}
EOF

# Generate CSR
openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" \
    -subj "/CN=${DOMAIN}" \
    -config "${CSR_FILE}.conf" || {
    echo -e "${RED}Error: Failed to create CSR${NC}"
    exit 1
}
echo "  ✓ CSR created"

# Step 3: Sign the certificate with step-ca private CA
echo -e "\n${YELLOW}Step 3: Signing certificate with private CA...${NC}"
echo "  CA Directory: $CA_DIR"

# Check which CA certificates are available
if [ -f "$CA_CERTS_DIR/intermediate_ca.crt" ] && [ -f "$CA_SECRETS_DIR/intermediate_ca_key" ]; then
    CA_CERT="$CA_CERTS_DIR/intermediate_ca.crt"
    CA_KEY="$CA_SECRETS_DIR/intermediate_ca_key"
    ROOT_CA="$CA_CERTS_DIR/root_ca.crt"
    echo -e "  ${GREEN}✓${NC} Using intermediate CA for signing"
    USING_INTERMEDIATE=true
elif [ -f "$CA_CERTS_DIR/root_ca.crt" ] && [ -f "$CA_SECRETS_DIR/root_ca_key" ]; then
    CA_CERT="$CA_CERTS_DIR/root_ca.crt"
    CA_KEY="$CA_SECRETS_DIR/root_ca_key"
    ROOT_CA="$CA_CERTS_DIR/root_ca.crt"
    echo -e "  ${YELLOW}⚠${NC} Using root CA for signing (no intermediate CA found)"
    USING_INTERMEDIATE=false
else
    echo -e "${RED}Error: No CA certificates found in $CA_CERTS_DIR${NC}"
    echo "Please ensure step-ca is properly initialized"
    exit 1
fi

# Display CA details
echo -e "\n${CYAN}CA Certificate Details:${NC}"
echo "  Issuer:"
openssl x509 -in "$CA_CERT" -noout -issuer | sed 's/^/    /'
echo "  Subject:"
openssl x509 -in "$CA_CERT" -noout -subject | sed 's/^/    /'
echo "  Valid Until:"
openssl x509 -in "$CA_CERT" -noout -enddate | sed 's/^/    /'

# Sign the certificate
sudo step certificate sign "$CSR_FILE" "$CA_CERT" "$CA_KEY" \
    --profile leaf \
    --not-after 8760h \
    --bundle \
    > "$CERT_FILE" || {
    echo -e "${RED}Error: Failed to sign certificate${NC}"
    exit 1
}
echo "  ✓ Certificate signed successfully"

# Step 4: Create certificate chain files
echo -e "\n${YELLOW}Step 4: Creating certificate chain files...${NC}"

# Extract just the certificate (first certificate in the bundle)
openssl x509 -in "$CERT_FILE" -out "$CERT_FILE.tmp"
mv "$CERT_FILE.tmp" "$CERT_FILE"

# Create chain file (intermediate + root)
if [ "$USING_INTERMEDIATE" = true ]; then
    cat "$CA_CERTS_DIR/intermediate_ca.crt" \
        "$ROOT_CA" \
        > "$CHAIN_FILE"
    echo -e "  ${GREEN}✓${NC} Chain file created with intermediate + root CA"
else
    cp "$ROOT_CA" "$CHAIN_FILE"
    echo -e "  ${GREEN}✓${NC} Chain file created with root CA only"
fi

# Create fullchain file (cert + intermediate + root)
cat "$CERT_FILE" "$CHAIN_FILE" > "$FULLCHAIN_FILE"
echo -e "  ${GREEN}✓${NC} Fullchain file created: $FULLCHAIN_FILE"

# Show chain structure
echo -e "\n${CYAN}Certificate Chain Structure:${NC}"
echo "  1. Leaf Certificate: $DOMAIN"
if [ "$USING_INTERMEDIATE" = true ]; then
    echo "  2. Intermediate CA"
    echo "  3. Root CA"
else
    echo "  2. Root CA"
fi

# Step 5: Comprehensive Certificate Verification
echo -e "\n${YELLOW}Step 5: Performing comprehensive certificate verification...${NC}"

# Verify certificate chain
echo -e "\n${CYAN}Chain Verification:${NC}"
echo -n "  Certificate chain integrity: "

if [ "$USING_INTERMEDIATE" = true ]; then
    VERIFY_OUTPUT=$(openssl verify -CAfile "$ROOT_CA" -untrusted "$CA_CERTS_DIR/intermediate_ca.crt" "$CERT_FILE" 2>&1)
else
    VERIFY_OUTPUT=$(openssl verify -CAfile "$ROOT_CA" "$CERT_FILE" 2>&1)
fi

if echo "$VERIFY_OUTPUT" | grep -q "OK"; then
    echo -e "${GREEN}✓ VALID${NC}"
    echo -e "  ${GREEN}✓${NC} Certificate successfully chains to root CA"
else
    echo -e "${RED}✗ FAILED${NC}"
    echo -e "  ${RED}Error output:${NC}"
    echo "$VERIFY_OUTPUT" | sed 's/^/    /'
    echo -e "${RED}  Warning: Certificate chain verification failed!${NC}"
fi

# Test that the certificate matches the private key
echo -n "  Certificate/Key match: "
CERT_MODULUS=$(openssl x509 -in "$CERT_FILE" -noout -modulus | md5sum)
KEY_MODULUS=$(openssl rsa -in "$KEY_FILE" -noout -modulus 2>/dev/null | md5sum)
if [ "$CERT_MODULUS" = "$KEY_MODULUS" ]; then
    echo -e "${GREEN}✓ MATCH${NC}"
else
    echo -e "${RED}✗ MISMATCH${NC}"
    echo -e "${RED}  Error: Certificate and private key do not match!${NC}"
fi

# Show complete certificate details
echo -e "\n${GREEN}=== Complete Certificate Details ===${NC}"

echo -e "\n${MAGENTA}Basic Information:${NC}"
echo "Subject:"
openssl x509 -in "$CERT_FILE" -noout -subject | sed 's/subject=/  /'

echo "Issuer:"
openssl x509 -in "$CERT_FILE" -noout -issuer | sed 's/issuer=/  /'

echo "Serial Number:"
openssl x509 -in "$CERT_FILE" -noout -serial | sed 's/serial=/  /'

echo -e "\n${MAGENTA}Validity Period:${NC}"
STARTDATE=$(openssl x509 -in "$CERT_FILE" -noout -startdate | sed 's/notBefore=//')
ENDDATE=$(openssl x509 -in "$CERT_FILE" -noout -enddate | sed 's/notAfter=//')
echo "  Not Before: $STARTDATE"
echo "  Not After:  $ENDDATE"

# Calculate days until expiry
ENDDATE_EPOCH=$(date -d "$ENDDATE" +%s)
NOW_EPOCH=$(date +%s)
DAYS_LEFT=$(( ($ENDDATE_EPOCH - $NOW_EPOCH) / 86400 ))
echo "  Days until expiry: $DAYS_LEFT"

echo -e "\n${MAGENTA}Subject Alternative Names:${NC}"
SANS=$(openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3 Subject Alternative Name:" | sed 's/^ *//')
if [ -n "$SANS" ]; then
    echo "$SANS" | sed 's/^/  /'
else
    echo "  None"
fi

echo -e "\n${MAGENTA}Key Usage:${NC}"
openssl x509 -in "$CERT_FILE" -noout -ext keyUsage | grep -v "X509v3 Key Usage:" | sed 's/^ */  /'

echo -e "\n${MAGENTA}Extended Key Usage:${NC}"
openssl x509 -in "$CERT_FILE" -noout -ext extendedKeyUsage | grep -v "X509v3 Extended Key Usage:" | sed 's/^ */  /'

echo -e "\n${MAGENTA}Signature Algorithm:${NC}"
openssl x509 -in "$CERT_FILE" -noout -text | grep "Signature Algorithm" | head -1 | sed 's/^ */  /'

echo -e "\n${MAGENTA}Public Key Info:${NC}"
openssl x509 -in "$CERT_FILE" -noout -text | grep -A 2 "Public Key Algorithm" | sed 's/^ */  /'

echo -e "\n${MAGENTA}Fingerprints:${NC}"
echo -n "  SHA1:   "
openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha1 | cut -d= -f2
echo -n "  SHA256: "
openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | cut -d= -f2

# Verify each certificate in the chain
echo -e "\n${CYAN}Full Chain Validation:${NC}"
echo "Verifying each certificate in the chain..."

# Verify leaf certificate
echo -e "\n  ${BLUE}[1] Leaf Certificate ($DOMAIN):${NC}"
openssl x509 -in "$CERT_FILE" -noout -subject | sed 's/^/      /'
openssl x509 -in "$CERT_FILE" -noout -issuer | sed 's/^/      /'

if [ "$USING_INTERMEDIATE" = true ]; then
    # Verify intermediate
    echo -e "\n  ${BLUE}[2] Intermediate CA:${NC}"
    openssl x509 -in "$CA_CERTS_DIR/intermediate_ca.crt" -noout -subject | sed 's/^/      /'
    openssl x509 -in "$CA_CERTS_DIR/intermediate_ca.crt" -noout -issuer | sed 's/^/      /'

    # Verify intermediate against root
    echo -n "      Verification: "
    if openssl verify -CAfile "$ROOT_CA" "$CA_CERTS_DIR/intermediate_ca.crt" 2>/dev/null | grep -q "OK"; then
        echo -e "${GREEN}✓ Valid${NC}"
    else
        echo -e "${RED}✗ Invalid${NC}"
    fi

    echo -e "\n  ${BLUE}[3] Root CA:${NC}"
else
    echo -e "\n  ${BLUE}[2] Root CA:${NC}"
fi

openssl x509 -in "$ROOT_CA" -noout -subject | sed 's/^/      /'
openssl x509 -in "$ROOT_CA" -noout -issuer | sed 's/^/      /'
echo -n "      Self-signed: "
ROOT_SUBJECT=$(openssl x509 -in "$ROOT_CA" -noout -subject)
ROOT_ISSUER=$(openssl x509 -in "$ROOT_CA" -noout -issuer)
if [ "$ROOT_SUBJECT" = "$ROOT_ISSUER" ]; then
    echo -e "${GREEN}✓ Yes${NC}"
else
    echo -e "${RED}✗ No${NC}"
fi

# Set proper permissions
chmod 644 "$CERT_FILE" "$CHAIN_FILE" "$FULLCHAIN_FILE"

# Final Summary
echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}                    CERTIFICATE GENERATION COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${CYAN}Verification Summary:${NC}"
echo -n "  • Certificate chain: "
if echo "$VERIFY_OUTPUT" | grep -q "OK"; then
    echo -e "${GREEN}✓ VALID${NC}"
else
    echo -e "${RED}✗ INVALID${NC}"
fi

echo -n "  • Certificate/Key match: "
if [ "$CERT_MODULUS" = "$KEY_MODULUS" ]; then
    echo -e "${GREEN}✓ MATCH${NC}"
else
    echo -e "${RED}✗ MISMATCH${NC}"
fi

echo "  • Days until expiry: ${DAYS_LEFT} days"
echo "  • Signed by: $(basename "$CA_CERT" .crt | sed 's/_/ /g')"

echo -e "\n${CYAN}Generated Files:${NC}"
echo "  ${BLUE}Private Key:${NC}  $KEY_FILE ${RED}(KEEP SECRET!)${NC}"
echo "  ${BLUE}Certificate:${NC}  $CERT_FILE"
echo "  ${BLUE}CA Chain:${NC}     $CHAIN_FILE"
echo "  ${BLUE}Full Chain:${NC}   $FULLCHAIN_FILE"

echo -e "\n${CYAN}Configuration Examples:${NC}"
echo ""
echo "  ${MAGENTA}For nginx:${NC}"
echo "    ssl_certificate     $FULLCHAIN_FILE;"
echo "    ssl_certificate_key $KEY_FILE;"
echo ""
echo "  ${MAGENTA}For Apache:${NC}"
echo "    SSLCertificateFile    $CERT_FILE"
echo "    SSLCertificateKeyFile $KEY_FILE"
echo "    SSLCertificateChainFile $CHAIN_FILE"
echo ""
echo "  ${MAGENTA}For HAProxy:${NC}"
echo "    cat $FULLCHAIN_FILE $KEY_FILE > haproxy.pem"
echo ""
echo "  ${MAGENTA}To verify manually:${NC}"
echo "    openssl verify -CAfile $ROOT_CA $CERT_FILE"
echo ""
echo "  ${MAGENTA}To test with curl:${NC}"
echo "    curl --cacert $ROOT_CA https://$DOMAIN"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Cleanup temp files
rm -f "$CSR_FILE" "${CSR_FILE}.conf"