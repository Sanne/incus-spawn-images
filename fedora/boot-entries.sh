#!/bin/bash
# Give every boot entry in a VM image the options in its /etc/kernel/cmdline.
#
# The stock image's entry for its kernel says `options $kernelopts`, which the
# EFI system partition's grub.cfg fills in from a fallback of its own (it reads
# no grubenv), while every kernel installed later gets the literal contents of
# /etc/kernel/cmdline from kernel-install. Writing those same contents into every
# entry, as kernel-install itself would, leaves one place that decides what every
# kernel boots with: kernel-cmdline.sh's (Sanne/incus-spawn#1217, #1238). An
# entry's options become one line; nothing else in it changes.
#
# Usage: boot-entries.sh <image-root>
# Without /etc/kernel/cmdline there is nothing to copy, and nothing changes.
set -euo pipefail

ROOT="${1:?Usage: $0 <image-root>}"
CMDLINE="${ROOT}/etc/kernel/cmdline"

[ -f "${CMDLINE}" ] || exit 0

# kernel-install joins every line of the file, so do the same.
read -r -d '' -a OPTIONS < "${CMDLINE}" || true
[ ${#OPTIONS[@]} -gt 0 ] || { echo "Error: ${CMDLINE} is empty" >&2; exit 1; }

for entry in "${ROOT}"/boot/loader/entries/*.conf; do
  [ -f "${entry}" ] || continue
  # The first options line becomes the file's options, later ones go. ENVIRON,
  # unlike awk -v, takes the options as they are, backslashes included.
  OPTS="${OPTIONS[*]}" awk '
    /^options([[:space:]]|$)/ { if (!done) print "options " ENVIRON["OPTS"]; done = 1; next }
    { print }' "${entry}" > "${entry}.new"
  mv "${entry}.new" "${entry}"
done
