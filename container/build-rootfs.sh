#!/bin/sh
# Build the 7552N OpenWrt container rootfs tarball on the host (WSL/PC).
#   container/build-rootfs.sh [out.tar.gz]
# Output: changxing60-openwrt-container-rootfs.tar.gz - official OpenWrt 25.12.5 armsr rootfs
# (procd, ubus, rpcd, uhttpd, LuCI, dnsmasq, dropbear are all in the official tarball) plus our
# overlay: sing-box, changxing60-vpn, the procd service and default configs.
set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$TOP/container/changxing60-openwrt-container-rootfs.tar.gz}
BASE=$TOP/openwrt/openwrt-25.12.5-armsr-armv8-rootfs.tar.gz
OVL=$TOP/container/overlay

[ -f "$BASE" ] || { echo "official armsr rootfs tarball missing: $BASE" >&2; exit 1; }
[ -x "$OVL/opt/changxing60/bin/sing-box" ] || { echo "sing-box missing under $OVL (see container/README)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/r"
tar -xzf "$BASE" -C "$WORK/r"

# overlay: /opt/changxing60/bin/{sing-box,changxing60-vpn}, /etc/init.d/changxing60-vpn, /etc/changxing60/vpn.conf
cp -a "$OVL/opt" "$WORK/r/"
cp -a "$OVL/etc/init.d" "$WORK/r/etc/"
mkdir -p "$WORK/r/etc/changxing60"
cp "$OVL/etc/changxing60/vpn.conf" "$WORK/r/etc/changxing60/"
chmod 755 "$WORK/r/opt/changxing60/bin/sing-box" "$WORK/r/opt/changxing60/bin/changxing60-vpn" "$WORK/r/etc/init.d/changxing60-vpn"

# enable our service the way the tarball enables the others (rc.common needs ubus, absent here)
ln -sf ../init.d/changxing60-vpn "$WORK/r/etc/rc.d/S99changxing60-vpn"

# config: LuCI/uhttpd listens on all interfaces (the hotspot subnet is the LAN);
# dnsmasq: only DNS on the hotspot subnet (Android's own DHCP already serves the AP clients),
#           so the default dhcp-facing config stays but nothing conflicts
sed -i 's/^list listen_http.*/list listen_http\t0.0.0.0:80/' "$WORK/r/etc/config/uhttpd" 2>/dev/null || true
sed -i 's/^list listen_http.*/list listen_http 0.0.0.0:80/' "$WORK/r/etc/config/uhttpd" 2>/dev/null || true

# dnsmasq: procd_add_jail hard-codes a ujail sandbox in its init script. ujail drops
# CAP_PERFMON(38) which this Android 5.4 kernel does not know - the jailed dnsmasq
# crash-loops (native buildRootfs does "apk del procd-ujail"; here we strip the jail lines).
sed -i '/procd_add_jail/d' "$WORK/r/etc/init.d/dnsmasq" 2>/dev/null || true

# dropbear: off by default (LuCI over the hotspot is the management plane; sshd on a shared
# netns would fight Android for port 22 anyway)
rm -f "$WORK/r/etc/rc.d/"*dropbear 2>/dev/null || true

# firewall4/nftables: the stock kernel has no nftables - make sure fw4 never starts
rm -f "$WORK/r/etc/rc.d/"*firewall 2>/dev/null || true

# --- shared-netns / shared-kernel safety audit (2026-09-20, chroot shares them with Android) ---
# netifd (S20network): would try to manage interfaces/IPs in Android's netns; the armsr tarball
#   ships no etc/config/network so it would only idle, but it must never get config to act on.
# odhcpd (S35): IPv6 RA/DHCPv6 - would fight Android's own ipv6 stack on the hotspot.
# packet_steering (S25): rewrites RPS sysctls - shared-kernel tunable, Android may not expect it.
# sysntpd (S98): settimeofday would jump the shared clock - time sync is Android's job.
# gpio_switch (S94/K10): no gpio platform devices on this phone; dead weight.
# sysupgrade / owut / luci-app-attendedsysupgrade: MUST NOT exist in a container - sysupgrade
# dd-writes the whole "firmware" device (here: the phone's /dev/sda) = instant brick.
#   The native-install build (openwrt/build-rootfs.sh) already strips these; the container
#   build missed it. Remove binaries, LuCI UI, menus, ACLs, apk metadata, config and uci-defaults.
rm -f  "$WORK/r/sbin/sysupgrade" \
       "$WORK/r/usr/bin/owut" \
       "$WORK/r/usr/share/rpcd/acl.d/luci-app-attendedsysupgrade.json" \
       "$WORK/r/usr/share/luci/menu.d/luci-app-attendedsysupgrade.json" \
       "$WORK/r/etc/sysupgrade.conf" \
       "$WORK/r/etc/owut.d/pre-install.sh" \
       "$WORK/r/lib/upgrade/keep.d/owut"
rm -f  "$WORK/r/lib/apk/packages/"*owut* \
       "$WORK/r/lib/apk/packages/"*attendedsysupgrade* \
       "$WORK/r/etc/uci-defaults/"*attendedsysupgrade* \
       "$WORK/r/etc/uci-defaults/51-attendedsysupgrade-owut"
rm -rf "$WORK/r/www/luci-static/resources/view/attendedsysupgrade" "$WORK/r/etc/owut.d"

# --- shared-netns / shared-kernel safety audit (chroot shares them with Android) ---
# netifd (S20network): would try to manage interfaces/IPs in Android's netns; the armsr
#   tarball ships no etc/config/network so it would only idle, but it must never run.
# odhcpd (S35): IPv6 RA/DHCPv6 - would fight Android's own ipv6 stack on the hotspot.
# packet_steering (S25): rewrites RPS sysctls - shared-kernel tunable, Android may not expect it.
# sysntpd (S98): settimeofday would jump the shared clock - time sync is Android's job.
# gpio_switch (S94/K10): no gpio platform devices on this phone; dead weight.
rm -f "$WORK/r/etc/rc.d/"*network \
      "$WORK/r/etc/rc.d/"*odhcpd \
      "$WORK/r/etc/rc.d/"*packet_steering \
      "$WORK/r/etc/rc.d/"*sysntpd \
      "$WORK/r/etc/rc.d/"*gpio_switch

tar -czf "$OUT" -C "$WORK/r" .
echo "built $OUT"
du -h "$OUT"
