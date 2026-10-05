#!/bin/bash
# Runs the isx-network-watchdog that configure-base.sh installs against stubbed
# `ip`, `ping`, `logger` and `systemctl`, and checks when it restarts networkd.
# Needs nothing but bash: no root, no container, no network. Where iproute2 is
# installed, it also runs the watchdog once against the real `ip`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The watchdog is a heredoc in configure-base.sh; test exactly what the image gets,
# with only the network file path pointed into the scratch directory.
sed -n "/<< 'WDEOF'$/,/^WDEOF$/{//!p}" "$ROOT/fedora/configure-base.sh" \
    | sed "s|/etc/systemd/network/10-eth0.network|$WORK/10-eth0.network|" \
    > "$WORK/watchdog"
grep -q "$WORK/10-eth0.network" "$WORK/watchdog" || { echo "could not extract the watchdog" >&2; exit 1; }

# The watchdog runs with nothing on PATH but the stubs and these: tools the container
# image ships. It has no awk (minimal install, no weak deps), and a watchdog that used
# it read an empty address and restarted networkd on every run.
mkdir "$WORK/bin"
for tool in grep head cut tr; do
    ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done

# `ip -4 [-o|-br] addr show [scope global] [to <address>] [[dev] <link>]` prints
# $WORK/ip-addrs ("<link> <address/prefix>" per line) in iproute2's one-line or brief
# format. Like iproute2, `to` with a bare address matches only that address, and a link
# name limits it to that link (so a watchdog asking for eth0 alone sees what it would on
# a real guest). Bash only, since awk is not on the PATH either.
cat > "$WORK/bin/ip" << STUB
#!/bin/bash
brief= to= dev=
while [ \$# -gt 0 ]; do
    case "\$1" in
        -4|-o|addr|show) ;;
        -br) brief=1 ;;
        scope) shift ;;
        to) shift; to="\$1" ;;
        dev) shift; dev="\$1" ;;
        *) dev="\$1" ;;
    esac
    shift
done
n=1
while read -r link addr; do
    [ -n "\$link" ] || continue
    [ -z "\$dev" ] || [ "\$dev" = "\$link" ] || continue
    [ -z "\$to" ] || [ "\$to" = "\${addr%/*}" ] || continue
    if [ -n "\$brief" ]; then
        echo "\$link       UP             \$addr "
    else
        echo "\$n: \$link    inet \$addr brd 0.0.0.255 scope global \$link\\       valid_lft forever preferred_lft forever"
    fi
    n=\$((n + 1))
done < "$WORK/ip-addrs"
STUB
cat > "$WORK/bin/ping" << STUB
#!/bin/bash
[ -e "$WORK/gateway-up" ]
STUB
cat > "$WORK/bin/logger" << STUB
#!/bin/bash
echo "\$*" >> "$WORK/log"
STUB
cat > "$WORK/bin/systemctl" << STUB
#!/bin/bash
echo "\$*" >> "$WORK/restarts"
STUB
chmod +x "$WORK/bin/ip" "$WORK/bin/ping" "$WORK/bin/logger" "$WORK/bin/systemctl"

failures=0

# check <name> <expected restarts: 0|1> <ip-addrs content> [network file content]
check() {
    local name="$1" want="$2" addrs="$3" network="${4-$'[Network]\nAddress=10.100.229.2/24\nGateway=10.100.229.1'}"
    rm -f "$WORK/log"
    : > "$WORK/restarts"
    printf '%s\n' "$addrs" > "$WORK/ip-addrs"
    printf '%s\n' "$network" > "$WORK/10-eth0.network"
    PATH="$WORK/bin" /bin/bash "$WORK/watchdog" 2> "$WORK/stderr" || true
    local got
    got=$(wc -l < "$WORK/restarts")
    if [ "$got" = "$want" ] && [ ! -s "$WORK/stderr" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: expected $want networkd restart(s), got $got"
        [ -s "$WORK/log" ] && sed 's/^/     log: /' "$WORK/log"
        [ -s "$WORK/stderr" ] && sed 's/^/     stderr: /' "$WORK/stderr"
        failures=$((failures + 1))
    fi
}

touch "$WORK/gateway-up"
check "container: address on eth0" 0 "eth0 10.100.229.2/24"
check "VM: address on enp5s0" 0 "enp5s0 10.100.229.2/24"
check "VM: address on enp5s0 beside another link" 0 $'docker0 172.17.0.1/16\nenp5s0 10.100.229.2/24'
check "address lost" 1 "enp5s0 10.100.229.9/24"
# iproute2's brief format ends each line with a space; the log line should not carry it.
if grep -qx -- '-t isx-watchdog IP mismatch: expected=10.100.229.2 current=enp5s0 UP 10.100.229.9/24, restarting networkd' "$WORK/log"; then
    echo "ok   address lost: log line"
else
    echo "FAIL address lost: log line"
    sed 's/^/     log: /' "$WORK/log"
    failures=$((failures + 1))
fi
check "no address at all" 1 ""
check "address only a prefix of another" 1 "enp5s0 10.100.229.20/24"
check "no static address configured" 0 "" $'[Network]\nDHCP=yes'
rm "$WORK/gateway-up"
check "address held, gateway unreachable" 1 "enp5s0 10.100.229.2/24"

# The stub's model of `to` is an assumption about iproute2. Anchor it: run the same
# watchdog against the real `ip` and this machine's loopback, which holds 127.0.0.1/8
# and no other 127.x address. Skipped where there is no `ip` (set REQUIRE_REAL_IP=1
# to fail instead, as CI does).
if real_ip=$(command -v ip); then
    ln -sf "$real_ip" "$WORK/bin/ip"
    touch "$WORK/gateway-up"
    check "real ip: address held" 0 "" $'[Network]\nAddress=127.0.0.1/8\nGateway=127.0.0.1'
    check "real ip: address only in the held one's subnet" 1 "" $'[Network]\nAddress=127.0.0.2/8\nGateway=127.0.0.1'
elif [ "${REQUIRE_REAL_IP:-}" = 1 ]; then
    echo "FAIL real ip: no ip on PATH"
    failures=$((failures + 1))
else
    echo "skip real ip: no ip on PATH"
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
