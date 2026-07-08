#!/bin/bash
set -euo pipefail

# Build a prebaked Fedora VM image for incus-spawn.
#
# Downloads the stock Incus Fedora VM image (which already has the
# incus-agent, bootloader, and kernel set up), applies incus-spawn
# base configuration via virt-customize, and repackages as an Incus
# VM tarball.
#
# Usage: ./build-vm.sh <output-dir>
#
# Dependencies (Fedora): dnf install libguestfs-tools-c qemu-img jq curl
# Dependencies (Ubuntu): apt install libguestfs-tools qemu-utils jq curl

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:?Usage: $0 <output-dir>}"
ARCH=$(uname -m)
RELEASE=44
IMAGE_SERVER="https://images.linuxcontainers.org"

# --- Dependency check ---
MISSING=()
for cmd in virt-customize qemu-img jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: missing required tools: ${MISSING[*]}"
  echo ""
  echo "Install them with:"
  echo "  Fedora: dnf install libguestfs-tools-c qemu-img jq curl"
  echo "  Ubuntu: apt install libguestfs-tools qemu-utils jq curl"
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

# --- Download and customize ---
STAGING=$(mktemp -d /tmp/vm-image-XXXXXX)
trap 'rm -rf "${STAGING}"' EXIT

echo "Downloading stock VM disk..."
curl -fL --progress-bar -o "${STAGING}/disk.qcow2" "${DISK_URL}"

echo "Expanding disk to 10G..."
qemu-img resize "${STAGING}/disk.qcow2" 10G

echo "Installing packages and applying base configuration..."
virt-customize -a "${STAGING}/disk.qcow2" \
  --run-command 'growpart /dev/sda 2 && resize2fs /dev/sda2 || xfs_growfs / || true' \
  --install systemd-networkd,dnf5,glibc-langpack-en,bash-completion,git,curl,which,procps-ng,findutils,iproute,iputils,cloud-utils-growpart,e2fsprogs,xfsprogs \
  --run-command 'dnf -y remove glibc-all-langpacks geolite2-city geolite2-country 2>/dev/null; true' \
  --run "${SCRIPT_DIR}/configure-base.sh"

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
