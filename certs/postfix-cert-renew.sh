#!/usr/bin/env bash

# Postfix certificate renewal script using the general renew-certificate.sh
#
# ---------------------------------------------------------------------------
# WHAT THIS FIXES (2026-08-20)
# ---------------------------------------------------------------------------
# This script renewed into /etc/postfix/certs for ~11 months while postfix has
# always read /var/lib/postfix-certs. Every monthly run reported success, wrote
# fresh files nothing consumed, and left the live certificate untouched. The
# served cert dated from 2025-09-23 and was 34 days from expiry when this was
# found; nothing had noticed, because the renewal unit's exit status is not
# evidence that the wire changed.
#
# The authoritative path is NOT this script's opinion -- it is set in Nix at
# modules/services/postfix.nix:149-150:
#     smtpd_tls_chain_files = /var/lib/postfix-certs/smtp.vulcan.lan.key,
#                             /var/lib/postfix-certs/smtp.vulcan.lan.fullchain.crt
# Confirm with `sudo postconf -h smtpd_tls_chain_files` before changing anything
# here. If those ever disagree, postfix.nix wins and this file is wrong.
#
# ---------------------------------------------------------------------------
# WHY TWO CERTIFICATE FILES
# ---------------------------------------------------------------------------
# Two different consumers read two different files, and it is easy to fix one
# and silently break the other:
#   *.fullchain.crt  postfix serves this (leaf + intermediate)
#   *.crt            modules/monitoring/services/certificate-exporter.nix reads
#                    this to publish certificate_days_until_expiry, and also
#                    verifies it against the step-ca chain
# renew-certificate.sh writes ONE cert file and concatenates the CA into it, so
# pointing it at the fullchain and stopping would leave the MONITORED file stale
# -- the same bug inverted, and harder to spot. The leaf is therefore extracted
# back out afterwards. `openssl x509` emits only the first certificate of a
# bundle, which is exactly the leaf.
#
# ---------------------------------------------------------------------------
# WHY ONLY smtp.vulcan.lan
# ---------------------------------------------------------------------------
# This script also renewed mail.vulcan.lan and imap.vulcan.lan into the same
# orphan directory. Neither is referenced by postfix's live config or anywhere
# in this repository, and imap is genuinely served by dovecot, which has its own
# working renewal (certs/dovecot-cert-renew.sh -> /var/lib/dovecot-certs, on the
# wire with a 2027 expiry). Renewing three certificates where only one is used
# is what let the real failure hide in a wall of successful output.

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
RENEW_SCRIPT="${SCRIPT_DIR}/renew-certificate.sh"

# Configuration
POSTFIX_CERT_DIR="/var/lib/postfix-certs"
DOMAIN="smtp.vulcan.lan"
VALIDITY_DAYS=365

# Check if the general renewal script exists
if [ ! -f "$RENEW_SCRIPT" ]; then
    echo "ERROR: General renewal script not found at $RENEW_SCRIPT"
    exit 1
fi

echo "=== Postfix Certificate Renewal Script ==="
echo "Domain:    ${DOMAIN}"
echo "Directory: ${POSTFIX_CERT_DIR}"
echo "Validity:  ${VALIDITY_DAYS} days"
echo ""

# Refuse to run if postfix is not actually configured to read where we write.
# This is the guard whose absence allowed an 11-month silent failure.
LIVE_CHAIN="$(postconf -h smtpd_tls_chain_files 2>/dev/null || true)"
if [ -n "$LIVE_CHAIN" ] && [[ "$LIVE_CHAIN" != *"${POSTFIX_CERT_DIR}/"* ]]; then
    echo "ERROR: postfix reads its chain from a directory this script does not write."
    echo "  postfix smtpd_tls_chain_files: ${LIVE_CHAIN}"
    echo "  this script writes to:         ${POSTFIX_CERT_DIR}"
    echo "Renewing now would produce fresh files nothing serves. Fix POSTFIX_CERT_DIR"
    echo "here, or modules/services/postfix.nix, so the two agree."
    exit 1
fi

if [ ! -d "$POSTFIX_CERT_DIR" ]; then
    echo "Creating certificate directory: $POSTFIX_CERT_DIR"
    sudo mkdir -p "$POSTFIX_CERT_DIR"
fi

# Renew directly into the fullchain file postfix serves. renew-certificate.sh
# concatenates the step-ca intermediate (its default --ca-cert) after the leaf,
# which is precisely the chain postfix wants.
echo "Renewing ${DOMAIN} certificate..."
"$RENEW_SCRIPT" "$DOMAIN" \
    -o "$POSTFIX_CERT_DIR" \
    -k "${DOMAIN}.key" \
    -c "${DOMAIN}.fullchain.crt" \
    -d "$VALIDITY_DAYS" \
    --owner "root:root" \
    --organization "Vulcan Mail Services"

# Publish the leaf on its own for the certificate exporter.
echo ""
echo "Extracting leaf certificate for monitoring..."
sudo openssl x509 -in "${POSTFIX_CERT_DIR}/${DOMAIN}.fullchain.crt" \
     -out "${POSTFIX_CERT_DIR}/${DOMAIN}.crt"
sudo chown root:root "${POSTFIX_CERT_DIR}/${DOMAIN}.crt"
sudo chmod 644 "${POSTFIX_CERT_DIR}/${DOMAIN}.crt"

echo ""
echo "Reloading postfix configuration..."
sudo systemctl reload postfix || echo "Note: Postfix service may not be running"

# ---------------------------------------------------------------------------
# VERIFY ON THE WIRE, not on disk.
# ---------------------------------------------------------------------------
# The whole point of this section: a successful renewal and a successful reload
# both reported success throughout the 11 months this was broken. The only
# evidence that means anything is what the server actually presents on port 587.
echo ""
echo "Verifying served certificate on port 587..."
sleep 2
FILE_END="$(sudo openssl x509 -in "${POSTFIX_CERT_DIR}/${DOMAIN}.crt" -noout -enddate | cut -d= -f2)"
WIRE_END="$(echo | timeout 10 openssl s_client -connect 127.0.0.1:587 -starttls smtp 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"

echo "  on disk: ${FILE_END:-<none>}"
echo "  on wire: ${WIRE_END:-<none>}"

if [ -z "$WIRE_END" ]; then
    echo "WARNING: could not read the served certificate. Check postfix is running"
    echo "and that submission is enabled on 587, then re-verify by hand."
    exit 1
fi

if [ "$(date -d "$FILE_END" +%s)" != "$(date -d "$WIRE_END" +%s)" ]; then
    echo "ERROR: postfix is still serving a different certificate than the one on disk."
    echo "The renewal wrote files that are not being served -- exactly the failure"
    echo "mode this script was rewritten to prevent. Do NOT assume this is cosmetic."
    exit 1
fi

echo ""
echo "✓ ${DOMAIN} renewed and confirmed live on port 587"
