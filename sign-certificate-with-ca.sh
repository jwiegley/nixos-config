#!/usr/bin/env bash

# Script to sign a certificate using step-ca root CA
# Usage: ./sign-certificate-with-ca.sh <input.p12> [output.p12] [new-cn]

set -euo pipefail

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <input.p12> [output.p12] [new-cn]"
    echo "Signs a certificate from a .p12 file with the step-ca root CA"
    echo ""
    echo "Arguments:"
    echo "  input.p12   - Input certificate file"
    echo "  output.p12  - Output file (default: input-signed.p12)"
    echo "  new-cn      - New Common Name (default: uses original CN)"
    echo ""
    echo "Examples:"
    echo "  $0 cert.p12                           # Keep original CN"
    echo "  $0 cert.p12 signed.p12                # Keep original CN, custom output"
    echo "  $0 cert.p12 signed.p12 router.lan     # Use new CN"
    exit 1
fi

INPUT_P12="$1"
OUTPUT_P12="${2:-${INPUT_P12%.p12}-signed.p12}"
NEW_CN="${3:-}"

# Check if input file exists
if [ ! -f "$INPUT_P12" ]; then
    echo "Error: Input file '$INPUT_P12' not found"
    exit 1
fi

# Create temporary directory for work
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "=== Signing certificate from $INPUT_P12 ==="

# Step 1: Extract private key and certificate from .p12
echo "Step 1: Extracting private key and certificate..."
openssl pkcs12 -in "$INPUT_P12" -nocerts -out "$TEMP_DIR/private.key" -nodes 2>/dev/null || {
    echo "Error: Failed to extract private key. Wrong password?"
    exit 1
}

openssl pkcs12 -in "$INPUT_P12" -clcerts -nokeys -out "$TEMP_DIR/original.crt" 2>/dev/null || {
    echo "Error: Failed to extract certificate"
    exit 1
}

# Get the CN from the original certificate
ORIGINAL_CN=$(openssl x509 -in "$TEMP_DIR/original.crt" -noout -subject | sed -n 's/.*CN=\([^,/]*\).*/\1/p')
if [ -z "$ORIGINAL_CN" ]; then
    echo "Error: Could not extract CN from certificate"
    exit 1
fi
echo "  Original CN: $ORIGINAL_CN"

# Use new CN if provided, otherwise use original
if [ -n "$NEW_CN" ]; then
    CN="$NEW_CN"
    echo "  New CN: $CN"
else
    CN="$ORIGINAL_CN"
fi

# Extract SANs from original certificate if present
echo "  Extracting SANs from original certificate..."
SANS=$(openssl x509 -in "$TEMP_DIR/original.crt" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3 Subject Alternative Name:" | sed 's/^ *//' | tr -d '\n' | sed 's/, /,/g')

# Step 2: Create CSR from the private key
echo "Step 2: Creating Certificate Signing Request..."

# Build the subject with the new CN
SUBJECT="/CN=$CN"

# Create a config file for the CSR with SANs
cat > "$TEMP_DIR/csr.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
EOF

# Add SANs to config if they exist
if [ -n "$SANS" ]; then
    echo "subjectAltName = $SANS" >> "$TEMP_DIR/csr.conf"
    echo "  Including SANs: $SANS"
fi

# Create CSR with the config
openssl req -new -key "$TEMP_DIR/private.key" -out "$TEMP_DIR/request.csr" \
    -subj "$SUBJECT" -config "$TEMP_DIR/csr.conf" || {
    echo "Error: Failed to create certificate signing request"
    exit 1
}

# Step 3: Sign the CSR with step-ca
echo "Step 3: Signing CSR with step-ca..."

# Check which CA certificates are available
if [ -f /var/lib/step-ca/certs/intermediate_ca.crt ] && [ -f /var/lib/step-ca/secrets/intermediate_ca_key ]; then
    # Use intermediate CA for signing
    echo "  Using intermediate CA for signing..."
    sudo step certificate sign "$TEMP_DIR/request.csr" \
        /var/lib/step-ca/certs/intermediate_ca.crt \
        /var/lib/step-ca/secrets/intermediate_ca_key \
        --profile leaf \
        --not-after 8760h \
        > "$TEMP_DIR/signed.crt" || {
        echo "Error: Failed to sign certificate with intermediate CA"
        exit 1
    }
elif [ -f /var/lib/step-ca/certs/root_ca.crt ] && [ -f /var/lib/step-ca/secrets/root_ca_key ]; then
    # Use root CA for signing (not recommended for production)
    echo "  Using root CA for signing (no intermediate CA found)..."
    sudo step certificate sign "$TEMP_DIR/request.csr" \
        /var/lib/step-ca/certs/root_ca.crt \
        /var/lib/step-ca/secrets/root_ca_key \
        --profile leaf \
        --not-after 8760h \
        > "$TEMP_DIR/signed.crt" || {
        echo "Error: Failed to sign certificate with root CA"
        exit 1
    }
else
    echo "Error: No CA certificates found in /var/lib/step-ca/certs/"
    echo "Please ensure step-ca is properly initialized"
    exit 1
fi

# Step 4: Create certificate chain
echo "Step 4: Creating certificate chain..."
cat "$TEMP_DIR/signed.crt" > "$TEMP_DIR/fullchain.crt"

# Add intermediate CA if it exists
if [ -f /var/lib/step-ca/certs/intermediate_ca.crt ]; then
    cat /var/lib/step-ca/certs/intermediate_ca.crt >> "$TEMP_DIR/fullchain.crt"
fi

# Add root CA
cat /var/lib/step-ca/certs/root_ca.crt >> "$TEMP_DIR/fullchain.crt"

# Step 5: Create new .p12 file
echo "Step 5: Creating signed .p12 file..."
echo "Enter a password for the new .p12 file:"
openssl pkcs12 -export \
    -out "$OUTPUT_P12" \
    -inkey "$TEMP_DIR/private.key" \
    -in "$TEMP_DIR/signed.crt" \
    -certfile "$TEMP_DIR/fullchain.crt" \
    -name "$CN"

# Step 6: Verify the signed certificate
echo ""
echo "Step 6: Verifying signed certificate..."

# We already have the signed certificate, no need to extract from p12
# Use the signed certificate directly for verification
cp "$TEMP_DIR/signed.crt" "$TEMP_DIR/verify.crt"

# Verify certificate chain
echo -n "  Certificate chain verification: "
if [ -f /var/lib/step-ca/certs/intermediate_ca.crt ]; then
    # Verify with intermediate CA in the chain
    if openssl verify -CAfile /var/lib/step-ca/certs/root_ca.crt -untrusted /var/lib/step-ca/certs/intermediate_ca.crt "$TEMP_DIR/verify.crt" 2>/dev/null | grep -q "OK"; then
        echo "✓ VALID"
    else
        echo "✗ FAILED"
        echo "  Error: Certificate chain verification failed!"
    fi
else
    # Verify directly with root CA
    if openssl verify -CAfile /var/lib/step-ca/certs/root_ca.crt "$TEMP_DIR/verify.crt" 2>/dev/null | grep -q "OK"; then
        echo "✓ VALID"
    else
        echo "✗ FAILED"
        echo "  Error: Certificate chain verification failed!"
    fi
fi

# Show certificate details
echo ""
echo "=== Certificate Details ==="
echo "Subject:"
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -subject | sed 's/^/  /'

echo "Issuer:"
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -issuer | sed 's/^/  /'

echo "Validity:"
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -startdate | sed 's/^/  /'
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -enddate | sed 's/^/  /'

echo "Serial Number:"
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -serial | sed 's/^/  /'

echo "Signature Algorithm:"
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -text | grep "Signature Algorithm" | head -1 | sed 's/^/  /'

# Check for SANs
echo "Subject Alternative Names:"
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3 Subject Alternative Name:" | sed 's/^/  /' || echo "  None"

# Show certificate fingerprints
echo "Fingerprints:"
echo -n "  SHA256: "
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -fingerprint -sha256 | cut -d= -f2

echo ""
echo "=== Certificate Chain Verification ==="

# Verify full chain
echo "Testing certificate chain integrity..."
cat "$TEMP_DIR/verify.crt" > "$TEMP_DIR/chain-test.pem"
[ -f /var/lib/step-ca/certs/intermediate_ca.crt ] && cat /var/lib/step-ca/certs/intermediate_ca.crt >> "$TEMP_DIR/chain-test.pem"
cat /var/lib/step-ca/certs/root_ca.crt >> "$TEMP_DIR/chain-test.pem"

if openssl verify -CAfile /var/lib/step-ca/certs/root_ca.crt -untrusted "$TEMP_DIR/chain-test.pem" "$TEMP_DIR/verify.crt" 2>/dev/null | grep -q "OK"; then
    echo "  ✓ Full chain verification: PASSED"
else
    echo "  ✗ Full chain verification: FAILED"
fi

# Check certificate purposes
echo ""
echo "Certificate purposes:"
openssl x509 -in "$TEMP_DIR/verify.crt" -noout -purpose | grep "Yes" | sed 's/^/  ✓ /'

echo ""
echo "=== Certificate signed successfully! ==="
echo "Output file: $OUTPUT_P12"
echo ""
echo "The certificate chain includes:"
echo "  1. Your signed certificate (CN=$CN)"
[ -f /var/lib/step-ca/certs/intermediate_ca.crt ] && echo "  2. Intermediate CA certificate"
echo "  3. Root CA certificate (/var/lib/step-ca/certs/root_ca.crt)"
echo ""
echo "To manually verify later:"
echo "  openssl pkcs12 -in '$OUTPUT_P12' -nokeys -out cert.pem"
echo "  openssl verify -CAfile /var/lib/step-ca/certs/root_ca.crt cert.pem"
