#!/usr/bin/env bash

# Nginx certificate renewal script using the general renew-certificate.sh
# This script renews certificates for the 37 hosts hardcoded in DOMAINS below.
# That is a SUBSET of the vhosts nginx serves out of /var/lib/nginx-certs: as of
# 2026-07-27 atd, budget, changes, chat, llama-swap, mailarchiver, shlink,
# shlink-api and vulcan.lan are NOT renewed here. atd and budget have their own
# *-certificate systemd units (modules/services/atd-nginx.nix:61,
# modules/containers/budgetboard-quadlet.nix:248); the rest have no automatic
# renewal at all. Add a domain here when you add a vhost.

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
    "immich.vulcan.lan"
    "jellyfin.vulcan.lan"
    "jupyter.vulcan.lan"
    "loki.vulcan.lan"
    "memory.vulcan.lan"
    "memory-mcp.vulcan.lan"
    "nagios.vulcan.lan"
    "nodered.vulcan.lan"
    "openproject.vulcan.lan"
    "postgres.vulcan.lan"
    "prometheus.vulcan.lan"
    "promtail.vulcan.lan"
    "radicale.vulcan.lan"
    "rspamd.vulcan.lan"
    "speedtest.vulcan.lan"
    "speedtracker.vulcan.lan"
    "teable.vulcan.lan"
    "trader.vulcan.lan"
    "vdirsyncer.vulcan.lan"
    "victoriametrics.vulcan.lan"
    "wallabag.vulcan.lan"
    "zimit.vulcan.lan"
    "kiwix.vulcan.lan"
    "searxng.vulcan.lan"
    "qdrant.vulcan.lan"
    "vane.vulcan.lan"
    "openclaw.vulcan.lan"
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
