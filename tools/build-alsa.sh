#!/bin/bash
# Put alsa-lib and alsa-utils on a RUNNING changxing60, and check they work.
#
# WHY THIS IS NOT A CROSS BUILD. The obvious plan -- cross-build alsa-lib with changxing60-cross --
# cannot work here, and it is worth writing down so nobody tries it again. The rootfs is musl
# (/lib/ld-musl-aarch64.so.1) and changxing60-cross is a glibc toolchain, so a libasound.so.2 built
# there would be linked against the glibc loader and could never be dlopen'd by the device's musl
# python3. The only correct source for these two is the OpenWrt feed, which builds them for exactly
# this target -- and that is not a workaround, it is how every other package in this rootfs arrives.
#
# WHY THIS IS NOT THE ROOTFS MECHANISM EITHER. The canonical path is one line in
# openwrt/build-rootfs.sh:
#     apk add alsa-lib alsa-utils
# This script does not replace it and must not drift from it. It exists for the other case: the
# device is already flashed with a 45 GB ext4 rootfs, and rebuilding and reflashing that image to
# add two libraries is a bad trade. The apk add below is the same operation, run on the live box.
#
# What the two packages give us:
#   libasound.so.2      the PCM half of changxing60-voice-audio (the mixer half is raw ioctls and
#                       needs no library at all -- see the header of that script for why)
#   /usr/share/alsa     libasound reads this config tree when it resolves a name like "hw:0,5";
#                       shipping only the .so without it is a subtle way to get ENOENT on open
#   amixer              the fastest way to enumerate this card's real controls by hand
#   aplay/arecord       not used by the daemon, but they come in the same package
#
# One side effect to know about: alsa-lib depends on kmod-sound-core, which is built for the armsr
# 6.12 kernel. It drops eight snd-*.ko into /lib/modules/6.12.94/ and an /etc/modules.d/30-sound-core
# that ubox kmodloader does read, so it would try ten modprobes for a kernel that is not running on
# every boot. The modules themselves are inert (kmodloader keys off uname -r); the autoload file is
# not, and bogus FAILED lines in the boot log have already cost this project real time, so this
# script removes the payload just as build-rootfs.sh does.
#
# Usage: tools/build-alsa.sh                    install on the default host, then verify
#        tools/build-alsa.sh --verify-only      check only; changes nothing on the device
#        tools/build-alsa.sh --host root@X     a different device
set -euo pipefail

HOST=root@192.168.77.1
VERIFY_ONLY=0
while [ $# -gt 0 ]; do
	case "$1" in
	--host) HOST=$2; shift 2 ;;
	--verify-only) VERIFY_ONLY=1; shift ;;
	-h | --help) sed -n '2,40p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

ssh_() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$HOST" "$@"; }

if [ "$VERIFY_ONLY" = 0 ]; then
	echo "== installing alsa-lib alsa-utils on $HOST"
	ssh_ 'apk update >/dev/null 2>&1; apk add alsa-lib alsa-utils' || {
		echo "apk add failed" >&2
		exit 1
	}
	# Match the image: drop the 6.12 kmod payload (see the header). Both removals are no-ops on a
	# device that never had the package, and neither can touch the 5.4 module tree we actually load.
	ssh_ 'rm -f /lib/modules/6.12.94/snd-*.ko /etc/modules.d/30-sound-core'
fi

echo "== verifying on $HOST"
fail=0
check() {
	local label=$1 expected=$2 actual=$3
	if [ "$actual" = "$expected" ]; then
		echo "  ok    $label: $actual"
	else
		echo "  FAIL  $label: expected $expected, got $actual" >&2
		fail=1
	fi
}

check "alsa-lib version" "alsa-lib-1.2.11-r1" \
	"$(ssh_ 'apk info -v 2>/dev/null | grep "^alsa-lib-"' | tr -d '\r')"
check "alsa-utils version" "alsa-utils-1.2.11-r1" \
	"$(ssh_ 'apk info -v 2>/dev/null | grep "^alsa-utils-"' | tr -d '\r')"
check "libasound.so.2" "yes" \
	"$(ssh_ '[ -e /usr/lib/libasound.so.2 ] && echo yes || echo no')"
check "alsa.conf (libasound cannot resolve hw: without it)" "yes" \
	"$(ssh_ '[ -e /usr/share/alsa/alsa.conf ] && echo yes || echo no')"
check "amixer" "yes" "$(ssh_ '[ -x /usr/bin/amixer ] && echo yes || echo no')"
check "amixer reads the card" "controls=319" \
	"$(ssh_ 'echo controls=$(amixer -c 0 controls 2>/dev/null | wc -l)')"
# The one that actually matters: the daemon loads libasound through ctypes, from musl python3.
check "python3 ctypes dlopen" "loaded" \
	"$(ssh_ 'python3 -c "import ctypes; ctypes.CDLL(\"libasound.so.2\"); print(\"loaded\")" 2>&1 | tail -1' | tr -d '\r')"
check "6.12 kmod payload removed" "0" \
	"$(ssh_ 'ls /lib/modules/6.12.94/snd-*.ko 2>/dev/null | wc -l')"
check "30-sound-core autoload removed" "0" \
	"$(ssh_ '[ -e /etc/modules.d/30-sound-core ] && echo 1 || echo 0')"

if [ "$fail" = 0 ]; then
	echo "alsa: PASSED"
else
	echo "alsa: FAILED" >&2
fi
exit "$fail"
