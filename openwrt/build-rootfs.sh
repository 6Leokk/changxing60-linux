#!/bin/sh
# Build the changxing60 OpenWrt rootfs tarball (runs on the host; needs Docker with arm64 support).
#
#   install.sh                                  <-- the canonical way to build an image
#   openwrt/build-rootfs.sh OUT.tar.gz          <-- only correct if the inputs are already staged
#
# install.sh is the entry point: it pulls what it needs off the device, stages the kernel modules,
# extracts android-subset, builds busybox/logdw/bt-init, and then calls this script with
# CHANGXING60_INPUTS=$WORK (default work/). Calling this script on its own with the default IN=$TOP
# is what its old usage line invited, and it silently omits busybox and android-subset -- an image
# that boots without a WAN. The required-input check below now fails the build instead.
#
# Inputs, all under $CHANGXING60_INPUTS (IN), not necessarily the checkout:
#   out/modules/*.ko  out/modules.builtin*  firmware/  busybox (static, full)   [required]
#   android-subset/                                                             [required]
#   tools/logdw/logdw  tools/bt-init/changxing60-bt-init  tools/screen/out  out/display
#   android-gpu-subset/  tools/gpu/cltest   (optional: the GPU userspace is not available yet)
#   upstream/out/modules/*.ko (optional: out-of-tree WCN modules for the mainline 6.18 kernel)
set -eu
VER=25.12.5
KREL=5.4.254-gb50db5b6224c
OUT=${1:-changxing60-openwrt-$VER-rootfs.tar.gz}
TOP=$(cd "$(dirname "$0")/.." && pwd)
# build inputs (out/, firmware/, android-subset/, tools binaries, busybox) may live outside the checkout
IN=${CHANGXING60_INPUTS:-$TOP}

# Required inputs, checked FIRST -- before the tarball download, the checksum fetch and the two
# container runs below. The `opt` helper further down expands to NOTHING when a path is absent, so a
# missing input does not fail the build: it silently produces an image without it, and nothing
# downstream notices. That is not hypothetical. tools/bt-init/changxing60-bt-init was absent from the
# repository for as long as this script existed, so every rebuild quietly dropped the Bluetooth init
# helper. busybox and android-subset are the same shape and worse: without busybox the tools that need
# od/timeout/losetup stop working, and without android-subset there is no modem_control, i.e. no WAN.
#
# Both live OUTSIDE the checkout in the canonical build. install.sh stages everything into
# $CHANGXING60_WORK (default work/) -- it copies the kernel modules there, extracts android-subset and
# builds busybox, logdw and bt-init -- and only then calls this script with CHANGXING60_INPUTS=$WORK.
# So running this script directly, which its own usage line above invites, omits both. Name them here
# so that mistake is a failed build with a reason, not an image that boots and has no WAN. Checked up
# here rather than beside `opt` so the failure costs a second instead of a download and an apt-get.
for req in busybox android-subset; do
    if [ ! -e "$IN/$req" ]; then
        echo "build-rootfs: required input $IN/$req is missing." >&2
        echo "  The image would silently ship without it." >&2
        echo "  Build via install.sh (the canonical path), or set CHANGXING60_INPUTS to the" >&2
        echo "  directory that holds busybox/ and android-subset/ (usually work/)." >&2
        exit 1
    fi
done

# Staleness of the module set. install.sh refreshes $IN/out/modules from $KOUT/modules on every run,
# so a direct build after a kernel rebuild ships whatever $IN happened to hold last. That is the same
# silent-omission shape as above and it nearly happened here: on 2026-10-16 the audio modules were
# rebuilt at 17:21 while $IN/out/modules still held the 01:20 set, so a direct build would have
# produced a 110-module rootfs with no sound. Warn rather than fail -- building from a deliberately
# frozen input set is legitimate, it just should not be an accident.
if [ -d "$TOP/out/modules" ] && [ -d "$IN/out/modules" ] && [ "$TOP/out/modules" != "$IN/out/modules" ]; then
    if [ -n "$(find "$TOP/out/modules" -name '*.ko' -newer "$IN/out/modules" -print -quit 2>/dev/null)" ]; then
        echo "build-rootfs: WARNING: $TOP/out/modules has modules newer than $IN/out/modules." >&2
        echo "  This image would ship the older set. Refresh it first:" >&2
        echo "    rm -rf $IN/out/modules && cp -R $TOP/out/modules $IN/out/modules" >&2
    fi
fi

TARBALL=openwrt-$VER-armsr-armv8-rootfs.tar.gz
URL=https://downloads.openwrt.org/releases/$VER/targets/armsr/armv8

cd "$TOP"
if [ ! -f "openwrt/$TARBALL" ]; then
    curl -fL -o "openwrt/$TARBALL" "$URL/$TARBALL"
fi
want=$(curl -fsL "$URL/sha256sums" | sed -n "s/^\([0-9a-f]*\) \*$TARBALL$/\1/p")
have=$(shasum -a 256 "openwrt/$TARBALL" 2>/dev/null || sha256sum "openwrt/$TARBALL")
[ "${have%% *}" = "$want" ] || { echo "checksum mismatch for $TARBALL" >&2; exit 1; }
docker import --platform linux/arm64 "openwrt/$TARBALL" changxing60-openwrt-base:$VER >/dev/null
# OpenWrt ships an unsigned regulatory.db; this kernel requires the signed database (wens key), so take Debian/Ubuntu's
REGDB=$(mktemp -d)
docker run --rm --platform linux/arm64 -v "$REGDB":/o ubuntu:26.04 sh -c \
  "apt-get update -qq >/dev/null && apt-get install -y -qq wireless-regdb >/dev/null && cp /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s /o/"

opt() { [ -e "$IN/$1" ] && echo "-v $IN/$1:/in/$2:ro" || true; }
# Checkout-resident build outputs. install.sh stages device-pulled and generated inputs into $IN
# (busybox, android-subset, firmware, modules, logdw, bt-init) but it never stages these three: they
# are produced inside the checkout by our own build scripts. Resolving them against $IN therefore
# missed them on EVERY canonical install.sh build, silently -- so every rootfs built that way shipped
# without the internal panel (out/display, the six modules from kernel/build-internal-display.sh),
# without the screen tools (tools/screen/out: changxing60-screen, keyinject, wifimac) and without the
# 6.18 out-of-tree modules (upstream/out/modules). Resolve them against $TOP instead.
optt() { [ -e "$TOP/$1" ] && echo "-v $TOP/$1:/in/$2:ro" || true; }

# shellcheck disable=SC2046
docker run --rm --platform linux/arm64 \
  -v "$TOP/rootfs/overlay/opt/changxing60":/in/opt-changxing60:ro -v "$TOP/openwrt/overlay":/in/overlay:ro \
  -v "$TOP/tools":/in/tools:ro \
  -v "$TOP/boot/module-order.txt":/in/module-order.txt:ro -v "$IN/out/modules":/in/modules:ro \
  $(opt out/modules.builtin modules.builtin) $(opt out/modules.builtin.modinfo modules.builtin.modinfo) \
  $(opt firmware firmware) $(opt android-subset android-subset) $(opt android-gpu-subset android-gpu-subset) \
  $(opt tools/logdw/logdw logdw) $(opt tools/bt-init/changxing60-bt-init bt-init) $(opt tools/gpu/cltest cltest) \
  $(opt busybox busybox) $(optt upstream/out/modules mainline-modules) -v "$TOP/openwrt":/out -v "$REGDB":/in/regdb:ro \
  $(optt out/display display) $(optt tools/screen/out screen-tools) \
  -e KREL=$KREL -e OUT="$(basename "$OUT")" changxing60-openwrt-base:$VER /bin/sh -eu -c '
# NOTE: everything down to the closing quote is ONE single-quoted string. An apostrophe anywhere
# inside -- even in a comment, where the shell would otherwise ignore it -- ends that string early
# and the outer script stops parsing. That is not hypothetical: exactly that happened to a comment
# here, and the committed script could not run at all until it was reworded.
mkdir -p /var/lock /var/run /tmp
# Every build re-fetches these from downloads.openwrt.org, and the CDN intermittently drops a single
# package -- "failed to extract ...: Connection aborted" followed by "wget: exited with error 4".
# Under set -e that one flake aborts a build which had otherwise done all of its real work, which is
# what happened on 2026-10-16: two runs lost to the network, neither to anything in this script.
# Retry, rather than making the operator re-run the whole build and hope.
apk_retry() {
    i=0
    while :; do
        i=$((i + 1))
        apk "$@" && return 0
        if [ "$i" -ge 4 ]; then
            echo "apk $* failed after $i attempts" >&2
            return 1
        fi
        echo "apk $* failed (attempt $i), retrying in 5s" >&2
        sleep 5
    done
}
apk_retry update >/dev/null
apk_retry add wpad-basic-mbedtls wifi-scripts iwinfo wireless-regdb iw bash ip-full coreutils-stty >/dev/null
# Debug toolbox, baked in so the box can be debugged in the field without a feed round-trip.
# ethtool and strace are the two that were actually missed (this rootfs had neither); the rest are
# the usual reach-for-it tools. apk still works on the device (repositories.d/distfeeds.list), but
# use "apk add <pkg>" only: "apk upgrade" would pull the armsr 6.12 kernel package at this rootfs.
apk_retry add ethtool strace lsof iperf3 mtr socat drill usbutils htop iftop nload openssl-util >/dev/null
# No interpreter, no python3 -- that has cost time twice now (a one-off check with no way to run it).
apk_retry add python3-light >/dev/null
# Call audio needs libasound.so.2 for the PCM half of the voice path (changxing60-voice-audio),
# and amixer to read the card back by hand. These come from the OpenWrt feed and NOT from our
# cross toolchain: this rootfs is musl and changxing60-cross is glibc, so a cross-built
# libasound.so.2 could never be loaded by the device python3. The feed builds it for exactly this
# rootfs, which is also how every other package here arrives. See tools/build-alsa.sh.
apk_retry add alsa-lib alsa-utils >/dev/null
# alsa-lib declares a dependency on kmod-sound-core, which is built for the armsr 6.12 kernel and not
# for ours. Installing it drops eight snd-*.ko into the existing /lib/modules/6.12.94/ tree (inert:
# ubox kmodloader keys off uname -r) and an /etc/modules.d/30-sound-core that kmodloader DOES read,
# so every boot would log ten failed modprobes for a kernel that is not running. That is the same
# shape of trap as the FAILED mali_kbase line that was once read as evidence for a whole wrong
# theory, so remove the payload instead of leaving it. apk still lists the package as installed
# because apk del refuses to break the alsa-lib dependency, and the library itself uses none of it.
rm -f /lib/modules/6.12.94/snd-*.ko /etc/modules.d/30-sound-core
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
cp -a /in/opt-changxing60 $R/opt/changxing60
cp -a /in/overlay/. $R/
# The mode bit is the entire interface for anything invoked by path, and it is the one property of a
# script that nobody reads. On 2026-10-16 six of these were committed 644 while every caller reached
# them by path -- net-split (from uci-defaults, so the hotspot never got a firewall zone and no
# client could get an address), hotspot-watch and charge-fix (procd instances in changxing60-post, so
# neither ever ran), quiet-console (changxing60-hw), and /etc/init.d/changxing60-ndp from the overlay
# itself (so ndp-learn never routed the carrier prefix to the hotspot). Every one of those failures was
# silent. `cp -a` reproduces the mode faithfully, so set it here instead of trusting the tree:
# everything with a shebang under /opt/changxing60/bin, and every init script, is executable.
for f in $R/opt/changxing60/bin/*; do
    if [ -f "$f" ] && [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ]; then chmod 755 "$f"; fi
done
# guarded: under `set -e` an unmatched glob reaches chmod as a literal path and would abort the build
for d in $R/etc/init.d $R/etc/uci-defaults; do
    [ -d "$d" ] && { chmod 755 "$d"/* 2>/dev/null || true; }
done
# On-device debugging tools. The canonical copies live in the repo tools/ directory; these are the
# ones that run ON the box (busybox ash), as opposed to the host-side helpers that drive it over
# ssh/adb. /opt/changxing60/bin is already on PATH via /etc/profile.d/changxing60.sh, so they are reachable by
# bare name. changxing60-diag.sh is the front door: one read-only snapshot for when the WAN dies again.
# net-v6-client-test.sh is included with its hazard warning intact -- it has panicked this kernel.
for t in changxing60-diag.sh changxing60-cp-reset.sh changxing60-wedge-watch.sh changxing60-wan-keepalive.sh \
         net-down-test.sh net-scope-test.sh net-v6-client-test.sh modem-ioctl; do
    [ -e /in/tools/$t ] || { echo "debug tool missing: tools/$t" >&2; continue; }
    cp /in/tools/$t $R/opt/changxing60/bin/$t && chmod 755 $R/opt/changxing60/bin/$t
done
# The voice tools live one level down in tools/voice/, so the flat loop above does not reach them.
# changxing60-vbc-dump is not optional: changxing60-vbc-load calls it by path to read the profiles
# back out of the kernel and compare, which is the only thing standing between a well-formed-but-wrong
# blob and a silent bad load (the driver checks the magic and nothing else). Without it the loader
# would report every profile unverified -- and it would be right to.
for t in changxing60-vbc-dump; do
    [ -e /in/tools/voice/$t ] || { echo "voice tool missing: tools/voice/$t" >&2; continue; }
    cp /in/tools/voice/$t $R/opt/changxing60/bin/$t && chmod 755 $R/opt/changxing60/bin/$t
done
echo "debug tools: $(ls $R/opt/changxing60/bin | wc -l) files in /opt/changxing60/bin"
mv $R/sbin/sysupgrade $R/sbin/sysupgrade.openwrt && mv $R/usr/libexec/changxing60-sysupgrade $R/sbin/sysupgrade
M=$R/lib/modules/$KREL; mkdir -p $M
cp /in/modules/*.ko $M/          # ubox kmodloader expects the modules flat in /lib/modules/<release>/
for f in modules.builtin modules.builtin.modinfo; do [ -e /in/$f ] && cp /in/$f $M/; done
[ -d /in/firmware ] && { mkdir -p $R/lib/firmware; cp -a /in/firmware/. $R/lib/firmware/; }
cp /in/regdb/regulatory.db /in/regdb/regulatory.db.p7s $R/lib/firmware/
if [ -d /in/android-subset ]; then
    mkdir -p $R/opt/changxing60/android && cp -a /in/android-subset/. $R/opt/changxing60/android/
    mv $R/opt/changxing60/android/dev/__properties__ $R/opt/changxing60/android/dev-properties && rmdir $R/opt/changxing60/android/dev
fi
[ -d /in/android-gpu-subset ] && cp -a /in/android-gpu-subset/. $R/opt/changxing60/android/
# Internal-panel display stack: six external modules built by kernel/build-internal-display.sh
# (sprd-drm, sprd-vpu-pd, pwm-sprd, unisoc-iommu, zte_lcdbl_vsp_vsn, trusty-ipc) that are NOT part
# of the 109-module boot set, plus the status-page binary. They load at S95 from
# /opt/changxing60/bin/display-modules, not at boot, so a broken panel cannot stop the device booting.
[ -d /in/display ] && cp /in/display/*.ko $M/
[ -e /in/display ] && echo "display modules: $(ls /in/display/*.ko | wc -l)"
[ -d /in/screen-tools ] && for b in changxing60-screen keyinject wifimac; do
    [ -e /in/screen-tools/$b ] && { cp /in/screen-tools/$b $R/usr/bin/$b; chmod 755 $R/usr/bin/$b; }
done
[ -e /in/cltest ] && { mkdir -p $R/opt/changxing60/android/system/bin; cp /in/cltest $R/opt/changxing60/android/system/bin/cltest; chmod 755 $R/opt/changxing60/android/system/bin/cltest; }
[ -e /in/logdw ] && { cp /in/logdw $R/opt/changxing60/bin/logdw; chmod 755 $R/opt/changxing60/bin/logdw; }
# /in/tools is already bind-mounted read-only above, so this needs no new -v. Built by tools/modem/build.sh.
[ -e /in/tools/modem/changxing60-modemd ] && { cp /in/tools/modem/changxing60-modemd $R/opt/changxing60/bin/changxing60-modemd; chmod 755 $R/opt/changxing60/bin/changxing60-modemd; }
[ -e /in/bt-init ] && { cp /in/bt-init $R/opt/changxing60/bin/changxing60-bt-init; chmod 755 $R/opt/changxing60/bin/changxing60-bt-init; }
# full static busybox for the tools OpenWrt busybox leaves out (od, timeout, mountpoint, losetup, rfkill, telnetd)
if [ -e /in/busybox ]; then
    cp /in/busybox $R/opt/changxing60/bin/busybox; chmod 755 $R/opt/changxing60/bin/busybox
    mkdir -p $R/opt/changxing60/busybox-bin
    for a in od timeout losetup telnetd getty; do
        chroot $R /bin/sh -c "command -v $a" >/dev/null 2>&1 && continue
        ln -sf ../bin/busybox $R/opt/changxing60/busybox-bin/$a
    done
fi
mkdir -p $R/etc/changxing60
# The rootfs is assembled in a container, so /etc/resolv.conf is whatever Docker bind-mounted
# there: "nameserver 10.255.255.254", the Docker resolver. That address means nothing on the
# device, and the failure hides well -- dnsmasq still answers LAN clients from its own upstreams
# (/tmp/resolv.conf.d/resolv.conf.auto), so only lookups that originate ON the router break
# (apk update, LuCI package installs, curl). OpenWrt keeps /etc/resolv.conf as a symlink that
# netifd fills in.
ln -sfn /tmp/resolv.conf $R/etc/resolv.conf
# enable the services (rc.common "enable" needs ubus, which is not running in the build container).
# Globbed, not listed by hand: the hand-written list silently left a script out of rc.d, and a service
# that is installed but never enabled does not fail -- it just never runs. (changxing60-power, added
# 2026-10-15, was absent from the old list and would have been dead on arrival.)
for f in $R/etc/init.d/changxing60-*; do
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
# device. A silent loss that expensive deserves a banner. (docs/changxing60/backlog.md section 4.)
if [ -e $R/etc/init.d/openclash ] || [ -e $R/etc/openclash ]; then
    echo "openclash: present in this rootfs"
else
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! WARNING: this rootfs contains NO OpenClash."
    echo "!! The proxy stack lives only on the device, so flashing this tarball drops it."
    echo "!! Reinstalling needs a working WAN. See docs/changxing60/backlog.md section 4."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
# State what optional inputs actually landed. Each one is dropped silently when its mount is absent,
# and "the file is not in the image" stays invisible until the feature is needed on the device -- which
# is exactly how the internal panel and the screen tools went missing from every install.sh build.
# DOUBLE QUOTES ONLY here. A single quote closes the outer single-quoted script that starts at the
# `sh -eu -c` above, which truncates the whole container script. This block did exactly that when first
# written (printf with a single-quoted format string): the build printed everything up to this line,
# stopped, and still exited 0, so it looked like a successful build that had simply not written the
# tarball. That is the same trap the NOTE near the top of the script describes.
echo "included: modules=$(ls $M/*.ko 2>/dev/null | wc -l) display=$(ls /in/display/*.ko 2>/dev/null | wc -l) screen-tools=$(ls /in/screen-tools 2>/dev/null | wc -l) bt-init=$([ -e /in/bt-init ] && echo yes || echo NO) busybox=$([ -e /in/busybox ] && echo yes || echo NO) android-subset=$([ -d /in/android-subset ] && echo yes || echo NO)"
# Ownership. The image is assembled as container-root, but entries copied in from the host keep the
# uid of the host user: the trees under rootfs/overlay, openwrt/overlay and android-subset are owned
# by uid 1000 on the build machine, and `cp -a` writes the ownership of a source directory onto the
# destination even when that directory already exists -- so /usr, /etc, /www, /opt/changxing60 and the
# root directory itself all came out as 1000:1000. That is not cosmetic on the device: dropbear
# refuses public-key auth outright when /etc/dropbear is not owned by root (it reports that the
# directory must be owned by the user or by root, and not writable by group or others), which is how
# it was found on 2026-10-16 -- key auth failed while password auth worked. The same 1000:1000
# signature is what silently broke the Android property area (docs/changxing60/cptl-and-boot.md
# section 4.2). The base OpenWrt tree is root:root throughout, so normalise the whole image rather
# than chase paths one by one. busybox tar has no --owner/--group here (checked: only -o, and that is
# extract-side), hence an explicit chown.
# NOTE: no apostrophes in this comment, or anywhere else inside the single-quoted script above.
# -h is required here, not cosmetic. The image contains deliberately dangling symlinks (/etc/resolv.conf,
# /etc/localtime, /etc/TZ, /etc/ppp/resolv.conf, opt/changxing60/android/system/bin/linker64 and others)
# which only resolve at runtime on the device. Plain -R dereferences them, fails with ENOENT on the first
# one, and because this script runs under set -e that aborts the build before the tarball is written --
# measured 2026-10-16: EXIT=1, no tarball, and the failure looked like a missing file rather than a
# permission problem. busybox chown offers only -R and -h (its usage line is "chown [-Rh]"), and -Rh
# changes the links themselves while leaving them dangling, which is exactly what the device needs.
chown -Rh 0:0 $R
cd $R && tar -czf /out/$OUT .
ls -la /out/$OUT'
rm -rf "$REGDB"
