#!/usr/bin/env bash

# Nginx certificate renewal script using the general renew-certificate.sh
# Add a domain here when you add a vhost.
#
# COVERAGE, re-derived 2026-08-20 (nixos-r1n) rather than trusted. The previous
# version of this header listed the gap correctly and it was still never closed,
# so the useful thing is the method, not the list:
#
#   NGINX_CONF=$(systemctl cat nginx.service | grep -oE '/nix/store/[^ ]*nginx\.conf')
#   # then compare, for each *.crt in /var/lib/nginx-certs, whether the basename
#   # appears in a live `server_name` directive of that file AND in DOMAINS below.
#
# That check on 2026-08-20 found four LIVE vhosts with no renewer anywhere --
# vulcan.lan (33 days from expiry), changes, mailarchiver and chat -- which are
# now in the list below.
#
# STILL NOT RENEWED HERE, deliberately:
#   atd.vulcan.lan, budget.vulcan.lan -- owned by their own units
#     (modules/services/atd-nginx.nix:61, modules/containers/budgetboard-quadlet.nix:248).
#     Note those are activation-time oneshots, not timers: both last ran at the
#     2026-07-03 boot and are RemainAfterExit, so they renew on reboot rather
#     than on a schedule. Adding them here as well would double-issue.
#   llama-swap, copyparty, notebook, syncthing, openclaw -- certificates on disk
#     with NO live vhost, left over from removed services. teable is the mirror
#     image: still in DOMAINS below and renewed monthly, with no live vhost.
#     Neither class is touched here; that is housekeeping, not renewal.

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
RENEW_SCRIPT="${SCRIPT_DIR}/renew-certificate.sh"

# Configuration
CERT_DIR="/var/lib/nginx-certs"
VALIDITY_DAYS=365

DOMAINS=(
    "alertmanager.vulcan.lan"
    "aria.vulcan.lan"
    "dns.vulcan.lan"
    "gitea.vulcan.lan"
    "glance.vulcan.lan"
    "grist.vulcan.lan"
    "glances.vulcan.lan"
    "grafana.vulcan.lan"
    "hass.vulcan.lan"
    "hermes.vulcan.lan"
    "immich.vulcan.lan"
    "jellyfin.vulcan.lan"
    "loki.vulcan.lan"
    "nodered.vulcan.lan"
    "openproject.vulcan.lan"
    "postgres.vulcan.lan"
    "prometheus.vulcan.lan"
    "promtail.vulcan.lan"
    "radicale.vulcan.lan"
    "rspamd.vulcan.lan"
    "speedtracker.vulcan.lan"
    "teable.vulcan.lan"
    "trader.vulcan.lan"
    "vdirsyncer.vulcan.lan"
    "victoriametrics.vulcan.lan"
    # nocobase: restored 2026-08-15. Listed even while services.nocobase.enable
    # is false so the certificate is provisioned ahead of the vhost -- nginx
    # refuses to start if it references a certificate that does not exist. This
    # script creates as well as renews (renew-certificate.sh only checks current
    # expiry "if it exists"), so an unissued domain is handled, not an error.
    "nocobase.vulcan.lan"
    "wallabag.vulcan.lan"
    "zimit.vulcan.lan"
    "kiwix.vulcan.lan"
    "searxng.vulcan.lan"
    "qdrant.vulcan.lan"
    "vane.vulcan.lan"
    # ADDED 2026-08-20 (nixos-r1n). All four are live vhosts in the generated
    # nginx.conf whose certificates had NO renewer anywhere -- verified by
    # cross-checking every *.crt in /var/lib/nginx-certs against the live
    # server_name directives and against this list. vulcan.lan was 33 days from
    # expiry when found; the others had 71-142 days.
    #
    # vulcan.lan is the bare-domain vhost (server_name vulcan.lan vulcan), which
    # is easy to miss precisely because it has no subdomain and reads like a
    # suffix of every other entry here. Do not grep for it loosely: "vulcan.lan"
    # matches all 40-odd names in this array.
    "vulcan.lan"
    "changes.vulcan.lan"
    "mailarchiver.vulcan.lan"
    "chat.vulcan.lan"
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
