#!/bin/bash
set -euo pipefail

ARCH=$(uname -m)
RELEASE=44
ROOTFS=/tmp/rootfs
OUTPUT=${OUTPUT_DIR:-/output}

echo "=== Building Fedora ${RELEASE} base image for ${ARCH} ==="

# Bootstrap a complete systemd-based Fedora rootfs
echo "Bootstrapping rootfs..."
dnf --use-host-config \
    --installroot="${ROOTFS}" \
    --releasever="${RELEASE}" \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=False \
    --exclude='kernel*' \
    -y install \
    systemd systemd-resolved dhcpcd passwd \
    sudo bash coreutils util-linux dnf5 \
    glibc-langpack-en bash-completion \
    git curl which procps-ng findutils \
    iproute iputils

# Remove bloat packages that ship in the base but aren't needed
echo "Removing unnecessary packages..."
dnf --use-host-config --installroot="${ROOTFS}" -y remove \
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
# Remove the dangling resolv.conf symlink that resolved's package creates
# (points to /run/systemd/resolve/stub-resolv.conf which won't exist).
# Incus / BuildCommand will write a real resolv.conf at container start.
rm -f "${ROOTFS}/etc/resolv.conf"

# Patch nsswitch.conf so .local domains use dnsmasq, not mDNS
sed -i 's/resolve \[!UNAVAIL=return\] //' "${ROOTFS}/etc/nsswitch.conf"

# Enable DHCP on eth0 via dhcpcd (must specify interface to bypass udev)
echo "Enabling dhcpcd for eth0..."
mkdir -p "${ROOTFS}/etc/systemd/system"
cat > "${ROOTFS}/etc/systemd/system/dhcpcd-eth0.service" << 'SVCEOF'
[Unit]
Description=DHCP client for eth0
After=network.target
Wants=network.target

[Service]
ExecStart=/usr/sbin/dhcpcd -4 -q eth0
ExecStop=/usr/sbin/dhcpcd -x eth0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
chroot "${ROOTFS}" systemctl enable dhcpcd-eth0

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
tar -cJf "${TARBALL}" -C /tmp/image-root .

# Compute and save SHA256
sha256sum "${TARBALL}" | awk '{print $1}' > "${TARBALL}.sha256"
echo "SHA256: $(cat "${TARBALL}.sha256")"
echo "Output: ${TARBALL}"
echo "=== Done ==="
