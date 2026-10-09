#!/bin/bash
# Pin the root in a VM image's /etc/kernel/cmdline to its root filesystem's UUID.
#
# The stock Incus Fedora VM image ships this file with the loop device
# distrobuilder built it on (root=/dev/loop0p2). The image's own boot entry uses
# $kernelopts and boots, but kernel-install writes the entry for any kernel
# installed later (a template's `dnf upgrade`) from this file, and a guest
# booting that entry waits forever for a device that does not exist
# (Sanne/incus-spawn#1217). Every other option is kept as it is.
#
# Usage: kernel-cmdline.sh <cmdline-file> <root-fs-uuid>
# Without the file there is nothing to fix: kernel-install then uses the running
# guest's /proc/cmdline.
set -euo pipefail

FILE="${1:?Usage: $0 <cmdline-file> <root-fs-uuid>}"
UUID="${2:-}"

# The root is ext4 or xfs, whose UUIDs are always 8-4-4-4-12 hex digits.
if ! [[ "${UUID}" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
  echo "Error: '${UUID}' is not a filesystem UUID" >&2
  exit 1
fi

[ -e "${FILE}" ] || exit 0

# kernel-install reads every line, so read them all (-d ''); read then reports
# end of file as a failure, though it still splits what it read.
read -r -d '' -a OPTIONS < "${FILE}" || true

# The root stays where it was in the line, or goes first if there was none.
NEW=()
placed=
for opt in "${OPTIONS[@]}"; do
  if [[ "${opt}" == root=* ]]; then
    [ -n "${placed}" ] || NEW+=("root=UUID=${UUID}")
    placed=1
  else
    NEW+=("${opt}")
  fi
done
[ -n "${placed}" ] || NEW=("root=UUID=${UUID}" "${NEW[@]}")

echo "${NEW[*]}" > "${FILE}"
