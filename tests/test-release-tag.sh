#!/bin/bash
# Runs .github/scripts/release-tag.sh, which build-fedora.yml's release job uses to
# name its tag, against lists of existing tags. Needs nothing but bash.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/scripts/release-tag.sh"
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# run <existing tags, one per line> [channel]: the tag for a release on 2026-10-12
run() { printf '%s' "$1" | bash "$SCRIPT" 44 20261012 ${2:+"$2"} 2>&1; }

# expect <name> <existing tags> <expected tag> [channel]
expect() {
    local got
    if ! got="$(run "$2" ${4:+"$4"})"; then
        fail "$1: exited non-zero: $got"
        return
    fi
    [ "$got" = "$3" ] || fail "$1: got '$got', want '$3'"
}

# refuse <name> <existing tags> <channel> <message part>
refuse() {
    local got
    if got="$(run "$2" "$3")"; then
        fail "$1: published under '$got'"
    elif [[ "$got" != *"$4"* ]]; then
        fail "$1: failed for another reason: $got"
    fi
}

expect "first of the day" "fedora-44-20261011
" fedora-44-20261012
expect "no tags yet" "" fedora-44-20261012
# Sanne/incus-spawn-images#24: a second run on 2026-10-12 re-uploaded every asset
# of fedora-44-20261012, which incus-spawn had already pinned.
expect "second of the day" "fedora-44-20261011
fedora-44-20261012
" fedora-44-20261012-2
expect "third of the day" "fedora-44-20261012
fedora-44-20261012-2
" fedora-44-20261012-3
expect "last tag without a newline" "fedora-44-20261012" fedora-44-20261012-2
# Sanne/incus-spawn#1994: a channel is part of the line, before the date, and is
# numbered within its own line only.
expect "channel" "fedora-44-20261012
" fedora-44-next-20261012 next
expect "channel, second of the day" "fedora-44-20261012
fedora-44-next-20261012
" fedora-44-next-20261012-2 next
expect "stable beside a channel" "fedora-44-next-20261012
" fedora-44-20261012
refuse "channel with a digit" "" next2 "lower-case letters only"
refuse "channel with a dash" "" a-b "lower-case letters only"
refuse "channel in capitals" "" Next "lower-case letters only"
for args in "44 2026101" "4x 20261012" "" ; do
    # shellcheck disable=SC2086
    if bash "$SCRIPT" $args < /dev/null > /dev/null 2>&1; then
        fail "usage '$args': accepted"
    fi
done

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi
echo "All release tag checks passed."
