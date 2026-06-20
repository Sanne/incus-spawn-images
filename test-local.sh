#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
CONFIG_DIR="${HOME}/.config/incus-spawn/images"
OVERRIDE_FILE="${CONFIG_DIR}/minimal.yaml"
ARCH=$(uname -m)
TAG="local-$(date +%Y%m%d-%H%M%S)"

echo "=== Building base image locally ==="
mkdir -p "${OUTPUT_DIR}"
podman run --rm --privileged \
  -v "${SCRIPT_DIR}:/build:ro" \
  -v "${OUTPUT_DIR}:/output" \
  -e OUTPUT_DIR=/output \
  fedora:44 bash /build/fedora/build.sh

TARBALL="${OUTPUT_DIR}/fedora-44-${ARCH}.tar.xz"
if [ ! -f "${TARBALL}" ]; then
  echo "Error: expected tarball not found: ${TARBALL}"
  exit 1
fi

echo ""
echo "=== Configuring isx to use local image ==="
mkdir -p "${CONFIG_DIR}"
cat > "${OVERRIDE_FILE}" << EOF
name: tpl-minimal
description: Base OS only (local build)
image: fedora-44-base
image_url: file://${TARBALL}
image_tag: ${TAG}
EOF

echo "Wrote ${OVERRIDE_FILE}"
echo "Tag: ${TAG}"
echo ""
echo "Next steps:"
echo "  isx build tpl-minimal       # imports the local image"
echo "  isx build tpl-dev            # rebuild derived templates"
echo ""
echo "To revert: ./revert-local.sh"
