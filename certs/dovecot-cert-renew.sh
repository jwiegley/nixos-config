#!/usr/bin/env bash

# Dovecot certificate renewal script using the general renew-certificate.sh
# This script renews the Dovecot IMAP server certificates

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
RENEW_SCRIPT="${SCRIPT_DIR}/renew-certificate.sh"

# Configuration
DOVECOT_CERT_DIR="/var/lib/dovecot-certs"
VALIDITY_DAYS=365

# Check if the general renewal script exists
if [ ! -f "$RENEW_SCRIPT" ]; then
    echo "ERROR: General renewal script not found at $RENEW_SCRIPT"
    exit 1
fi

echo "=== Dovecot Certificate Renewal Script ==="
echo "Renewing certificates for ${VALIDITY_DAYS} days validity"
echo ""

# Create certificate directory if it doesn't exist
if [ ! -d "$DOVECOT_CERT_DIR" ]; then
    echo "Creating certificate directory: $DOVECOT_CERT_DIR"
    sudo mkdir -p "$DOVECOT_CERT_DIR"
fi

# IMAP certificate
echo "Renewing IMAP certificate..."
"$RENEW_SCRIPT" "imap.vulcan.lan" \
    -o "$DOVECOT_CERT_DIR" \
    -k "imap.vulcan.lan.key" \
    -c "imap.vulcan.lan.crt" \
    -d "$VALIDITY_DAYS" \
    --owner "root:dovecot2" \
    --organization "Vulcan Mail Services"

# Create fullchain certificate (combining cert and CA chain)
if [ -f "$DOVECOT_CERT_DIR/imap.vulcan.lan.crt" ]; then
    echo "Creating fullchain certificate..."
    
    # Check if intermediate CA exists
    if [ -f "/var/lib/step-ca-state/certs/intermediate_ca.crt" ]; then
        cat "$DOVECOT_CERT_DIR/imap.vulcan.lan.crt" \
            "/var/lib/step-ca-state/certs/intermediate_ca.crt" \
            > "$DOVECOT_CERT_DIR/imap.vulcan.lan.fullchain.crt"
    else
        # Fallback to just the certificate if intermediate is not available
        cp "$DOVECOT_CERT_DIR/imap.vulcan.lan.crt" \
           "$DOVECOT_CERT_DIR/imap.vulcan.lan.fullchain.crt"
    fi
    
    # Set proper permissions on fullchain
    sudo chown root:dovecot2 "$DOVECOT_CERT_DIR/imap.vulcan.lan.fullchain.crt"
    sudo chmod 640 "$DOVECOT_CERT_DIR/imap.vulcan.lan.fullchain.crt"
fi

# Alternative names for the same certificate (for flexibility)
echo ""
echo "Creating certificate aliases..."
for alias in mail.vulcan.lan dovecot.vulcan.lan; do
    echo "  Creating alias: $alias"
    ln -sf "$DOVECOT_CERT_DIR/imap.vulcan.lan.crt" "$DOVECOT_CERT_DIR/${alias}.crt" 2>/dev/null || true
    ln -sf "$DOVECOT_CERT_DIR/imap.vulcan.lan.key" "$DOVECOT_CERT_DIR/${alias}.key" 2>/dev/null || true
    ln -sf "$DOVECOT_CERT_DIR/imap.vulcan.lan.fullchain.crt" "$DOVECOT_CERT_DIR/${alias}.fullchain.crt" 2>/dev/null || true
done

echo ""
echo "=== Certificate renewal complete ==="
echo ""

# Validate the certificate
echo "Validating certificate..."
openssl x509 -in "$DOVECOT_CERT_DIR/imap.vulcan.lan.crt" -text -noout | grep -E "Subject:|Not Before|Not After" || true

# Reload Dovecot to use new certificates
echo ""
echo "Reloading dovecot configuration..."
sudo systemctl reload dovecot2 2>/dev/null || echo "Note: Dovecot service may not be running yet"

echo "✓ Dovecot certificates renewed successfully"
