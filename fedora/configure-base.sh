#!/bin/bash
set -euo pipefail

# Configure the incus-spawn base system.
#
# Runs inside the target filesystem — either via chroot (container build)
# or directly in a kickstart %post (VM build). Assumes packages are already
# installed; this script only does post-install configuration.

echo "Creating agentuser..."
useradd -m -u 1000 -G systemd-journal agentuser
chown -R agentuser:agentuser /home/agentuser
mkdir -p /home/agentuser/inbox
chown agentuser:agentuser /home/agentuser/inbox
echo 'agentuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/agentuser

echo "Masking systemd services..."
systemctl mask \
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
# inside the user namespace.
mkdir -p /etc/tmpfiles.d
printf '# Container override: skip static device node permissions.\n# Host-injected device nodes cannot be fchmod'"'"'d inside the user namespace.\n' \
  > /etc/tmpfiles.d/static-nodes-permissions.conf

# Patch nsswitch.conf: remove mDNS resolve entry so .local domains use dnsmasq.
sed -i 's/resolve \[!UNAVAIL=return\] //' /etc/nsswitch.conf
rm -f /etc/resolv.conf

echo "Enabling systemd-networkd..."
mkdir -p /etc/systemd/network
systemctl enable systemd-networkd

echo "Installing network watchdog..."
mkdir -p /etc/systemd/system
cat > /usr/local/bin/isx-network-watchdog << 'WDEOF'
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
chmod +x /usr/local/bin/isx-network-watchdog

cat > /etc/systemd/system/isx-network-watchdog.service << 'SVCEOF'
[Unit]
Description=incus-spawn network connectivity watchdog
After=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/isx-network-watchdog
SVCEOF

cat > /etc/systemd/system/isx-network-watchdog.timer << 'TMREOF'
[Unit]
Description=incus-spawn network watchdog timer

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
TMREOF
systemctl enable isx-network-watchdog.timer

cat >> /home/agentuser/.bashrc << 'BASHEOF'
PROMPT_COMMAND="printf '\033]0;isx:%s\007' \"${HOSTNAME}\""
if [ -f /usr/share/bash-completion/bash_completion ]; then
  . /usr/share/bash-completion/bash_completion
fi
BASHEOF
chown agentuser:agentuser /home/agentuser/.bashrc

echo "Stripping non-essential files..."
find /usr/share/doc /usr/share/man /usr/share/info -type f -delete 2>/dev/null || true
rm -rf /usr/share/licenses /usr/share/groff

echo "Cleaning caches..."
dnf clean all 2>/dev/null || true
rm -rf /var/cache/libdnf5 /tmp/* /var/tmp/*
rm -rf /var/log/*
