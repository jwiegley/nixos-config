#!/usr/bin/env bash
set -euo pipefail

# Build Vanna.AI Docker image
cd "$(dirname "$0")"

echo "Building Vanna.AI Docker image..."
podman build -t localhost/vanna:latest .

echo "Vanna.AI image built successfully!"
echo "Image: localhost/vanna:latest"
