#!/bin/bash
# Build v8dasm as a Linux binary using Docker.
#
# This script:
#   1. Builds a Docker image that compiles V8 9.4.146.24 and v8dasm
#   2. Extracts the v8dasm binary from the image
#
# Requirements:
#   - Docker with ~40GB free disk space
#   - Internet connection (to fetch V8 source and dependencies)
#
# The build takes 1-2 hours depending on your machine.
#
# Usage:
#   ./docker-build.sh                  # Build and extract binary
#   ./docker-build.sh --no-extract     # Only build Docker image
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="v8dasm-builder"
OUTPUT_BINARY="v8dasm"

cd "$SCRIPT_DIR"

echo "============================================="
echo "  Building v8dasm for Linux (V8 9.4.146.24)"
echo "============================================="
echo ""
echo "This will:"
echo "  - Download V8 source (~10GB)"
echo "  - Build V8 as static library"
echo "  - Compile v8dasm against it"
echo ""
echo "Estimated time: 1-2 hours"
echo "Estimated disk: ~40GB during build"
echo ""

# Build Docker image
echo ">>> Building Docker image '${IMAGE_NAME}'..."
docker build -t "${IMAGE_NAME}" .

if [ "${1:-}" = "--no-extract" ]; then
    echo ""
    echo "Docker image built. Run manually:"
    echo "  docker run --rm ${IMAGE_NAME} > ${OUTPUT_BINARY}"
    exit 0
fi

# Extract binary from image
echo ""
echo ">>> Extracting v8dasm binary..."
CONTAINER_ID=$(docker create "${IMAGE_NAME}")
docker cp "${CONTAINER_ID}:/usr/local/bin/v8dasm" "./${OUTPUT_BINARY}"
docker rm "${CONTAINER_ID}" > /dev/null

chmod +x "./${OUTPUT_BINARY}"

echo ""
echo "============================================="
echo "  Build complete!"
echo "============================================="
echo ""
echo "Binary: ${SCRIPT_DIR}/${OUTPUT_BINARY}"
echo ""
echo "Usage:"
echo "  ./v8dasm code.jsc > disassembly.txt"
echo ""
file "./${OUTPUT_BINARY}"
