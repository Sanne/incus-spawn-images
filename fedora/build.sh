#!/bin/bash
set -euo pipefail

ARCH=$(uname -m)
RELEASE=44
ROOTFS=/tmp/rootfs
OUTPUT=${OUTPUT_DIR:-/output}

echo "=== Building Fedora ${RELEASE} base image for ${ARCH} ==="

# Bootstrap a complete systemd-based Fedora rootfs
echo "Bootstrapping rootfs..."
dnf --installroot="${ROOTFS}" \
    --releasever="${RELEASE}" \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=False \
    -y install \
    systemd systemd-resolved passwd \
    sudo bash coreutils util-linux dnf5 \
    glibc-langpack-en bash-completion \
    git curl which procps-ng findutils \
    iproute iputils

# Remove bloat packages that ship in the base but aren't needed
echo "Removing unnecessary packages..."
dnf --installroot="${ROOTFS}" -y remove \
    glibc-all-langpacks geolite2-city geolite2-country 2>/dev/null || true

# Create agentuser (UID 1000) with passwordless sudo
echo "Creating agentuser..."
chroot "${ROOTFS}" useradd -m -u 1000 -G systemd-journal agentuser
chroot "${ROOTFS}" chown -R agentuser:agentuser /home/agentuser
chroot "${ROOTFS}" mkdir -p /home/agentuser/inbox
echo 'agentuser ALL=(ALL) NOPASSWD: ALL' > "${ROOTFS}/etc/sudoers.d/agentuser"

# Mask systemd services that are unnecessary or harmful in containers
echo "Masking systemd services..."
chroot "${ROOTFS}" systemctl mask \
    systemd-udevd.service \
    systemd-udevd-control.socket \
    systemd-udevd-kernel.socket \
    systemd-udev-trigger.service \
    systemd-udev-settle.service \
    systemd-udev-load-credentials.service \
    systemd-homed.service \
    systemd-pcrlock-file-system.service \
    systemd-pcrlock-firmware-code.service \
    systemd-pcrlock-firmware-config.service \
    systemd-pcrlock-machine-id.service \
    systemd-pcrlock-make-policy.service \
    systemd-pcrlock-secureboot-authority.service \
    systemd-pcrlock-secureboot-policy.service \
    systemd-tpm2-clear.service \
    systemd-time-wait-sync.service \
    systemd-timesyncd.service \
    systemd-boot-update.service \
    systemd-boot-check-no-failures.service \
    systemd-boot-clear-sysfail.service \
    systemd-sysupdate.timer \
    systemd-sysupdate-reboot.timer \
    unbound-anchor.timer \
    fstrim.timer \
    selinux-autorelabel-mark.service

# Disable and mask systemd-resolved (incus-spawn uses gateway dnsmasq instead)
echo "Disabling systemd-resolved..."
chroot "${ROOTFS}" systemctl disable systemd-resolved 2>/dev/null || true
chroot "${ROOTFS}" systemctl mask systemd-resolved

# Patch nsswitch.conf so .local domains use dnsmasq, not mDNS
sed -i 's/resolve \[!UNAVAIL=return\] //' "${ROOTFS}/etc/nsswitch.conf"

# Configure bash prompt (ISX window title) and bash-completion
cat >> "${ROOTFS}/home/agentuser/.bashrc" << 'BASHEOF'
PROMPT_COMMAND="printf '\033]0;isx:%s\007' \"${HOSTNAME}\""
if [ -f /usr/share/bash-completion/bash_completion ]; then
  . /usr/share/bash-completion/bash_completion
fi
BASHEOF
chroot "${ROOTFS}" chown agentuser:agentuser /home/agentuser/.bashrc

# Clean all caches to minimize image size
echo "Cleaning caches..."
dnf --installroot="${ROOTFS}" clean all
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

# Package as unified tarball (metadata.yaml + rootfs tree)
echo "Packaging image..."
mkdir -p "${OUTPUT}"
TARBALL="${OUTPUT}/fedora-${RELEASE}-${ARCH}.tar.xz"
tar -cJf "${TARBALL}" \
    -C /tmp metadata.yaml \
    -C "${ROOTFS}" .

# Compute and save SHA256
sha256sum "${TARBALL}" | awk '{print $1}' > "${TARBALL}.sha256"
echo "SHA256: $(cat "${TARBALL}.sha256")"
echo "Output: ${TARBALL}"
echo "=== Done ==="
