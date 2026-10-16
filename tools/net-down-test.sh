#!/bin/sh
# Downlink throughput of the changxing60's links, measured on the WAN interface counters (that is what the
# far side actually delivered, so it does not depend on the client's own TCP stack).
#
#   net-down-test.sh wan     the device's own cellular downlink
#   net-down-test.sh lan     a client behind br-wifi (veth in its own netns: a real forwarded, NATed
#                            client, it just skips the air link)
#   net-down-test.sh air     sample hostapd's per-station byte counters for N seconds. This is the
#                            only way to see the AP<->client air link on this driver: `iw dev wlan0
#                            station dump` is always empty here, hostapd's table is not. A client
#                            has to be pushing traffic for it to mean anything.
#
# The HTTP mirrors reject a request whose Host header is an IP (403 or a reset), so the URL stays a
# hostname; running as a netns client therefore needs a resolver reachable on br-wifi, which
# 192.168.8.1 is. resolv.conf is saved and put back.
#
# Measured 2026-10-13 (Tsinghua mirror, 10 s windows, one boot):
#     cellular     1 flow  21 Mbps      4 flows  87-114 Mbps
#     via br-wifi  1 flow  19 Mbps      4 flows  88- 99 Mbps
# Two things fall out of that. The forwarding path costs almost nothing (99 vs 114), so the hotspot
# is not where a slow download comes from; and the single-flow figure is a property of the *client*
# (uclient-fetch's small socket buffers against a 55-230 ms RTT), not of the link -- which is why a
# one-connection test on this box reads ~20 Mbps no matter which side of the bridge it runs on.
# Cloudflare's __down works one flow at a time (parallel downloads stall after a few KiB) and its
# __up resets, so uploads still have no usable target from here.
#
# The air link is still unmeasured: that needs a wireless client actually pushing traffic, which is
# what the `air` mode is for.
set -e
MODE=${1:?usage: net-down-test.sh wan|lan|air [flows] [seconds]}
N=${2:-4}
SECS=${3:-10}
IF=sipa_eth0
MIRROR=http://mirrors.tuna.tsinghua.edu.cn/speedtest/1000mb.bin
CFDOWN="https://speed.cloudflare.com/__down?bytes=200000000"

rate() {  # $1 label, $2 interface, $3 first byte counter, $4 last, $5 seconds
	echo "  $1: $(( ($4 - $3) * 8 / $5 / 1000000 )) Mbps   ($(( ($4 - $3) / 1024 / 1024 )) MiB / $5 s)"
}

wan_test() {
	A=$(cat /sys/class/net/$IF/statistics/rx_bytes); T1=$(date +%s)
	sleep "$SECS"
	B=$(cat /sys/class/net/$IF/statistics/rx_bytes); T2=$(date +%s)
	rate "cellular, $N flows" "$IF" "$A" "$B" "$((T2 - T1))"
}

echo "== $MODE =="
case "$MODE" in
wan)
	i=0; while [ $i -lt $N ]; do i=$((i + 1)); wget -4 -q -T 30 -O /dev/null "$MIRROR" >/dev/null 2>&1 & done
	sleep 4; wan_test; killall wget 2>/dev/null || true
	;;
lan)
	cp /tmp/resolv.conf /tmp/resolv.conf.bak 2>/dev/null || true
	grep -q '^nameserver 192.168.8.1' /tmp/resolv.conf || printf 'nameserver 192.168.8.1\n' >> /tmp/resolv.conf
	ip netns add c1
	ip link add vc1 type veth peer name vc1p
	ip link set vc1p master br-wifi; ip link set vc1p up
	ip link set vc1 netns c1
	ip netns exec c1 ip link set lo up; ip netns exec c1 ip link set vc1 up
	cat > /tmp/c1.sh <<'SCRIPT'
#!/bin/sh
case "$1" in
bound|renew) ip addr add "$ip/$mask" dev "$interface"; ip route add default via "$router" dev "$interface";;
esac
exit 0
SCRIPT
	chmod +x /tmp/c1.sh
	ip netns exec c1 udhcpc -i vc1 -s /tmp/c1.sh -f -q -n -t 5 >/dev/null 2>&1
	echo "  client $(ip netns exec c1 ip -4 -o addr show vc1 | awk '{print $4}')"
	i=0; while [ $i -lt $N ]; do i=$((i + 1)); ip netns exec c1 wget -4 -q -T 30 -O /dev/null "$MIRROR" >/dev/null 2>&1 & done
	sleep 4; wan_test
	ip netns pids c1 2>/dev/null | xargs -r kill -9 2>/dev/null || true
	ip link del vc1 2>/dev/null || true
	ip netns del c1 2>/dev/null || true
	cp /tmp/resolv.conf.bak /tmp/resolv.conf 2>/dev/null || true
	;;
air)
	# hostapd keeps the station's byte counters; the driver's own station dump does not.
	prev_rx=0; prev_tx=0; n=0
	while [ $n -lt "$SECS" ]; do
		n=$((n + 1))
		set -- $(ubus call hostapd.wlan0 get_clients 2>/dev/null | grep -A5 '"bytes"' | grep -E '"rx"|"tx"' | grep -o '[0-9]*')
		[ $# -ge 2 ] || { echo "  no client associated"; exit 0; }
		if [ "$prev_rx" -ne 0 ]; then
			echo "  $n: client->AP $(( ($1 - prev_rx) * 8 / 1000000 )) Mbps   AP->client $(( ($2 - prev_tx) * 8 / 1000000 )) Mbps"
		fi
		prev_rx=$1; prev_tx=$2
		sleep 1
	done
	;;
*) echo "usage: $0 wan|lan|air [flows] [seconds]" >&2; exit 2 ;;
esac
echo "  wan health: $(cat /tmp/changxing60-wan-health 2>/dev/null)"
