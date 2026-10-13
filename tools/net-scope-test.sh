#!/bin/sh
# Ask each LAN scope for a lease, the way a client would, and report what it is offered.
#
# Run it on the device:  net-scope-test.sh br-lan      # the USB host's side
#                        net-scope-test.sh br-wifi     # the hotspot's side
#
# A veth pair joined to the bridge is a real DHCP client as far as dnsmasq is concerned: the
# request arrives on the bridge port and is answered with that interface's scope and options.
# That is exactly the part that is easy to get wrong and impossible to see from dnsmasq's config
# file alone -- `dhcp-option=lan,3` with an empty value is supposed to mean "send no router", and
# this is how you find out whether the client agrees.
#
# The lease script deliberately does not install the address or the route: this must never touch
# the device's own routing table (udhcpc's default script would add a default route via the phone
# itself). It only reports.
set -e
BR=${1:?usage: net-scope-test.sh <br-lan|br-wifi>}
V=mst
GW_TEST=223.5.5.5

cat > /tmp/mst-lease.sh <<'SCRIPT'
#!/bin/sh
case "$1" in
bound|renew)
	printf '  addr  %s/%s\n' "$ip" "$mask"
	printf '  router %s\n' "${router:-(none offered)}"
	printf '  dns    %s\n' "${dns:-(none offered)}"
	printf '  server %s\n' "$siaddr"
	;;
esac
exit 0
SCRIPT
chmod +x /tmp/mst-lease.sh

cleanup() {
	ip link del "$V" 2>/dev/null || true
	rm -f /tmp/mst-lease.sh
}
trap cleanup EXIT

ip link add "$V" type veth peer name "${V}p" 2>/dev/null || true
ip link set "${V}p" master "$BR"
ip link set "${V}p" up
ip link set "$V" up
sleep 1

echo "== $BR =="
udhcpc -i "$V" -s /tmp/mst-lease.sh -f -q -n -t 3 -T 3 2>&1 | grep -v "^udhcpc: " || true
echo "== end $BR =="
