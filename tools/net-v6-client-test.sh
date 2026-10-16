#!/bin/sh
# Put a real IPv6 client on the hotspot and follow its traffic end to end.
#
# Run it on the device:  net-v6-client-test.sh [br-wifi]
#
# ⚠⚠ MEASURED 2026-10-13: THIS TOOL HAS PANICKED THE KERNEL. Run it only when you accept that the
# phone may reboot, and prefer a real Wi-Fi client for anything you care about.
#
# What happened: the run that removed the bridge port / tore the namespace down (the teardown half,
# not the traffic) ended in `Unable to handle kernel paging request at virtual address
# dead000000000100` in `kmem_cache_alloc_trace` <- `scs_alloc` <- `copy_process` <-
# `call_usermodehelper_exec_work`, i.e. an Oops in the *fork* path on an unrelated kworker, seconds
# after the netdev event burst. The next boot read `bootcause="Reboot into ap watchdog"`. The full
# console is in changxing60-linux/docs/FINDINGS.md §33. Nothing in the packet path is suspected -- the
# device-side veth peer `$Vp` entering and leaving the bridge is what the kernel's vendor `sipa`
# netdev notifier sees, and every `sipa_dummy: dev ... evt ...` line in that boot belonged to it.
#
# So: a real phone on the hotspot (the real thing this verifies) does not add or remove a bridge
# port, and the AP has run for days of client traffic without this. Treat this tool as bench
# equipment with a known hazard, and leave the phone alone after a run -- if it is going to panic,
# it panics within seconds, not later.
#
# A veth pair dropped into the bridge is a client as far as the bridge, odhcpd and the firewall are
# concerned -- but only if it lives in its own network namespace. In the device's own namespace the
# relayed router advertisement would be taken by the device itself: its SLAAC address and its default
# route would land in the main table, the packet would be locally generated, and the test would skip
# the whole FORWARD + NAT66 + return-route path that a real client needs. In a namespace nothing is
# shared, so the packet is forwarded exactly like a phone on the Wi-Fi.
#
# What each result means:
#   a global address out of the carrier's /64  <- odhcpd relays the carrier's RA onto br-wifi
#   a default route via br-wifi's link-local   <- br-wifi is the client's router, so NAT66 must rewrite
#   ping6 to a public v6 host succeeds         <- masq6 egress and the /64 route back (ndp-learn)
#   the AAAA lookup succeeds                   <- IPv6 is not just reachable, it is usable: the failure
#                                                 this guards against is an IPv6 network whose name
#                                                 resolution silently returns nothing
# The RA the client is given is captured whole (prefix, flags, lifetimes, RDNSS): that is what a phone
# on the hotspot actually bases its decisions on, and the flags are the part no config file shows.
# Nothing is added to the device's own tables; the namespace is removed on exit unless --keep is given.
set -e

BR=br-wifi
KEEP=0
for a in "$@"; do
	case $a in
		--keep) KEEP=1 ;;
		-*) echo "usage: $0 [br-wifi] [--keep]" >&2; exit 1 ;;
		*) BR=$a ;;
	esac
done

NS=v6cli
V=v6c
TARGET6=2400:3200::1          # Alibaba, reachable over China Mobile's v6
TARGET6_ALT=2409:8088::8      # China Mobile's own v6 DNS -- no DNS names involved, plain packets

# Every command here is guarded, and the guard matters: this runs from an EXIT trap under `set -e`, so
# one non-zero status inside it decides the script's exit status. Measured 2026-10-13: a full pass --
# RA, SLAAC, both pings, the AAAA lookup -- still reported exit 1, because the trap re-killed the
# tcpdump this script had already killed (kill on a dead pid returns 1). A tool that says "failed"
# after a clean run is worse than no tool: it hides a real failure the next time.
cleanup() {
	[ -n "${RA_PID:-}" ] && { kill "$RA_PID" 2>/dev/null || true; }
	ip netns del "$NS" 2>/dev/null || true
	# Both ends by name. `$V` is inside the namespace, so deleting it on the host can never match; the
	# end that does live here is the peer `$Vp`, and that is the one that must not be left sitting in the
	# bridge. (Deleting the namespace takes `$V` with it, but a leftover `$Vp` is what makes the next run
	# die on `ip link add ... File exists`.)
	ip link del "$Vp" 2>/dev/null || true
	ip link del "$V" 2>/dev/null || true
	return 0
}
[ "$KEEP" = 1 ] || trap cleanup EXIT

cleanup
ip netns add "$NS"
ip link add "$V" type veth peer name "${V}p"
ip link set "${V}p" master "$BR"
ip link set "${V}p" up
ip link set "$V" netns "$NS"
ip netns exec "$NS" ip link set lo up

# The capture has to be running before the link comes up: the advertisement that answers the client's
# first solicitation arrives within milliseconds of that.
ip netns exec "$NS" tcpdump -i "$V" -n -l -tt -vv 'icmp6 and (ip6[40] == 133 or ip6[40] == 134)' \
	>/tmp/v6-ra.log 2>/dev/null &
RA_PID=$!
ip netns exec "$NS" ip link set "$V" up

echo "== waiting for the relayed router advertisement on $BR (up to 20s) =="
i=0
while [ $i -lt 20 ]; do
	sleep 1
	i=$((i + 1))
	ip netns exec "$NS" ip -6 addr show dev "$V" scope global | grep -q inet6 && break
done

kill $RA_PID 2>/dev/null || true
echo "-- what the client was advertised (the RA it acted on) --"
sed -n 's/^/   /p' /tmp/v6-ra.log | head -30

echo "-- client addresses --"
ip netns exec "$NS" ip -6 -o addr show dev "$V" | sed 's/^/   /'
echo "-- client routes --"
ip netns exec "$NS" ip -6 route show dev "$V" | sed 's/^/   /'
echo "-- client default route --"
ip netns exec "$NS" ip -6 route show default | sed 's/^/   /'

GW=$(ip netns exec "$NS" ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
if [ -z "$GW" ]; then
	echo "== NO DEFAULT ROUTE: the RA was not relayed, the client is IPv6-dead =="
else
	echo "== pinging out through $GW =="
	ip netns exec "$NS" ping6 -c 3 -W 5 "$TARGET6" 2>&1 | sed 's/^/   /' || true
	ip netns exec "$NS" ping6 -c 3 -W 5 "$TARGET6_ALT" 2>&1 | sed 's/^/   /' || true

	# Name resolution over IPv6, asked directly of the carrier's own v6 resolver: this is the part that
	# fails invisibly (the transport works, the answer never comes, and clients decide IPv6 is dead).
	echo "== AAAA lookup over IPv6 (carrier resolver $TARGET6_ALT) =="
	# busybox's smaller nslookup build has no -type; the plain form is the fallback, and either way the
	# answer has to arrive over the v6 transport to the v6 server, which is the thing under test.
	ip netns exec "$NS" nslookup -type=AAAA www.qq.com "$TARGET6_ALT" 2>&1 | sed 's/^/   /' ||
		ip netns exec "$NS" nslookup www.qq.com "$TARGET6_ALT" 2>&1 | sed 's/^/   /' || true
fi

echo "== device side =="
echo "-- neighbour table on $BR (the client should be there) --"
ip -6 neigh show dev "$BR" | sed 's/^/   /'
echo "-- the route that must carry the reply --"
ip -6 route show "$(ip -6 -o addr show dev sipa_eth0 scope global 2>/dev/null | awk '{print $4}' | head -1)" 2>/dev/null | sed 's/^/   /' || true
ip -6 route show | grep -v fe80 | sed 's/^/   /'

if [ "$KEEP" = 1 ]; then
	echo "== --keep: namespace $NS left up; remove with: ip netns del $NS; ip link del $V =="
fi
exit 0
