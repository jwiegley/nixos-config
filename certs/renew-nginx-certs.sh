#!/usr/bin/env bash

# Nginx certificate renewal script using the general renew-certificate.sh
# This script renews certificates for all nginx virtual hosts

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
RENEW_SCRIPT="${SCRIPT_DIR}/renew-certificate.sh"

# Configuration
CERT_DIR="/var/lib/nginx-certs"
VALIDITY_DAYS=365

DOMAINS=(
    "alertmanager.vulcan.lan"
    "aria.vulcan.lan"
    "cockpit.vulcan.lan"
    "dns.vulcan.lan"
    "gitea.vulcan.lan"
    "glance.vulcan.lan"
    "glances.vulcan.lan"
    "grafana.vulcan.lan"
    "hass.vulcan.lan"
    "jellyfin.vulcan.lan"
    "jupyter.vulcan.lan"
    "litellm.vulcan.lan"
    "loki.vulcan.lan"
    "n8n.vulcan.lan"
    "nagios.vulcan.lan"
    "nodered.vulcan.lan"
    "ntopng.vulcan.lan"
    "postgres.vulcan.lan"
    "prometheus.vulcan.lan"
    "promtail.vulcan.lan"
    "radicale.vulcan.lan"
    "rspamd.vulcan.lan"
    "silly-tavern.vulcan.lan"
    "speedtest.vulcan.lan"
    "teable.vulcan.lan"
    "vdirsyncer.vulcan.lan"
    "victoriametrics.vulcan.lan"
    "wallabag.vulcan.lan"
)

# Check if the general renewal script exists
if [ ! -f "$RENEW_SCRIPT" ]; then
    echo "ERROR: General renewal script not found at $RENEW_SCRIPT"
    exit 1
fi

echo "=== Nginx Certificate Renewal Script ==="
echo "Renewing certificates for ${VALIDITY_DAYS} days validity"
echo ""

for domain in "${DOMAINS[@]}"; do
    echo "Processing: $domain"

    # Use the general renewal script with nginx-specific parameters
    "$RENEW_SCRIPT" "$domain" \
        -o "$CERT_DIR" \
        -d "$VALIDITY_DAYS" \
        --owner "nginx:nginx" \
        --cert-perms "644" \
        --key-perms "600"

    echo ""
done

echo "=== Certificate renewal complete ==="
echo ""
echo "Reloading nginx configuration..."
sudo systemctl reload nginx

echo "✓ All certificates renewed and nginx reloaded"
