#!/usr/bin/env bash

set -euo pipefail

CERT_DIR="/var/lib/nginx-certs"
CA_CERT="/var/lib/step-ca-state/certs/intermediate_ca.crt"
CA_KEY="/var/lib/step-ca-state/secrets/intermediate_ca_key"
CA_PASSWORD=$(sops -d /etc/nixos/secrets.yaml 2>/dev/null | grep "step-ca-password:" | cut -d' ' -f2)
VALIDITY_DAYS=365

DOMAINS=(
    "jellyfin.vulcan.lan"
    "litellm.vulcan.lan"
    "organizr.vulcan.lan"
    "postgres.vulcan.lan"
    "smokeping.vulcan.lan"
    "wallabag.vulcan.lan"
    "dns.vulcan.lan"
)

echo "=== Nginx Certificate Renewal Script ==="
echo "Renewing certificates for ${VALIDITY_DAYS} days validity"
echo ""

# Check if we can access the CA password
if [ -z "$CA_PASSWORD" ]; then
    echo "ERROR: Cannot access CA password from SOPS"
    echo "Make sure you have the correct SOPS keys configured"
    exit 1
fi

for domain in "${DOMAINS[@]}"; do
    echo "Processing: $domain"

    CERT_FILE="${CERT_DIR}/${domain}.crt"
    KEY_FILE="${CERT_DIR}/${domain}.key"

    # Check if certificate exists and its expiration
    if [ -f "$CERT_FILE" ]; then
        EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo "  Current expiry: $EXPIRY"
    fi

    # Generate private key
    openssl genrsa -out "${KEY_FILE}.tmp" 2048 2>/dev/null

    # Generate certificate signing request
    openssl req -new \
        -key "${KEY_FILE}.tmp" \
        -out "/tmp/${domain}.csr" \
        -subj "/CN=${domain}/O=Vulcan LAN Services" \
        2>/dev/null

    # Create extensions file for SAN
    cat > "/tmp/${domain}.ext" <<EOF
subjectAltName = DNS:${domain}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

    # Sign the certificate with the intermediate CA (using password)
    echo "$CA_PASSWORD" | sudo openssl x509 -req \
        -in "/tmp/${domain}.csr" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "/tmp/${domain}.crt.tmp" \
        -days $VALIDITY_DAYS \
        -sha256 \
        -extfile "/tmp/${domain}.ext" \
        -passin stdin \
        2>/dev/null || {
            echo "  ERROR: Failed to generate certificate for $domain"
            rm -f "${KEY_FILE}.tmp" "/tmp/${domain}.csr" "/tmp/${domain}.ext"
            continue
        }

    # Create fullchain certificate (server cert + intermediate CA)
    cat "/tmp/${domain}.crt.tmp" "$CA_CERT" > "${CERT_FILE}.tmp"

    # Set proper permissions and ownership
    sudo chown nginx:nginx "${CERT_FILE}.tmp" "${KEY_FILE}.tmp"
    sudo chmod 644 "${CERT_FILE}.tmp"
    sudo chmod 600 "${KEY_FILE}.tmp"

    # Move new certificates into place
    sudo mv "${CERT_FILE}.tmp" "$CERT_FILE"
    sudo mv "${KEY_FILE}.tmp" "$KEY_FILE"

    # Clean up temporary files
    rm -f "/tmp/${domain}.csr" "/tmp/${domain}.ext" "/tmp/${domain}.crt.tmp"

    # Verify the new certificate
    NEW_EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
    echo "  New expiry: $NEW_EXPIRY"
    echo "  ✓ Certificate renewed successfully"
    echo ""
done

echo "=== Certificate renewal complete ==="
echo ""
echo "Reloading nginx configuration..."
sudo systemctl reload nginx

echo "✓ All certificates renewed and nginx reloaded"