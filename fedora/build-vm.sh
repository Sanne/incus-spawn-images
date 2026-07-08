#!/bin/bash
set -euo pipefail

# Build a prebaked Fedora VM image for incus-spawn.
#
# Downloads the stock Incus Fedora VM image (which already has the
# incus-agent, bootloader, and kernel set up), mounts it via qemu-nbd,
# installs packages and applies configuration, then repackages as an
# Incus VM tarball.
#
# Usage: ./build-vm.sh <output-dir>
#
# Dependencies: qemu-utils (qemu-img, qemu-nbd), jq, curl
# Must run as root (for nbd mount).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:?Usage: $0 <output-dir>}"
ARCH=$(uname -m)
RELEASE=44
IMAGE_SERVER="https://images.linuxcontainers.org"

# --- Dependency check ---
MISSING=()
for cmd in qemu-img qemu-nbd jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: missing required tools: ${MISSING[*]}"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root (need nbd + mount)"
  exit 1
fi

# Map uname arch to simplestreams arch
case "${ARCH}" in
  x86_64)  SS_ARCH=amd64 ;;
  aarch64) SS_ARCH=arm64 ;;
  *)
    echo "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

# --- Find the latest stock Incus Fedora VM image ---
echo "=== Building Fedora ${RELEASE} VM image (${ARCH}) ==="
echo "Querying image server for latest Fedora ${RELEASE} VM image..."

PRODUCT="fedora:${RELEASE}:${SS_ARCH}:default"
DISK_PATH=$(curl -sfL "${IMAGE_SERVER}/streams/v1/images.json" \
  | jq -r ".products[\"${PRODUCT}\"].versions | to_entries | sort_by(.key) | last | .value.items[\"disk.qcow2\"].path")

if [ -z "${DISK_PATH}" ] || [ "${DISK_PATH}" = "null" ]; then
  echo "Error: could not find VM disk image for ${PRODUCT}"
  exit 1
fi

DISK_URL="${IMAGE_SERVER}/${DISK_PATH}"
echo "Found: ${DISK_URL}"

# --- Download ---
STAGING=$(mktemp -d /tmp/vm-image-XXXXXX)
MOUNTPOINT=$(mktemp -d /tmp/vm-mount-XXXXXX)
NBD_DEV=""

cleanup() {
  set +e
  if [ -n "${NBD_DEV}" ]; then
    umount "${MOUNTPOINT}/dev/pts" 2>/dev/null
    umount "${MOUNTPOINT}/dev" 2>/dev/null
    umount "${MOUNTPOINT}/proc" 2>/dev/null
    umount "${MOUNTPOINT}/sys" 2>/dev/null
    umount "${MOUNTPOINT}/run" 2>/dev/null
    umount "${MOUNTPOINT}" 2>/dev/null
    qemu-nbd --disconnect "${NBD_DEV}" 2>/dev/null
  fi
  rm -rf "${STAGING}" "${MOUNTPOINT}"
}
trap cleanup EXIT

echo "Downloading stock VM disk..."
curl -fL --progress-bar -o "${STAGING}/disk.qcow2" "${DISK_URL}"

echo "Expanding disk to 10G..."
qemu-img resize "${STAGING}/disk.qcow2" 10G

# --- Mount via qemu-nbd ---
echo "Mounting disk image..."
modprobe nbd max_part=8 2>/dev/null || true

# Find a free nbd device
for dev in /dev/nbd{0..7}; do
  if ! lsblk "${dev}" &>/dev/null; then
    NBD_DEV="${dev}"
    break
  fi
done
if [ -z "${NBD_DEV}" ]; then
  echo "Error: no free nbd device found"
  exit 1
fi

qemu-nbd --connect="${NBD_DEV}" "${STAGING}/disk.qcow2"
sleep 1
partprobe "${NBD_DEV}" 2>/dev/null || true
sleep 1

# Find the root partition (the largest one, typically partition 2)
ROOT_PART=$(lsblk -ln -o NAME,SIZE "${NBD_DEV}" | tail -n +2 | sort -k2 -h | tail -1 | awk '{print $1}')
ROOT_DEV="/dev/${ROOT_PART}"

echo "Root partition: ${ROOT_DEV}"

# Grow the partition and filesystem
growpart "${NBD_DEV}" 2 || true
e2fsck -fy "${ROOT_DEV}" 2>/dev/null || true
resize2fs "${ROOT_DEV}" 2>/dev/null || xfs_growfs "${ROOT_DEV}" 2>/dev/null || true

mount "${ROOT_DEV}" "${MOUNTPOINT}"

# --- Install packages via chroot ---
echo "Installing packages..."

# Bind-mount host resources for chroot
mount --bind /dev "${MOUNTPOINT}/dev"
mount --bind /dev/pts "${MOUNTPOINT}/dev/pts"
mount -t proc proc "${MOUNTPOINT}/proc"
mount -t sysfs sysfs "${MOUNTPOINT}/sys"
mount -t tmpfs tmpfs "${MOUNTPOINT}/run"

# Use host DNS inside chroot
cp /etc/resolv.conf "${MOUNTPOINT}/etc/resolv.conf" 2>/dev/null || \
  echo "nameserver 8.8.8.8" > "${MOUNTPOINT}/etc/resolv.conf"

PACKAGES="systemd-networkd dnf5 glibc-langpack-en bash-completion git curl which procps-ng findutils iproute iputils cloud-utils-growpart e2fsprogs xfsprogs"

chroot "${MOUNTPOINT}" /bin/bash -c "dnf -y install ${PACKAGES}"
chroot "${MOUNTPOINT}" /bin/bash -c "dnf -y remove glibc-all-langpacks geolite2-city geolite2-country 2>/dev/null; true"

# --- Apply base configuration ---
echo "Applying base configuration..."
cp "${SCRIPT_DIR}/configure-base.sh" "${MOUNTPOINT}/tmp/configure-base.sh"
chroot "${MOUNTPOINT}" /bin/bash /tmp/configure-base.sh
rm -f "${MOUNTPOINT}/tmp/configure-base.sh"

# --- Unmount ---
echo "Unmounting..."
umount "${MOUNTPOINT}/dev/pts"
umount "${MOUNTPOINT}/dev"
umount "${MOUNTPOINT}/proc"
umount "${MOUNTPOINT}/sys"
umount "${MOUNTPOINT}/run"
umount "${MOUNTPOINT}"
qemu-nbd --disconnect "${NBD_DEV}"
NBD_DEV=""

# --- Repackage as Incus VM tarball ---
echo "Compressing disk image..."
qemu-img convert -c -f qcow2 -O qcow2 "${STAGING}/disk.qcow2" "${STAGING}/rootfs.img"
rm -f "${STAGING}/disk.qcow2"

echo "Packaging VM image..."
CREATION_DATE=$(date +%s)
cat > "${STAGING}/metadata.yaml" << EOF
architecture: ${ARCH}
creation_date: ${CREATION_DATE}
properties:
  description: Fedora ${RELEASE} VM base for incus-spawn
  os: Fedora
  release: "${RELEASE}"
  variant: incus-spawn-base-vm
EOF

mkdir -p "${OUTPUT}"
VM_TARBALL="${OUTPUT}/fedora-${RELEASE}-${ARCH}-vm.tar.xz"
tar -cJf "${VM_TARBALL}" -C "${STAGING}" metadata.yaml rootfs.img

sha256sum "${VM_TARBALL}" | awk '{print $1}' > "${VM_TARBALL}.sha256"
echo "SHA256: $(cat "${VM_TARBALL}.sha256")"
echo "VM output: ${VM_TARBALL}"
