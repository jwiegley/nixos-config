#!/usr/bin/env bash
# Deployment and management script for Convention Speaker List
# This script helps manage the convention-speaker-list container

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="convention-speaker-list"
APP_DATA_DIR="/var/lib/convention-speaker-list"
HOST_PORT=9094

# Helper functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Show container status
status() {
    info "Convention Speaker List Status:"
    echo ""

    # Container status
    if systemctl is-active --quiet "container@${CONTAINER_NAME}.service"; then
        success "Container: Running"
    else
        error "Container: Not running"
    fi

    # Proxy service status
    if systemctl is-active --quiet "convention-speaker-list-http.service"; then
        success "HTTP Proxy: Running"
    else
        error "HTTP Proxy: Not running"
    fi

    # Cloudflare tunnel status (if configured)
    if systemctl is-active --quiet "cloudflared-tunnel-convention-speaker-list.service" 2>/dev/null; then
        success "Cloudflare Tunnel: Running"
    else
        warning "Cloudflare Tunnel: Not configured or not running"
    fi

    echo ""
    info "Listening on: http://127.0.0.1:${HOST_PORT}"
}

# Show logs
logs() {
    local service="${1:-all}"

    case "$service" in
        app)
            info "Showing application logs..."
            machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/journalctl -u convention-speaker-list-app.service -f
            ;;
        nginx)
            info "Showing nginx logs..."
            machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/journalctl -u nginx.service -f
            ;;
        postgres)
            info "Showing PostgreSQL logs..."
            machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/journalctl -u postgresql.service -f
            ;;
        redis)
            info "Showing Redis logs..."
            machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/journalctl -u redis-convention.service -f
            ;;
        tunnel)
            info "Showing Cloudflare Tunnel logs..."
            journalctl -u cloudflared-tunnel-convention-speaker-list.service -f
            ;;
        container)
            info "Showing container logs..."
            journalctl -u "container@${CONTAINER_NAME}.service" -f
            ;;
        all|*)
            info "Showing all container service logs..."
            machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/journalctl -f
            ;;
    esac
}

# Restart services
restart() {
    local service="${1:-all}"

    case "$service" in
        app)
            info "Restarting application..."
            machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/systemctl restart convention-speaker-list-app.service
            success "Application restarted"
            ;;
        nginx)
            info "Restarting nginx..."
            machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/systemctl restart nginx.service
            success "Nginx restarted"
            ;;
        container)
            info "Restarting container..."
            systemctl restart "container@${CONTAINER_NAME}.service"
            success "Container restarted"
            ;;
        tunnel)
            info "Restarting Cloudflare Tunnel..."
            systemctl restart cloudflared-tunnel-convention-speaker-list.service
            success "Cloudflare Tunnel restarted"
            ;;
        all|*)
            info "Restarting entire container..."
            systemctl restart "container@${CONTAINER_NAME}.service"
            success "Container restarted"
            ;;
    esac
}

# Database operations
db_migrate() {
    info "Running database migrations..."
    machinectl shell "$CONTAINER_NAME" /bin/sh -c "
        cd ${APP_DATA_DIR}/app/src/backend
        /run/current-system/sw/bin/npm run db:migrate
    "
    success "Database migrations completed"
}

db_shell() {
    info "Opening PostgreSQL shell..."
    machinectl shell "$CONTAINER_NAME" /bin/sh -c "
        /run/current-system/sw/bin/psql -U convention_user -d convention_db
    "
}

db_backup() {
    local backup_file="${APP_DATA_DIR}/backups/convention_db_$(date +%Y%m%d_%H%M%S).sql"

    info "Creating database backup..."
    mkdir -p "${APP_DATA_DIR}/backups"

    machinectl shell "$CONTAINER_NAME" /bin/sh -c "
        /run/current-system/sw/bin/pg_dump -U postgres convention_db
    " > "$backup_file"

    success "Database backed up to: $backup_file"
}

# Shell into container
shell() {
    local user="${1:-root}"
    info "Opening shell in container as $user..."
    machinectl shell "$CONTAINER_NAME"
}

# Health check
health() {
    info "Checking service health..."
    echo ""

    # Check localhost port
    if curl -sf "http://127.0.0.1:${HOST_PORT}/health" > /dev/null 2>&1; then
        success "HTTP endpoint: Healthy"
    else
        error "HTTP endpoint: Not responding"
    fi

    # Check PostgreSQL
    if machinectl shell "$CONTAINER_NAME" /run/current-system/sw/bin/pg_isready -h 127.0.0.1 -U convention_user > /dev/null 2>&1; then
        success "PostgreSQL: Healthy"
    else
        error "PostgreSQL: Not ready"
    fi

    # Check Redis
    if machinectl shell "$CONTAINER_NAME" /bin/sh -c "/run/current-system/sw/bin/redis-cli ping" | grep -q PONG 2>&1; then
        success "Redis: Healthy"
    else
        error "Redis: Not responding"
    fi
}

# Update application from git
update() {
    info "Updating application from Gitea..."
    info "This will update the flake input and rebuild..."

    cd /etc/nixos
    nix flake lock --update-input convention-speaker-list

    success "Flake updated. Run 'nixos-rebuild switch' to apply changes"
}

# Show help
show_help() {
    cat <<EOF
Convention Speaker List Management Script

Usage: $0 <command> [options]

Commands:
    status              Show service status
    logs [service]      Show logs (app|nginx|postgres|redis|tunnel|container|all)
    restart [service]   Restart service (app|nginx|container|tunnel|all)

    db:migrate          Run database migrations
    db:shell            Open PostgreSQL shell
    db:backup           Create database backup

    shell [user]        Open shell in container (default: root)
    health              Check service health
    update              Update application from Gitea

    help                Show this help message

Examples:
    $0 status
    $0 logs app
    $0 restart app
    $0 db:migrate
    $0 health

EOF
}

# Main command dispatcher
main() {
    check_root

    case "${1:-help}" in
        status)
            status
            ;;
        logs)
            logs "${2:-all}"
            ;;
        restart)
            restart "${2:-all}"
            ;;
        db:migrate)
            db_migrate
            ;;
        db:shell)
            db_shell
            ;;
        db:backup)
            db_backup
            ;;
        shell)
            shell "${2:-root}"
            ;;
        health)
            health
            ;;
        update)
            update
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
