#!/bin/bash
# Runs fedora/boot-entries.sh, which build-vm.sh uses to give the VM image's own
# boot entry the options in /etc/kernel/cmdline, against copies of what the stock
# Incus image ships. Needs nothing but bash: no root, no loop device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/fedora/boot-entries.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UUID=ce628afb-bfaa-47dd-8d27-275b47264e4a
OPTS="root=UUID=$UUID ro console=tty1 console=ttyS0 loglevel=5"
KVER=7.2.9-200.fc44.x86_64
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# A BLS entry as the stock image ships it, with options line $1
entry() {
    printf 'title Fedora Linux (%s) 44 (Container Image)\nversion %s\nlinux /boot/vmlinuz-%s\ninitrd /boot/initramfs-%s.img\n%s\ngrub_users $grub_users\ngrub_arg --unrestricted\ngrub_class fedora\n' \
        "$KVER" "$KVER" "$KVER" "$KVER" "$1"
}

# image <cmdline content, or empty for none> <options line of each entry>...
image() {
    rm -rf "$WORK/img"
    mkdir -p "$WORK/img/etc/kernel" "$WORK/img/boot/loader/entries"
    [ -z "$1" ] || printf '%s\n' "$1" > "$WORK/img/etc/kernel/cmdline"
    shift
    local n=0
    for opts in "$@"; do
        n=$((n + 1))
        entry "$opts" > "$WORK/img/boot/loader/entries/m$n-$KVER.conf"
    done
}

run() {
    bash "$SCRIPT" "$WORK/img" > "$WORK/out" 2>&1 || fail "$1: exited non-zero: $(cat "$WORK/out")"
}

# expect <name> <entry number> <options line>: that entry is the stock one but for its options
expect() {
    local want
    want="$(entry "$3")"
    [ "$(cat "$WORK/img/boot/loader/entries/m$2-$KVER.conf")" = "$want" ] \
        || fail "$1: entry $2 is '$(cat "$WORK/img/boot/loader/entries/m$2-$KVER.conf")'"
}

# The stock entry: $kernelopts, filled in from grub.cfg's fallback, becomes the
# literal options every later kernel gets; nothing else in the entry changes.
image "$OPTS" 'options $kernelopts'
run "stock"
expect "stock" 1 "options $OPTS"

# Running it again changes nothing.
run "second run"
expect "second run" 1 "options $OPTS"

# An entry that lists other options gets the file's too: one file decides.
image "$OPTS" 'options $kernelopts' "options root=UUID=$UUID ro"
run "literal entry"
expect "literal entry: stock" 1 "options $OPTS"
expect "literal entry: rewritten" 2 "options $OPTS"

# BLS joins several options lines; they become the one line.
image "$OPTS" $'options root=UUID='"$UUID"$' ro\noptions $tuned_params'
run "several options lines"
expect "several options lines" 1 "options $OPTS"

# kernel-install joins every line of the cmdline file.
image $'root=UUID='"$UUID"$' ro\nloglevel=5' 'options $kernelopts'
run "multi-line"
expect "multi-line" 1 "options root=UUID=$UUID ro loglevel=5"

# Options sed would read as its own syntax arrive as they are.
image "root=UUID=$UUID ro a=b&c x=/dev/sda2 y=\\1|z" 'options $kernelopts'
run "special characters"
expect "special characters" 1 "options root=UUID=$UUID ro a=b&c x=/dev/sda2 y=\\1|z"

# No cmdline file: nothing to copy, the entry keeps $kernelopts.
image "" 'options $kernelopts'
run "no cmdline"
expect "no cmdline" 1 'options $kernelopts'

# An empty cmdline file would leave the stock kernel with no root: refuse.
image "" 'options $kernelopts'
: > "$WORK/img/etc/kernel/cmdline"
if bash "$SCRIPT" "$WORK/img" > "$WORK/out" 2>&1; then fail "empty cmdline: accepted"; fi
expect "empty cmdline" 1 'options $kernelopts'

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "All boot entry checks passed"
