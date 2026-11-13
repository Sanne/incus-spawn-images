#!/bin/bash
# Prints the tag a release is published under, never one that already exists: a
# published tag is immutable, since incus-spawn pins the checksums of its assets.
#
# Usage: release-tag.sh <release> <YYYYMMDD> [channel] < existing tag names
#
# Every tag is generated here, never typed (Sanne/incus-spawn#1994):
#
#   fedora-<release>[-<channel>]-<YYYYMMDD>[-<n>]
#
# The line is everything before the date: fedora-45 is the stable line, and
# fedora-45-next a channel of it. isx orders tags only within a line, by date and
# then <n>, and follows only the stable line by itself; another line is never
# newer or older. A channel is lower-case letters only, so the line always ends
# where the date starts.
#
# A later release on the same day gets -2, -3 and so on: isx takes the newest of
# its line, and so does the upstream watch.
set -euo pipefail

release="$1" date="$2" channel="${3:-}"
if ! [[ "$release" =~ ^[0-9]{1,9}$ && "$date" =~ ^[0-9]{8}$ ]]; then
    echo "Usage: release-tag.sh <release> <YYYYMMDD> [channel] < existing tag names" >&2
    exit 2
fi
if [ -n "$channel" ] && ! [[ "$channel" =~ ^[a-z]+$ ]]; then
    echo "Channel '$channel' is not lower-case letters only (such as 'next'); leave it empty for the stable line." >&2
    exit 1
fi
declare -A existing=()
while IFS= read -r tag || [ -n "$tag" ]; do
    [ -n "$tag" ] && existing["$tag"]=1
done

base="fedora-$release${channel:+-$channel}-$date"
tag="$base"
n=2
while [ -n "${existing[$tag]:-}" ]; do
    tag="$base-$n"
    n=$((n + 1))
done
echo "$tag"
