#!/usr/bin/env bash
# Migration script for container user separation
# This script helps migrate from shared container users (container-db, container-web, etc.)
# to dedicated per-service users for improved security isolation.
#
# IMPORTANT: Review and test this script carefully before running!
# Run this AFTER switching to the new configuration with dedicated users.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

# Banner
echo "========================================="
echo "Container User Migration Script"
echo "========================================="
echo ""
log_warn "This script will change ownership of container data directories."
log_warn "Make sure you have backups before proceeding!"
echo ""
read -p "Continue? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    log_info "Migration cancelled."
    exit 0
fi

# Migration mappings: service_name:old_user:new_user
declare -A migrations=(
    ["litellm"]="container-db:litellm"
    ["metabase"]="container-db:metabase"
    ["mindsdb"]="container-db:mindsdb"
    ["nocobase"]="container-db:nocobase"
    ["vanna"]="container-db:vanna"
    ["wallabag"]="container-db:wallabag"
    ["teable"]="container-db:teable"
    ["silly-tavern"]="container-web:sillytavern"
    ["opnsense-exporter"]="container-monitor:opnsense-exporter"
    ["technitium-dns-exporter"]="container-monitor:technitium-dns-exporter"
    ["openspeedtest"]="container-misc:openspeedtest"
    ["paperless-ai"]="container-misc:paperless-ai"
)

# Stop all containers
log_info "Stopping all container services..."
for service in "${!migrations[@]}"; do
    log_info "  Stopping $service.service..."
    systemctl stop "$service.service" || log_warn "    Failed to stop $service.service (may not be running)"
done
echo ""

# Wait for containers to fully stop
log_info "Waiting for containers to stop..."
sleep 5
echo ""

# Migrate data directories
log_info "Migrating data directory ownership..."
for service in "${!migrations[@]}"; do
    IFS=':' read -r old_user new_user <<< "${migrations[$service]}"

    # Primary data directory
    data_dir="/var/lib/$service"
    if [[ -d "$data_dir" ]]; then
        log_info "  $service: Changing ownership from $old_user to $new_user"
        log_info "    Directory: $data_dir"
        chown -R "$new_user:$new_user" "$data_dir" || log_error "    Failed to change ownership of $data_dir"
    else
        log_warn "  $service: Directory $data_dir does not exist, skipping"
    fi
done
echo ""

# Migrate container home directories
log_info "Migrating container home directories..."
for service in "${!migrations[@]}"; do
    IFS=':' read -r old_user new_user <<< "${migrations[$service]}"

    old_home="/var/lib/containers/$old_user"
    new_home="/var/lib/containers/$new_user"

    # Create new home if it doesn't exist
    if [[ ! -d "$new_home" ]]; then
        log_info "  Creating home directory for $new_user: $new_home"
        mkdir -p "$new_home"
        chown "$new_user:$new_user" "$new_home"
        chmod 700 "$new_home"
    fi
done
echo ""

# Migrate secrets directories
log_info "Migrating secrets directories..."
for service in "${!migrations[@]}"; do
    IFS=':' read -r old_user new_user <<< "${migrations[$service]}"

    old_secrets="/run/secrets-$old_user"
    new_secrets="/run/secrets-$new_user"

    # Create new secrets directory if it doesn't exist
    if [[ ! -d "$new_secrets" ]]; then
        log_info "  Creating secrets directory for $new_user: $new_secrets"
        mkdir -p "$new_secrets"
        chown "$new_user:$new_user" "$new_secrets"
        chmod 750 "$new_secrets"
    fi

    # Copy secrets from old directory if it exists and has files
    if [[ -d "$old_secrets" ]] && [[ -n "$(ls -A $old_secrets 2>/dev/null)" ]]; then
        log_info "  Copying secrets from $old_secrets to $new_secrets"
        cp -a "$old_secrets"/* "$new_secrets/" || log_warn "    No secrets to copy or copy failed"
        chown -R "$new_user:$new_user" "$new_secrets"
    fi
done
echo ""

# Migrate podman storage (container images, volumes, etc.)
log_info "Migrating podman storage..."
log_info "  NOTE: Each user will need to pull/build their own container images"
log_info "  This is intentional for security isolation"
for service in "${!migrations[@]}"; do
    IFS=':' read -r old_user new_user <<< "${migrations[$service]}"

    new_storage="/var/lib/containers/$new_user/.local/share/containers"
    if [[ ! -d "$new_storage" ]]; then
        log_info "  Creating podman storage for $new_user"
        mkdir -p "$new_storage"
        chown -R "$new_user:$new_user" "/var/lib/containers/$new_user/.local"
    fi
done
echo ""

# Special handling for specific services
log_info "Applying service-specific migrations..."

# litellm: config directory
if [[ -d "/etc/litellm" ]]; then
    log_info "  litellm: Migrating /etc/litellm ownership to litellm user"
    chown -R litellm:litellm /etc/litellm
fi

# vanna: subdirectories
if [[ -d "/var/lib/vanna" ]]; then
    log_info "  vanna: Migrating /var/lib/vanna subdirectories to vanna user"
    for subdir in faiss cache; do
        if [[ -d "/var/lib/vanna/$subdir" ]]; then
            chown -R vanna:vanna "/var/lib/vanna/$subdir"
        fi
    done
fi

# silly-tavern: config and data subdirectories
if [[ -d "/var/lib/silly-tavern" ]]; then
    log_info "  silly-tavern: Migrating /var/lib/silly-tavern subdirectories to sillytavern user"
    for subdir in config data; do
        if [[ -d "/var/lib/silly-tavern/$subdir" ]]; then
            chown -R sillytavern:sillytavern "/var/lib/silly-tavern/$subdir"
        fi
    done
fi

echo ""
log_info "Migration complete!"
echo ""
log_info "Next steps:"
log_info "1. Review the migration log above for any errors"
log_info "2. Start services with: sudo systemctl start <service>.service"
log_info "3. Check service status with: sudo systemctl status <service>.service"
log_info "4. Monitor logs with: sudo journalctl -u <service>.service -f"
log_info "5. Verify containers are running: podman ps -a"
echo ""
log_warn "Important: Container images will need to be pulled/built for each new user"
log_warn "NixOS will handle this automatically on the next rebuild or service start"
echo ""
