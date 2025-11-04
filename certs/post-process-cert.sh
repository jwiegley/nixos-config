#!/usr/bin/env bash
#
# post-process-cert.sh - Post-process Step-CA generated certificates
#
# This script automates certificate file management after generation:
# 1. Renames fullchain.crt to .crt
# 2. Removes unnecessary chain.crt file
# 3. Sets proper ownership (nginx:nginx by default)
# 4. Moves certificates to target directory (/var/lib/nginx-certs by default)
#
# Usage:
#   post-process-cert.sh <basename> [options]
#
# Arguments:
#   basename              Base name of certificate (e.g., "rspamd.vulcan.lan")
#
# Options:
#   -d, --directory DIR   Target directory (default: /var/lib/nginx-certs)
#   -o, --owner USER:GROUP File ownership (default: nginx:nginx)
#   --source-dir DIR      Source directory containing cert files (default: current directory)
#   --keep-chain          Keep the chain.crt file instead of deleting it
#   --dry-run             Show what would be done without executing
#   -h, --help            Show this help message
#
# Examples:
#   # Basic usage (process rspamd.vulcan.lan.* files)
#   post-process-cert.sh rspamd.vulcan.lan
#
#   # Custom ownership for Postfix
#   post-process-cert.sh mail.vulcan.lan --owner root:root
#
#   # Custom target directory
#   post-process-cert.sh dovecot.vulcan.lan -d /etc/dovecot/certs
#
#   # Dry run to preview actions
#   post-process-cert.sh hass.vulcan.lan --dry-run

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
TARGET_DIR="/var/lib/nginx-certs"
OWNER="nginx:nginx"
SOURCE_DIR="$(pwd)"
KEEP_CHAIN=false
DRY_RUN=false

# Helper functions
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

show_help() {
    grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# \?//'
    exit 0
}

execute() {
    local cmd="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN]${NC} Would execute: $cmd"
    else
        info "Executing: $cmd"
        eval "$cmd"
    fi
}

# Parse arguments
BASENAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -d|--directory)
            TARGET_DIR="$2"
            shift 2
            ;;
        -o|--owner)
            OWNER="$2"
            shift 2
            ;;
        --source-dir)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --keep-chain)
            KEEP_CHAIN=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            if [[ -z "$BASENAME" ]]; then
                BASENAME="$1"
            else
                error "Multiple basenames provided. Only one basename is allowed."
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$BASENAME" ]]; then
    error "Basename is required. Usage: $0 <basename> [options]"
fi

# Validate source directory
if [[ ! -d "$SOURCE_DIR" ]]; then
    error "Source directory does not exist: $SOURCE_DIR"
fi

cd "$SOURCE_DIR"

# Check if files exist
FULLCHAIN="${BASENAME}.fullchain.crt"
CHAIN="${BASENAME}.chain.crt"
KEY="${BASENAME}.key"

if [[ ! -f "$FULLCHAIN" ]]; then
    error "Fullchain certificate not found: $SOURCE_DIR/$FULLCHAIN"
fi

if [[ ! -f "$KEY" ]]; then
    error "Private key not found: $SOURCE_DIR/$KEY"
fi

# Validate target directory
if [[ ! -d "$TARGET_DIR" ]] && [[ "$DRY_RUN" == false ]]; then
    error "Target directory does not exist: $TARGET_DIR"
fi

# Validate ownership format
if ! echo "$OWNER" | grep -qE '^[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$'; then
    error "Invalid owner format. Expected USER:GROUP (e.g., nginx:nginx)"
fi

# Show configuration
info "Configuration:"
echo "  Basename:       $BASENAME"
echo "  Source dir:     $SOURCE_DIR"
echo "  Target dir:     $TARGET_DIR"
echo "  Ownership:      $OWNER"
echo "  Keep chain:     $KEEP_CHAIN"
echo "  Dry run:        $DRY_RUN"
echo ""

# Step 1: Rename fullchain to .crt
TARGET_CERT="${BASENAME}.crt"
if [[ -f "$FULLCHAIN" ]]; then
    if [[ -f "$TARGET_CERT" ]] && [[ "$TARGET_CERT" != "$FULLCHAIN" ]]; then
        warn "Target certificate already exists, will be overwritten: $TARGET_CERT"
    fi
    execute "sudo mv '$FULLCHAIN' '$TARGET_CERT'"
    success "Renamed fullchain certificate"
else
    warn "Fullchain certificate not found, skipping rename: $FULLCHAIN"
fi

# Step 2: Remove chain.crt if requested
if [[ "$KEEP_CHAIN" == false ]]; then
    if [[ -f "$CHAIN" ]]; then
        execute "sudo rm '$CHAIN'"
        success "Removed chain certificate"
    else
        info "Chain certificate not found, skipping removal: $CHAIN"
    fi
else
    info "Keeping chain certificate as requested"
fi

# Step 3: Set ownership on all matching files
execute "sudo chown '$OWNER' '${BASENAME}'.crt '${BASENAME}'.key"
if [[ "$KEEP_CHAIN" == true ]] && [[ -f "$CHAIN" ]]; then
    execute "sudo chown '$OWNER' '$CHAIN'"
fi
success "Set ownership to $OWNER"

# Step 4: Move files to target directory
if [[ "$SOURCE_DIR" != "$TARGET_DIR" ]]; then
    execute "sudo mv '${BASENAME}'.crt '${BASENAME}'.key '$TARGET_DIR/'"
    if [[ "$KEEP_CHAIN" == true ]] && [[ -f "$CHAIN" ]]; then
        execute "sudo mv '$CHAIN' '$TARGET_DIR/'"
    fi
    success "Moved certificates to $TARGET_DIR"
else
    info "Source and target directories are the same, skipping move"
fi

# Final summary
echo ""
if [[ "$DRY_RUN" == true ]]; then
    info "Dry run complete. No changes were made."
else
    success "Certificate post-processing complete!"
    info "Files processed:"
    execute "sudo ls -lh '$TARGET_DIR/${BASENAME}'.crt '$TARGET_DIR/${BASENAME}'.key"
    if [[ "$KEEP_CHAIN" == true ]]; then
        execute "sudo ls -lh '$TARGET_DIR/$CHAIN'"
    fi
fi
