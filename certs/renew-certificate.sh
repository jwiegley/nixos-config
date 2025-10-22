#!/usr/bin/env bash

# General certificate renewal script using step-ca
# Usage: ./renew-certificate.sh <domain> [options]

set -euo pipefail

# Default values
CA_CERT="/var/lib/step-ca-state/certs/intermediate_ca.crt"
CA_KEY="/var/lib/step-ca-state/secrets/intermediate_ca_key"
VALIDITY_DAYS=365
OUTPUT_DIR=""
KEY_FILE=""
CERT_FILE=""
OWNER="root:root"
KEY_PERMS="600"
CERT_PERMS="644"
ORGANIZATION="Vulcan LAN Services"
SKIP_FULLCHAIN=false
QUIET=false

# Function to print usage
usage() {
    cat <<EOF
Usage: $0 <domain> [options]

Renews a certificate for the specified domain using step-ca.

Options:
    -o, --output-dir DIR       Directory to save certificates (required)
    -k, --key-file NAME        Key filename (default: <domain>.key)
    -c, --cert-file NAME       Certificate filename (default: <domain>.crt)
    -d, --days DAYS           Validity period in days (default: 365)
    --owner USER:GROUP        File ownership (default: root:root)
    --key-perms MODE          Key file permissions (default: 600)
    --cert-perms MODE         Certificate file permissions (default: 644)
    --organization ORG        Organization name (default: Vulcan LAN Services)
    --ca-cert PATH           CA certificate path (default: /var/lib/step-ca-state/certs/intermediate_ca.crt)
    --ca-key PATH            CA key path (default: /var/lib/step-ca-state/secrets/intermediate_ca_key)
    --skip-fullchain         Don't create fullchain certificate
    -q, --quiet              Suppress non-error output
    -h, --help               Show this help message

Examples:
    # Renew nginx certificate
    $0 example.com -o /var/lib/nginx-certs --owner nginx:nginx

    # Renew postfix certificate
    $0 mail.example.com -o /etc/postfix/certs --days 730

    # Renew with custom filenames
    $0 example.com -o /etc/ssl -k server.key -c server.crt
EOF
    exit 0
}

# Check for help flag first
for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        usage
    fi
done

# Parse arguments
if [ $# -lt 1 ]; then
    echo "ERROR: Domain name is required"
    usage
fi

DOMAIN="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -k|--key-file)
            KEY_FILE="$2"
            shift 2
            ;;
        -c|--cert-file)
            CERT_FILE="$2"
            shift 2
            ;;
        -d|--days)
            VALIDITY_DAYS="$2"
            shift 2
            ;;
        --owner)
            OWNER="$2"
            shift 2
            ;;
        --key-perms)
            KEY_PERMS="$2"
            shift 2
            ;;
        --cert-perms)
            CERT_PERMS="$2"
            shift 2
            ;;
        --organization)
            ORGANIZATION="$2"
            shift 2
            ;;
        --ca-cert)
            CA_CERT="$2"
            shift 2
            ;;
        --ca-key)
            CA_KEY="$2"
            shift 2
            ;;
        --skip-fullchain)
            SKIP_FULLCHAIN=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            ;;
    esac
done

# Check required parameters
if [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: Output directory is required (use -o or --output-dir)"
    exit 1
fi

# Set default filenames if not specified
KEY_FILE="${KEY_FILE:-${DOMAIN}.key}"
CERT_FILE="${CERT_FILE:-${DOMAIN}.crt}"

# Full paths
KEY_PATH="${OUTPUT_DIR}/${KEY_FILE}"
CERT_PATH="${OUTPUT_DIR}/${CERT_FILE}"

# Create output directory if it doesn't exist
sudo mkdir -p "$OUTPUT_DIR"

# Get CA password from SOPS
CA_PASSWORD=$(sops -d /etc/nixos/secrets/secrets.yaml 2>/dev/null | grep "step-ca-password:" | cut -d' ' -f2)

if [ -z "$CA_PASSWORD" ]; then
    echo "ERROR: Cannot access CA password from SOPS"
    echo "Make sure you have the correct SOPS keys configured"
    exit 1
fi

# Print status if not quiet
if [ "$QUIET" != true ]; then
    echo "=== Certificate Renewal for $DOMAIN ==="
    echo "Output directory: $OUTPUT_DIR"
    echo "Certificate: $CERT_FILE"
    echo "Private key: $KEY_FILE"
    echo "Validity: $VALIDITY_DAYS days"
    echo ""
fi

# Check current certificate expiration if it exists
if [ -f "$CERT_PATH" ]; then
    CURRENT_EXPIRY=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ "$QUIET" != true ]; then
        echo "Current certificate expiry: $CURRENT_EXPIRY"
    fi
fi

# Generate private key
if [ "$QUIET" != true ]; then
    echo "Generating private key..."
fi
openssl genrsa -out "${KEY_PATH}.tmp" 2048 2>/dev/null

# Generate certificate signing request
if [ "$QUIET" != true ]; then
    echo "Creating certificate signing request..."
fi
openssl req -new \
    -key "${KEY_PATH}.tmp" \
    -out "/tmp/${DOMAIN}.csr" \
    -subj "/CN=${DOMAIN}/O=${ORGANIZATION}" \
    2>/dev/null

# Create extensions file for SAN
cat > "/tmp/${DOMAIN}.ext" <<EOFEXT
subjectAltName = DNS:${DOMAIN}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOFEXT

# Sign the certificate with the intermediate CA
if [ "$QUIET" != true ]; then
    echo "Signing certificate with CA..."
fi
echo "$CA_PASSWORD" | sudo openssl x509 -req \
    -in "/tmp/${DOMAIN}.csr" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -out "/tmp/${DOMAIN}.crt.tmp" \
    -days $VALIDITY_DAYS \
    -sha256 \
    -extfile "/tmp/${DOMAIN}.ext" \
    -passin stdin \
    2>/dev/null || {
        echo "ERROR: Failed to generate certificate for $DOMAIN"
        rm -f "${KEY_PATH}.tmp" "/tmp/${DOMAIN}.csr" "/tmp/${DOMAIN}.ext"
        exit 1
    }

# Create fullchain certificate if not skipped
if [ "$SKIP_FULLCHAIN" != true ]; then
    cat "/tmp/${DOMAIN}.crt.tmp" "$CA_CERT" > "${CERT_PATH}.tmp"
else
    cp "/tmp/${DOMAIN}.crt.tmp" "${CERT_PATH}.tmp"
fi

# Set proper permissions and ownership
sudo chown $OWNER "${CERT_PATH}.tmp" "${KEY_PATH}.tmp"
sudo chmod "$CERT_PERMS" "${CERT_PATH}.tmp"
sudo chmod "$KEY_PERMS" "${KEY_PATH}.tmp"

# Move new certificates into place
sudo mv "${CERT_PATH}.tmp" "$CERT_PATH"
sudo mv "${KEY_PATH}.tmp" "$KEY_PATH"

# Clean up temporary files
rm -f "/tmp/${DOMAIN}.csr" "/tmp/${DOMAIN}.ext" "/tmp/${DOMAIN}.crt.tmp"

# Verify the new certificate
NEW_EXPIRY=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
if [ "$QUIET" != true ]; then
    echo "New certificate expiry: $NEW_EXPIRY"
    echo "✓ Certificate renewed successfully"
fi

exit 0
