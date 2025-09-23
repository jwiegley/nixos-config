#!/usr/bin/env bash

# Postfix certificate renewal script using the general renew-certificate.sh
# This script renews the Postfix mail server certificates

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
RENEW_SCRIPT="${SCRIPT_DIR}/renew-certificate.sh"

# Configuration
POSTFIX_CERT_DIR="/etc/postfix/certs"
VALIDITY_DAYS=365

# Check if the general renewal script exists
if [ ! -f "$RENEW_SCRIPT" ]; then
    echo "ERROR: General renewal script not found at $RENEW_SCRIPT"
    exit 1
fi

echo "=== Postfix Certificate Renewal Script ==="
echo "Renewing certificates for ${VALIDITY_DAYS} days validity"
echo ""

# Primary mail server certificate
echo "Renewing primary mail server certificate..."
"$RENEW_SCRIPT" "mail.vulcan.lan" \
    -o "$POSTFIX_CERT_DIR" \
    -k "mail.key" \
    -c "mail.crt" \
    -d "$VALIDITY_DAYS" \
    --owner "root:root" \
    --organization "Vulcan Mail Services"

# SMTP certificate (if different from primary)
echo ""
echo "Renewing SMTP certificate..."
"$RENEW_SCRIPT" "smtp.vulcan.lan" \
    -o "$POSTFIX_CERT_DIR" \
    -k "smtp.key" \
    -c "smtp.crt" \
    -d "$VALIDITY_DAYS" \
    --owner "root:root" \
    --organization "Vulcan Mail Services"

# IMAP certificate (if using dovecot or similar)
echo ""
echo "Renewing IMAP certificate..."
"$RENEW_SCRIPT" "imap.vulcan.lan" \
    -o "$POSTFIX_CERT_DIR" \
    -k "imap.key" \
    -c "imap.crt" \
    -d "$VALIDITY_DAYS" \
    --owner "root:root" \
    --organization "Vulcan Mail Services"

echo ""
echo "=== Certificate renewal complete ==="
echo ""

# Reload Postfix to use new certificates
echo "Reloading postfix configuration..."
sudo systemctl reload postfix || echo "Note: Postfix service may not be running"

echo "✓ All mail certificates renewed"
