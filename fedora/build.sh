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
    selinux-autorelabel-mark.service \
    systemd-firstboot.service \
    systemd-homed-firstboot.service

# Mask static device node permissions — in unprivileged containers, /dev/net/tun
# and /dev/fuse are injected by Incus (host-managed) and can't be fchmod'd from
# inside the user namespace. The systemd %triggerin scriptlet runs
# systemd-tmpfiles --create which processes these rules and fails, aborting the
# entire rpm transaction.
mkdir -p "${ROOTFS}/etc/tmpfiles.d"
printf '# Container override: skip static device node permissions.\n# Host-injected device nodes cannot be fchmod'"'"'d inside the user namespace.\n' \
  > "${ROOTFS}/etc/tmpfiles.d/static-nodes-permissions.conf"

# Patch nsswitch.conf: remove mDNS resolve entry so .local domains use dnsmasq.
# Also ensure no dangling resolv.conf (BuildCommand writes the real one at container start).
sed -i 's/resolve \[!UNAVAIL=return\] //' "${ROOTFS}/etc/nsswitch.conf"
rm -f "${ROOTFS}/etc/resolv.conf"

# Enable systemd-networkd for static IP assignment (configured per-branch by isx).
# No .network file is baked in — branches push their own at creation time.
echo "Enabling systemd-networkd..."
mkdir -p "${ROOTFS}/etc/systemd/network"
chroot "${ROOTFS}" systemctl enable systemd-networkd

# Install connectivity watchdog — recovers static IP after host sleep/wake.
# Exits silently when no static network config exists (safe in templates).
echo "Installing network watchdog..."
mkdir -p "${ROOTFS}/etc/systemd/system"
cat > "${ROOTFS}/usr/local/bin/isx-network-watchdog" << 'WDEOF'
#!/bin/bash
IFACE=eth0
NETWORK_FILE=/etc/systemd/network/10-eth0.network

EXPECTED_IP=$(grep '^Address=' "$NETWORK_FILE" 2>/dev/null | head -1 | cut -d= -f2 | cut -d/ -f1)
GATEWAY=$(grep '^Gateway=' "$NETWORK_FILE" 2>/dev/null | head -1 | cut -d= -f2)

[ -z "$EXPECTED_IP" ] || [ -z "$GATEWAY" ] && exit 0

CURRENT_IP=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

if [ "$CURRENT_IP" != "$EXPECTED_IP" ]; then
    logger -t isx-watchdog "IP mismatch: expected=$EXPECTED_IP current=$CURRENT_IP, restarting networkd"
    systemctl restart systemd-networkd
    exit 0
fi

if ! ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then
    logger -t isx-watchdog "Gateway $GATEWAY unreachable, restarting networkd"
    systemctl restart systemd-networkd
fi
WDEOF
chmod +x "${ROOTFS}/usr/local/bin/isx-network-watchdog"

cat > "${ROOTFS}/etc/systemd/system/isx-network-watchdog.service" << 'SVCEOF'
[Unit]
Description=incus-spawn network connectivity watchdog
After=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/isx-network-watchdog
SVCEOF

cat > "${ROOTFS}/etc/systemd/system/isx-network-watchdog.timer" << 'TMREOF'
[Unit]
Description=incus-spawn network watchdog timer

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
TMREOF
chroot "${ROOTFS}" systemctl enable isx-network-watchdog.timer

# Configure bash prompt (ISX window title) and bash-completion
cat >> "${ROOTFS}/home/agentuser/.bashrc" << 'BASHEOF'
PROMPT_COMMAND="printf '\033]0;isx:%s\007' \"${HOSTNAME}\""
if [ -f /usr/share/bash-completion/bash_completion ]; then
  . /usr/share/bash-completion/bash_completion
fi
BASHEOF
chroot "${ROOTFS}" chown agentuser:agentuser /home/agentuser/.bashrc

# Strip non-essential files to minimize image size (keep directory structure
# intact — rpm %post scripts using the alternatives system create symlinks
# under /usr/share/man/man*/ and fail if those directories are missing)
echo "Stripping non-essential files..."
find "${ROOTFS}/usr/share/doc" "${ROOTFS}/usr/share/man" "${ROOTFS}/usr/share/info" -type f -delete 2>/dev/null || true
rm -rf "${ROOTFS}/usr/share/licenses" "${ROOTFS}/usr/share/groff"

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
echo "Output: ${TARBALL}"
echo "=== Done ==="
