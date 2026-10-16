#!/bin/sh
# Build the MU300 OpenWrt rootfs tarball (runs on the host; needs Docker with arm64 support).
#   openwrt/build-rootfs.sh OUT.tar.gz
# Inputs (same as rootfs/assemble.sh, all optional except modules):
#   out/modules/*.ko  out/modules.builtin*  firmware/  android-subset/  android-gpu-subset/
#   tools/logdw/logdw  tools/bt-init/mu300-bt-init  tools/gpu/cltest  busybox (static, full)
#   upstream/out/modules/*.ko (optional: out-of-tree WCN modules for the mainline 6.18 kernel)
set -eu
VER=25.12.5
KREL=5.4.254-gb50db5b6224c
OUT=${1:-mu300-openwrt-$VER-rootfs.tar.gz}
TOP=$(cd "$(dirname "$0")/.." && pwd)
# build inputs (out/, firmware/, android-subset/, tools binaries, busybox) may live outside the checkout
IN=${MU300_INPUTS:-$TOP}
TARBALL=openwrt-$VER-armsr-armv8-rootfs.tar.gz
URL=https://downloads.openwrt.org/releases/$VER/targets/armsr/armv8

cd "$TOP"
if [ ! -f "openwrt/$TARBALL" ]; then
    curl -fL -o "openwrt/$TARBALL" "$URL/$TARBALL"
fi
want=$(curl -fsL "$URL/sha256sums" | sed -n "s/^\([0-9a-f]*\) \*$TARBALL$/\1/p")
have=$(shasum -a 256 "openwrt/$TARBALL" 2>/dev/null || sha256sum "openwrt/$TARBALL")
[ "${have%% *}" = "$want" ] || { echo "checksum mismatch for $TARBALL" >&2; exit 1; }
docker import --platform linux/arm64 "openwrt/$TARBALL" mu300-openwrt-base:$VER >/dev/null
# OpenWrt ships an unsigned regulatory.db; this kernel requires the signed database (wens key), so take Debian/Ubuntu's
REGDB=$(mktemp -d)
docker run --rm --platform linux/arm64 -v "$REGDB":/o ubuntu:26.04 sh -c \
  "apt-get update -qq >/dev/null && apt-get install -y -qq wireless-regdb >/dev/null && cp /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s /o/"

opt() { [ -e "$IN/$1" ] && echo "-v $IN/$1:/in/$2:ro" || true; }
# shellcheck disable=SC2046
docker run --rm --platform linux/arm64 \
  -v "$TOP/rootfs/overlay/opt/mu300":/in/opt-mu300:ro -v "$TOP/openwrt/overlay":/in/overlay:ro \
  -v "$TOP/tools":/in/tools:ro \
  -v "$TOP/boot/module-order.txt":/in/module-order.txt:ro -v "$IN/out/modules":/in/modules:ro \
  $(opt out/modules.builtin modules.builtin) $(opt out/modules.builtin.modinfo modules.builtin.modinfo) \
  $(opt firmware firmware) $(opt android-subset android-subset) $(opt android-gpu-subset android-gpu-subset) \
  $(opt tools/logdw/logdw logdw) $(opt tools/bt-init/mu300-bt-init bt-init) $(opt tools/gpu/cltest cltest) \
  $(opt busybox busybox) $(opt upstream/out/modules mainline-modules) -v "$TOP/openwrt":/out -v "$REGDB":/in/regdb:ro \
  $(opt out/display display) $(opt tools/screen/out screen-tools) \
  -e KREL=$KREL -e OUT="$(basename "$OUT")" mu300-openwrt-base:$VER /bin/sh -eu -c '
# NOTE: everything down to the closing quote is ONE single-quoted string. An apostrophe anywhere
# inside -- even in a comment, where the shell would otherwise ignore it -- ends that string early
# and the outer script stops parsing. That is not hypothetical: exactly that happened to a comment
# here, and the committed script could not run at all until it was reworded.
mkdir -p /var/lock /var/run /tmp
apk update >/dev/null
apk add wpad-basic-mbedtls wifi-scripts iwinfo wireless-regdb iw bash ip-full coreutils-stty >/dev/null
# Debug toolbox, baked in so the box can be debugged in the field without a feed round-trip.
# ethtool and strace are the two that were actually missed (this rootfs had neither); the rest are
# the usual reach-for-it tools. apk still works on the device (repositories.d/distfeeds.list), but
# use "apk add <pkg>" only: "apk upgrade" would pull the armsr 6.12 kernel package at this rootfs.
apk add ethtool strace lsof iperf3 mtr socat drill usbutils htop iftop nload openssl-util >/dev/null
# No interpreter, no python3 -- that has cost time twice now (a one-off check with no way to run it).
apk add python3-light >/dev/null
# ujail drops CAP_PERFMON (38), which this 5.4 kernel does not know: jailed services (dnsmasq, ntpd) crash-loop
apk del procd-ujail procd-seccomp >/dev/null 2>&1 || true
# online firmware upgrades flash whole-disk armsr images: that would overwrite the eMMC, so remove them
apk del luci-app-attendedsysupgrade attendedsysupgrade-common owut >/dev/null 2>&1 || true
R=/build/root; mkdir -p $R
# copy the live filesystem of this container (the OpenWrt rootfs plus packages), without runtime mounts
for e in /*; do
    case "$e" in /proc|/sys|/dev|/build|/in|/out|/tmp) continue ;; esac
    cp -a "$e" $R/
done
mkdir -p $R/proc $R/sys $R/dev $R/tmp $R/run $R/opt
cp -a /in/opt-mu300 $R/opt/mu300
cp -a /in/overlay/. $R/
# The mode bit is the entire interface for anything invoked by path, and it is the one property of a
# script that nobody reads. On 2026-10-16 six of these were committed 644 while every caller reached
# them by path -- net-split (from uci-defaults, so the hotspot never got a firewall zone and no
# client could get an address), hotspot-watch and charge-fix (procd instances in mu300-post, so
# neither ever ran), quiet-console (mu300-hw), and the overlay's own /etc/init.d/mu300-ndp (so
# ndp-learn never routed the carrier's prefix to the hotspot). Every one of those failures was
# silent. `cp -a` reproduces the mode faithfully, so set it here instead of trusting the tree:
# everything with a shebang under /opt/mu300/bin, and every init script, is executable.
for f in $R/opt/mu300/bin/*; do
    if [ -f "$f" ] && [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ]; then chmod 755 "$f"; fi
done
# guarded: under `set -e` an unmatched glob reaches chmod as a literal path and would abort the build
for d in $R/etc/init.d $R/etc/uci-defaults; do
    [ -d "$d" ] && { chmod 755 "$d"/* 2>/dev/null || true; }
done
# On-device debugging tools. The canonical copies live in the repo tools/ directory; these are the
# ones that run ON the box (busybox ash), as opposed to the host-side helpers that drive it over
# ssh/adb. /opt/mu300/bin is already on PATH via /etc/profile.d/mu300.sh, so they are reachable by
# bare name. mu300-diag.sh is the front door: one read-only snapshot for when the WAN dies again.
# net-v6-client-test.sh is included with its hazard warning intact -- it has panicked this kernel.
for t in mu300-diag.sh mu300-cp-reset.sh mu300-wedge-watch.sh mu300-wan-keepalive.sh \
         net-down-test.sh net-scope-test.sh net-v6-client-test.sh modem-ioctl; do
    [ -e /in/tools/$t ] || { echo "debug tool missing: tools/$t" >&2; continue; }
    cp /in/tools/$t $R/opt/mu300/bin/$t && chmod 755 $R/opt/mu300/bin/$t
done
echo "debug tools: $(ls $R/opt/mu300/bin | wc -l) files in /opt/mu300/bin"
mv $R/sbin/sysupgrade $R/sbin/sysupgrade.openwrt && mv $R/usr/libexec/mu300-sysupgrade $R/sbin/sysupgrade
M=$R/lib/modules/$KREL; mkdir -p $M
cp /in/modules/*.ko $M/          # ubox kmodloader expects the modules flat in /lib/modules/<release>/
for f in modules.builtin modules.builtin.modinfo; do [ -e /in/$f ] && cp /in/$f $M/; done
[ -d /in/firmware ] && { mkdir -p $R/lib/firmware; cp -a /in/firmware/. $R/lib/firmware/; }
cp /in/regdb/regulatory.db /in/regdb/regulatory.db.p7s $R/lib/firmware/
if [ -d /in/android-subset ]; then
    mkdir -p $R/opt/mu300/android && cp -a /in/android-subset/. $R/opt/mu300/android/
    mv $R/opt/mu300/android/dev/__properties__ $R/opt/mu300/android/dev-properties && rmdir $R/opt/mu300/android/dev
fi
[ -d /in/android-gpu-subset ] && cp -a /in/android-gpu-subset/. $R/opt/mu300/android/
# Internal-panel display stack: six external modules built by kernel/build-internal-display.sh
# (sprd-drm, sprd-vpu-pd, pwm-sprd, unisoc-iommu, zte_lcdbl_vsp_vsn, trusty-ipc) that are NOT part
# of the 109-module boot set, plus the status-page binary. They load at S95 from
# /opt/mu300/bin/display-modules, not at boot, so a broken panel cannot stop the device booting.
[ -d /in/display ] && cp /in/display/*.ko $M/
[ -e /in/display ] && echo "display modules: $(ls /in/display/*.ko | wc -l)"
[ -d /in/screen-tools ] && for b in mu300-screen keyinject wifimac; do
    [ -e /in/screen-tools/$b ] && { cp /in/screen-tools/$b $R/usr/bin/$b; chmod 755 $R/usr/bin/$b; }
done
[ -e /in/cltest ] && { mkdir -p $R/opt/mu300/android/system/bin; cp /in/cltest $R/opt/mu300/android/system/bin/cltest; chmod 755 $R/opt/mu300/android/system/bin/cltest; }
[ -e /in/logdw ] && { cp /in/logdw $R/opt/mu300/bin/logdw; chmod 755 $R/opt/mu300/bin/logdw; }
[ -e /in/bt-init ] && { cp /in/bt-init $R/opt/mu300/bin/mu300-bt-init; chmod 755 $R/opt/mu300/bin/mu300-bt-init; }
# full static busybox for the tools OpenWrt busybox leaves out (od, timeout, mountpoint, losetup, rfkill, telnetd)
if [ -e /in/busybox ]; then
    cp /in/busybox $R/opt/mu300/bin/busybox; chmod 755 $R/opt/mu300/bin/busybox
    mkdir -p $R/opt/mu300/busybox-bin
    for a in od timeout losetup telnetd getty; do
        chroot $R /bin/sh -c "command -v $a" >/dev/null 2>&1 && continue
        ln -sf ../bin/busybox $R/opt/mu300/busybox-bin/$a
    done
fi
mkdir -p $R/etc/mu300
# The rootfs is assembled in a container, so /etc/resolv.conf is whatever Docker bind-mounted
# there: "nameserver 10.255.255.254", the Docker resolver. That address means nothing on the
# device, and the failure hides well -- dnsmasq still answers LAN clients from its own upstreams
# (/tmp/resolv.conf.d/resolv.conf.auto), so only lookups that originate ON the router break
# (apk update, LuCI package installs, curl). OpenWrt keeps /etc/resolv.conf as a symlink that
# netifd fills in.
ln -sfn /tmp/resolv.conf $R/etc/resolv.conf
# enable the services (rc.common "enable" needs ubus, which is not running in the build container).
# Globbed, not listed by hand: the hand-written list silently left a script out of rc.d, and a service
# that is installed but never enabled does not fail -- it just never runs. (mu300-power, added
# 2026-10-15, was absent from the old list and would have been dead on arrival.)
for f in $R/etc/init.d/mu300-*; do
    s=${f##*/}
    n=$(sed -n "s/^START=//p" "$f")
    if [ -z "$n" ]; then
        echo "build-rootfs: $s has no START=, leaving it disabled" >&2
        continue
    fi
    ln -sf ../init.d/$s $R/etc/rc.d/S$n$s
done
# no kernel of its own: OpenWrt kmods (6.12) and grub are unused on this device
rm -rf $R/lib/modules/6.* $R/boot
# out-of-tree modules for the experimental mainline kernel (upstream/). The release is read out of
# the modules themselves rather than written here: a hardcoded one silently went stale (6.18.52
# against modules built for 6.18.56), and a mismatched /lib/modules directory means the kernel
# finds nothing and every module load fails one by one at boot.
if ls /in/mainline-modules/*.ko >/dev/null 2>&1; then
    rel=$(grep -aoh "vermagic=[0-9][0-9.]*" /in/mainline-modules/*.ko | head -1 | cut -d= -f2)
    [ -n "$rel" ] || { echo "mainline-modules: no vermagic in any module" >&2; exit 1; }
    mkdir -p $R/lib/modules/$rel && cp /in/mainline-modules/*.ko $R/lib/modules/$rel/
    echo "mainline modules: $(ls /in/mainline-modules/*.ko | wc -l) in /lib/modules/$rel"
fi
# OpenClash is installed on the *device* by hand, not built here: luci-app-openclash 0.48.002, the
# mihomo core, and 34 dependency packages that were pulled from the network at install time. Nothing
# in this script puts them in. So every rebuild quietly produces a rootfs without the proxy stack, and
# reinstalling needs a working WAN -- which is the one thing that is intermittently broken on this
# device. A silent loss that expensive deserves a banner. (docs/mu300/backlog.md section 4.)
if [ -e $R/etc/init.d/openclash ] || [ -e $R/etc/openclash ]; then
    echo "openclash: present in this rootfs"
else
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! WARNING: this rootfs contains NO OpenClash."
    echo "!! The proxy stack lives only on the device, so flashing this tarball drops it."
    echo "!! Reinstalling needs a working WAN. See docs/mu300/backlog.md section 4."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
cd $R && tar -czf /out/$OUT .
ls -la /out/$OUT'
rm -rf "$REGDB"
