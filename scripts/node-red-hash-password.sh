#!/usr/bin/env nix-shell
#!nix-shell -i bash -p nodejs nodePackages.node-gyp python3
# Node-RED Password Hash Generator
# Generates bcrypt password hashes for use in Node-RED settings.js
# Usage: ./node-red-hash-password.sh [password]

set -euo pipefail

# Check if password provided as argument
if [ $# -eq 1 ]; then
    PASSWORD="$1"
else
    # Prompt for password
    read -sp "Enter password: " PASSWORD
    echo
    read -sp "Confirm password: " PASSWORD_CONFIRM
    echo

    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        echo "Error: Passwords do not match" >&2
        exit 1
    fi
fi

# Check if password is empty
if [ -z "$PASSWORD" ]; then
    echo "Error: Password cannot be empty" >&2
    exit 1
fi

# Create a temporary directory for npm packages
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cd "$TMPDIR"

# Install bcryptjs locally
echo "Installing bcryptjs..." >&2
npm install --silent bcryptjs 2>&1 | grep -v "npm warn" || true

# Generate bcrypt hash using Node.js and bcryptjs
# Node-RED uses bcryptjs internally, so we use the same
HASH=$(node -e "
const bcrypt = require('bcryptjs');
const password = process.argv[1];
const hash = bcrypt.hashSync(password, 8);
console.log(hash);
" "$PASSWORD")

echo
echo "Bcrypt hash generated:"
echo "$HASH"
echo
echo "Add this to your SOPS secrets file:"
echo "node-red:"
echo "  admin-password-hash: \"$HASH\""
