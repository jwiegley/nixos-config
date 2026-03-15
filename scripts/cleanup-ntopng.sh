#!/usr/bin/env bash
# =============================================================================
# Cleanup Script: Remove ntopng Network Traffic Monitor
# =============================================================================
# Generated: 2026-03-13
#
# Removes all runtime state for ntopng, including:
#   - systemd services (ntopng, redis-ntopng)
#   - PostgreSQL database and user
#   - SSL certificates
#   - Data directories (/var/lib/ntopng)
#   - Prometheus node-exporter prom files (if any)
#
# PREREQUISITES:
#   - Run AFTER `sudo nixos-rebuild switch` with the updated configuration
#   - Run as root (or with sudo)
#   - NOTE: SOPS secret cleanup (ntopng-db-password) must be done manually:
#       sops /etc/nixos/secrets.yaml  →  delete 'ntopng-db-password'
#
# USAGE:
#   sudo bash /etc/nixos/scripts/cleanup-ntopng.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_section() { echo -e "\n${GREEN}========================================${NC}"; echo -e "${GREEN}$*${NC}"; echo -e "${GREEN}========================================${NC}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root.${NC}"
    exit 1
fi

# =============================================================================
# STOP SERVICES
# =============================================================================

log_section "Stopping ntopng services"

for svc in ntopng.service redis-ntopng.service postgresql-ntopng-setup.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log_info "Stopping $svc..."
        systemctl stop "$svc" && log_ok "Stopped $svc" || log_warn "Failed to stop $svc"
    else
        log_info "$svc is not running"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        log_info "Disabling $svc..."
        systemctl disable "$svc" && log_ok "Disabled $svc" || log_warn "Failed to disable $svc"
    fi
done

# =============================================================================
# POSTGRESQL CLEANUP
# =============================================================================

log_section "Dropping ntopng PostgreSQL database and user"

if command -v psql &>/dev/null; then
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='ntopng'" | grep -q 1; then
        log_info "Dropping database 'ntopng'..."
        sudo -u postgres psql -c "DROP DATABASE ntopng;" && log_ok "Database 'ntopng' dropped"
    else
        log_info "Database 'ntopng' does not exist, skipping"
    fi

    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='ntopng'" | grep -q 1; then
        log_info "Dropping PostgreSQL role 'ntopng'..."
        sudo -u postgres psql -c "DROP ROLE ntopng;" && log_ok "Role 'ntopng' dropped"
    else
        log_info "PostgreSQL role 'ntopng' does not exist, skipping"
    fi
else
    log_warn "psql not found, skipping database cleanup"
fi

# =============================================================================
# SSL CERTIFICATES
# =============================================================================

log_section "Removing ntopng SSL certificates"

for cert in \
    /var/lib/nginx-certs/ntopng.vulcan.lan.crt \
    /var/lib/nginx-certs/ntopng.vulcan.lan.key; do
    if [[ -f "$cert" ]]; then
        rm -f "$cert" && log_ok "Removed $cert"
    else
        log_info "$cert does not exist, skipping"
    fi
done

# =============================================================================
# DATA DIRECTORIES
# =============================================================================

log_section "Removing ntopng data directories"

log_warn "ntopng stores ~1.7GB of high-churn data — this may take a moment."

for dir in /var/lib/ntopng; do
    if [[ -d "$dir" ]]; then
        log_info "Removing $dir ..."
        rm -rf "$dir" && log_ok "Removed $dir"
    else
        log_info "$dir does not exist, skipping"
    fi
done

# =============================================================================
# SYSTEM USER / GROUP
# =============================================================================

log_section "Removing ntopng system user and group"

if id ntopng &>/dev/null; then
    log_info "Removing user 'ntopng'..."
    userdel --force ntopng 2>/dev/null && log_ok "User 'ntopng' removed" \
        || log_warn "Could not remove user 'ntopng' (may still be in use)"
else
    log_info "User 'ntopng' does not exist, skipping"
fi

if getent group ntopng &>/dev/null; then
    log_info "Removing group 'ntopng'..."
    groupdel ntopng 2>/dev/null && log_ok "Group 'ntopng' removed" \
        || log_warn "Could not remove group 'ntopng'"
else
    log_info "Group 'ntopng' does not exist, skipping"
fi

# =============================================================================
# NGINX LEFTOVERS
# =============================================================================

log_section "Checking for nginx config leftovers"

for conf in \
    /etc/nginx/conf.d/ntopng.conf \
    /etc/nginx/sites-enabled/ntopng.vulcan.lan \
    /etc/nginx/sites-available/ntopng.vulcan.lan; do
    if [[ -f "$conf" ]]; then
        rm -f "$conf" && log_ok "Removed $conf"
    fi
done

# Reload nginx to drop the virtual host (if running)
if systemctl is-active --quiet nginx.service 2>/dev/null; then
    log_info "Reloading nginx..."
    systemctl reload nginx && log_ok "nginx reloaded" || log_warn "nginx reload failed"
fi

# =============================================================================
# SUMMARY
# =============================================================================

log_section "ntopng cleanup complete"

echo ""
echo -e "${GREEN}All runtime state for ntopng has been removed.${NC}"
echo ""
echo -e "${YELLOW}MANUAL STEPS REMAINING:${NC}"
echo "  1. Remove SOPS secret from /etc/nixos/secrets.yaml:"
echo "       sops /etc/nixos/secrets.yaml"
echo "     Delete this key:  ntopng-db-password"
echo ""
echo "  2. Restart Samba if needed (windows-shared share is already removed):"
echo "       sudo systemctl restart samba-smbd samba-nmbd"
echo ""
echo -e "${YELLOW}NOTE:${NC} Run 'sudo nixos-rebuild switch --flake /etc/nixos#vulcan' first"
echo "if you haven't done so already."
