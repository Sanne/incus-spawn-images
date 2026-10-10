#!/bin/bash
# Runs fedora/kernel-cmdline.sh, which build-vm.sh uses to pin the VM image's
# /etc/kernel/cmdline to its root filesystem, against copies of what the stock
# Incus image ships. Needs nothing but bash: no root, no loop device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/fedora/kernel-cmdline.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UUID=ce628afb-bfaa-47dd-8d27-275b47264e4a
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# expect <name> <file content> <expected content after the rewrite>
expect() {
    printf '%s\n' "$2" > "$WORK/cmdline"
    if ! bash "$SCRIPT" "$WORK/cmdline" "$UUID" > "$WORK/out" 2>&1; then
        fail "$1: exited non-zero: $(cat "$WORK/out")"
        return
    fi
    local got
    got="$(cat "$WORK/cmdline")"
    [ "$got" = "$3" ] || fail "$1: got '$got', want '$3'"
}

# What images.linuxcontainers.org ships: distrobuilder's loop device, recorded
# while it built the image (Sanne/incus-spawn#1217). A kernel installed later
# gets a boot entry with this root, and the guest waits for it forever.
expect "stock loop device" \
    "root=/dev/loop0p2 ro   console=tty1 console=ttyS0" \
    "root=UUID=$UUID ro console=tty1 console=ttyS0 loglevel=5"
expect "other loop device" \
    "root=/dev/loop1p2 ro   console=tty1 console=ttyS0" \
    "root=UUID=$UUID ro console=tty1 console=ttyS0 loglevel=5"
expect "root last" \
    "ro console=ttyS0 root=/dev/loop0p2" \
    "ro console=ttyS0 root=UUID=$UUID loglevel=5"
expect "no root at all" \
    "ro console=tty1 console=ttyS0" \
    "root=UUID=$UUID ro console=tty1 console=ttyS0 loglevel=5"
expect "already right" \
    "root=UUID=$UUID ro console=tty1 console=ttyS0" \
    "root=UUID=$UUID ro console=tty1 console=ttyS0 loglevel=5"
# Only the root= option is replaced, not options that merely end in "root=".
expect "rootflags kept" \
    "root=/dev/loop0p2 rootflags=noatime ro" \
    "root=UUID=$UUID rootflags=noatime ro loglevel=5"
# kernel-install reads every line of the file; options after the first survive.
expect "multi-line" \
    $'root=/dev/loop0p2 ro\nconsole=ttyS0' \
    "root=UUID=$UUID ro console=ttyS0 loglevel=5"

# A log level someone already chose is kept, not overridden or doubled
# (Sanne/incus-spawn#1238); one that merely ends in "loglevel=" is not a level.
expect "own log level" \
    "root=/dev/loop0p2 ro loglevel=7 console=ttyS0" \
    "root=UUID=$UUID ro loglevel=7 console=ttyS0"
expect "own log level on a later line" \
    $'root=/dev/loop0p2 ro\nloglevel=3' \
    "root=UUID=$UUID ro loglevel=3"
expect "quiet is a level" \
    $'root=/dev/loop0p2 ro\nquiet' \
    "root=UUID=$UUID ro quiet"
expect "debug is a level" \
    "root=/dev/loop0p2 debug ro" \
    "root=UUID=$UUID debug ro"
expect "an option merely containing quiet is not" \
    "root=/dev/loop0p2 ro rd.udev.log_level=quiet" \
    "root=UUID=$UUID ro rd.udev.log_level=quiet loglevel=5"
expect "initrd log level is not the kernel's" \
    "root=/dev/loop0p2 ro rd.loglevel=1" \
    "root=UUID=$UUID ro rd.loglevel=1 loglevel=5"
# Running it again changes nothing: the option is not stacked.
expect "second run" \
    "root=UUID=$UUID ro console=ttyS0 loglevel=5" \
    "root=UUID=$UUID ro console=ttyS0 loglevel=5"

# kernel-install and editors may leave the line without a newline.
printf 'root=/dev/loop0p2 ro' > "$WORK/cmdline"
bash "$SCRIPT" "$WORK/cmdline" "$UUID" > "$WORK/out" 2>&1 || fail "no newline: exited non-zero: $(cat "$WORK/out")"
grep -qx "root=UUID=$UUID ro loglevel=5" "$WORK/cmdline" || fail "no newline: got $(cat "$WORK/cmdline")"

# No file: nothing to rewrite, and none is created (kernel-install then falls back
# to the running guest's /proc/cmdline, which names the right root).
rm -f "$WORK/cmdline"
bash "$SCRIPT" "$WORK/cmdline" "$UUID" > "$WORK/out" 2>&1 || fail "missing file: exited non-zero: $(cat "$WORK/out")"
[ ! -e "$WORK/cmdline" ] || fail "missing file: created $(cat "$WORK/cmdline")"

# A UUID that is not one must stop the build, not be written.
for bad in "" "---" "ce628afb" "ce628afb-bfaa-47dd-8d27-275b47264e4a0" "/dev/sda2"; do
    printf 'root=/dev/loop0p2 ro\n' > "$WORK/cmdline"
    if bash "$SCRIPT" "$WORK/cmdline" "$bad" > "$WORK/out" 2>&1; then
        fail "UUID '$bad': accepted"
    fi
    grep -qx 'root=/dev/loop0p2 ro' "$WORK/cmdline" || fail "UUID '$bad': file changed to $(cat "$WORK/cmdline")"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "All kernel cmdline checks passed"
