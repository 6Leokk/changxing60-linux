#!/bin/sh
# netifd protocol for the changxing60 modem: attach with AT commands (mobile-data) and configure sipa_eth0.
# /etc/config/network:  config interface 'wan' / option proto 'changxing60cell' / option apn 'internet'
[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_changxing60cell_init_config() {
	available=1
	no_device=1
	proto_config_add_string "apn"
	proto_config_add_string "ipv6"
	proto_config_add_boolean "peerdns"
	proto_config_add_array "dns:list(ipaddr)"
}

proto_changxing60cell_setup() {
	local config="$1"
	local apn peerdns ipv6 out ifname ip prefix dns1 dns2
	json_get_vars apn peerdns ipv6

	out=$(CHANGXING60_NETIFD=1 /opt/changxing60/bin/mobile-data up $apn 2>/tmp/changxing60cell.err)
	if [ $? = 3 ]; then
		logger -t changxing60cell "$(cat /tmp/changxing60cell.err)"
		proto_notify_error "$config" NO_MODEM
		proto_block_restart "$config"
		return 1
	fi
	ip=$(echo "$out" | sed -n 's/^IP=//p')
	if [ -z "$ip" ]; then
		logger -t changxing60cell "attach failed: $(cat /tmp/changxing60cell.err)"
		proto_notify_error "$config" ATTACH_FAILED
		sleep 20
		proto_setup_failed "$config"
		return 1
	fi
	ifname=$(echo "$out" | sed -n 's/^IFACE=//p')
	prefix=$(echo "$out" | sed -n 's/^PREFIX=//p')
	dns1=$(echo "$out" | sed -n 's/^DNS1=//p')
	dns2=$(echo "$out" | sed -n 's/^DNS2=//p')

	ip link set "$ifname" up
	# Parity with the standalone path in mobile-data, which turns RX checksum offloading off
	# because the sipa driver reports checksums the stack cannot trust. Note that this rootfs has
	# no ethtool (see mobile-data), so both places are inert here -- recorded rather than removed so
	# the workaround is not silently forgotten.
	ethtool -K "$ifname" rx off 2>/dev/null || true
	# Contract with ndp-learn and the DHCPv6/RA relay: option ipv6 'relay' means "take IPv6 from the
	# carrier's router advertisement on this bearer, share the /64 with the hotspot". It is not a
	# prefix-delegation setup and nothing here configures an address: the kernel's own SLAAC owns it.
	#
	# Why the bearer has no IPv6 unless this runs. net.ipv6.conf.all.forwarding is 1 on this device,
	# and the kernel's per-interface default for accept_ra follows forwarding: it stays 0 on its own.
	# With accept_ra 0 a router advertisement that arrives is discarded -- and this carrier only sends
	# one in answer to a router solicitation, so nothing at all is attempted.
	#
	# Measured on this modem (5.4.254, China Mobile, 2026-10-13), with a capture on the bearer:
	#
	#   accept_ra 0->2 alone ................... 0 router solicitations sent, 0 advertisements
	#   disable_ipv6 1->0, accept_ra already 2 .. 2 solicitations sent, advertisement back in 57 ms
	#
	# So the ordering here is the opposite of upstream's and it is deliberate: accept_ra FIRST, and
	# then the addrconf restart that actually emits the solicitation (re-enabling IPv6 rebuilds the
	# link-local, DAD finishes, and the RS follows). Touching accept_ra after the restart cancels the
	# pending solicitation and buys another 30 s of silence -- that is the failure this ordering is
	# written to avoid, not a hypothetical one. Upstream's own relay attempt flips accept_ra after
	# the cycle; on their 6.18 build it works, on this one it does not.
	#
	# The solicited advertisement carries INFINITE address and prefix lifetimes (measured: valid_lft
	# forever, router lifetime ~18 h), so an address, once learnt, is never renewed or expired. That is
	# why the last dial's v6 state is flushed rather than kept: after a renumber the old prefix would
	# otherwise stay configured for the life of the boot and stack up beside the new one.
	#
	# Nothing is reported to netifd for IPv6 -- the kernel owns it, and odhcpd reads the advertisement
	# off the wire rather than out of netifd's records. What netifd needs is the IPv4 below.
	ip -6 addr flush dev "$ifname" scope global 2>/dev/null || true
	ip -6 route flush dev "$ifname" 2>/dev/null || true
	if [ "$ipv6" = relay ]; then
		if [ -w "/proc/sys/net/ipv6/conf/$ifname/accept_ra" ]; then
			echo 2 > "/proc/sys/net/ipv6/conf/$ifname/accept_ra"
			echo 1 > "/proc/sys/net/ipv6/conf/$ifname/disable_ipv6"
			sleep 1
			echo 0 > "/proc/sys/net/ipv6/conf/$ifname/disable_ipv6"
		fi
	elif [ -w "/proc/sys/net/ipv6/conf/$ifname/disable_ipv6" ]; then
		# Plain IPv4 bearer: an interface left with a link-local address sends router solicitations
		# and multicast into it for nothing. Note this has to happen after the address work above,
		# because netifd turns IPv6 back on as it configures the interface.
		echo 1 > "/proc/sys/net/ipv6/conf/$ifname/disable_ipv6"
	fi
	proto_init_update "$ifname" 1
	proto_add_ipv4_address "$ip" "${prefix:-32}"
	proto_add_ipv4_route "0.0.0.0" 0
	if [ "${peerdns:-1}" != 0 ]; then
		[ -n "$dns1" ] && proto_add_dns_server "$dns1"
		[ -n "$dns2" ] && proto_add_dns_server "$dns2"
	fi
	proto_send_update "$config"
	[ -w /sys/class/leds/sc27xx:blue/brightness ] && echo 255 > /sys/class/leds/sc27xx:blue/brightness
	logger -t changxing60cell "connected: $ip/${prefix:-32} on $ifname"
}

proto_changxing60cell_teardown() {
	local config="$1"
	/opt/changxing60/bin/mobile-data down >/dev/null 2>&1
	proto_kill_command "$config"
	# The bearer is the only one this hardware has. Clean it in both families: the carrier's
	# advertisement gives the address an infinite lifetime, so an SLAAC address left here would
	# survive every redial and stack up (see the setup path).
	ip -4 addr flush dev sipa_eth0 scope global 2>/dev/null || true
	ip -4 route del default dev sipa_eth0 2>/dev/null || true
	ip -6 addr flush dev sipa_eth0 scope global 2>/dev/null || true
	ip -6 route flush dev sipa_eth0 2>/dev/null || true
}

[ -n "$INCLUDE_ONLY" ] || add_protocol changxing60cell
