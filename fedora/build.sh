#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=$(uname -m)
RELEASE=44
ROOTFS=/tmp/rootfs
OUTPUT=${OUTPUT_DIR:-/output}

echo "=== Building Fedora ${RELEASE} container image for ${ARCH} ==="

# ============================================================
# Phase 1: Build container rootfs
# ============================================================

# Bootstrap a complete systemd-based Fedora rootfs
echo "Bootstrapping rootfs..."
dnf --use-host-config \
    --installroot="${ROOTFS}" \
    --releasever="${RELEASE}" \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=False \
    --setopt=tsflags=nodocs \
    --exclude='kernel*' \
    -y install \
    systemd systemd-udev systemd-networkd passwd \
    sudo bash coreutils util-linux dnf5 \
    glibc-langpack-en bash-completion \
    git curl which procps-ng findutils \
    iproute iputils

# Remove bloat packages that ship in the base but aren't needed
echo "Removing unnecessary packages..."
dnf --use-host-config --installroot="${ROOTFS}" -y remove \
    glibc-all-langpacks geolite2-city geolite2-country 2>/dev/null || true

# Run shared base configuration inside the rootfs
echo "Configuring base system..."
cp "${SCRIPT_DIR}/configure-base.sh" "${ROOTFS}/tmp/configure-base.sh"
chroot "${ROOTFS}" bash /tmp/configure-base.sh
rm -f "${ROOTFS}/tmp/configure-base.sh"

# ============================================================
# Phase 2: Package container image
# ============================================================

echo ""
echo "=== Packaging container image ==="

# Clean all caches to minimize image size
echo "Cleaning caches..."
dnf --use-host-config --installroot="${ROOTFS}" clean all
rm -rf "${ROOTFS}/var/cache/libdnf5" "${ROOTFS}/tmp"/* "${ROOTFS}/var/tmp"/*
rm -rf "${ROOTFS}/var/log"/*

# Create Incus metadata.yaml
echo "Creating metadata..."
CREATION_DATE=$(date +%s)
cat > /tmp/metadata.yaml << EOF
architecture: ${ARCH}
creation_date: ${CREATION_DATE}
properties:
  description: Fedora ${RELEASE} base for incus-spawn
  os: Fedora
  release: "${RELEASE}"
  variant: incus-spawn-base
EOF

# Incus expects container rootfs under a rootfs/ subdirectory
echo "Preparing rootfs layout..."
mkdir -p /tmp/image-root/rootfs
cp /tmp/metadata.yaml /tmp/image-root/
cp -a "${ROOTFS}/." /tmp/image-root/rootfs/

# Package as unified tarball (metadata.yaml + rootfs/ tree)
echo "Packaging image..."
mkdir -p "${OUTPUT}"
TARBALL="${OUTPUT}/fedora-${RELEASE}-${ARCH}.tar.xz"
tar --xattrs -cJf "${TARBALL}" -C /tmp/image-root .

# Compute and save SHA256
sha256sum "${TARBALL}" | awk '{print $1}' > "${TARBALL}.sha256"
echo "SHA256: $(cat "${TARBALL}.sha256")"
echo "Container output: ${TARBALL}"
