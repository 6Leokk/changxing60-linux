#!/bin/bash
# Assemble the driver-adaptation payload from this repo, and (with --stage) install it into the
# device's OpenWrt rootfs -- from Android, over adb.
#
#   tools/stage-adapt.sh              build + self-check; no device needed, nothing is pushed
#   tools/stage-adapt.sh --manifest   print just the generated manifest
#   tools/stage-adapt.sh --stage      build, push, install, then prove the device runs these bytes
#
# The payload is *derived*, never remembered.  The 25 modules come from out-linux/ (the build whose
# vermagic matches the kernel on the board, checked per module below) and the four scripts come from
# openwrt/overlay/, which is where they are edited.  The manifest is written during the same run, from
# the very bytes that go into the tarball.
#
# The reason this tool exists: the first install (2026-10-16 02:42) was assembled by hand into
# work/adapt/ and pushed from that snapshot.  By the time the device was looked at again, the repo's
# overlay had moved on -- vendor-modules had dropped `misc` from its default groups after the CFI
# panic, bootdiag had grown usb_recover() and the bisect hook -- and the device kept running the old
# bytes, because every check compared the snapshot against itself.  A hash proves the file arrived; it
# cannot prove the file is the one the repo intends.  So the checks below read the loaders the way the
# kernel will (by content) and refuse to build a payload whose pieces disagree with each other:
#   * the manifest's three load groups must equal vendor-modules' group_* lists, and its touch group
#     must equal touch-ctl's LOAD -- otherwise the loader and the payload are talking past each other;
#   * vendor-modules must default to `crypto usbnet` (misc panics the kernel: CFI failure, NULL timer
#     callback, ~3 s after load);
#   * no init script or cron-run script other than touch-ctl may name a touch module.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
KREL=${KREL:-5.4.254-gb50db5b6224c}
OV=$ROOT/openwrt/overlay
VMS_SRC=$OV/opt/mu300/bin/vendor-modules
TCTL_SRC=$OV/opt/mu300/bin/touch-ctl
TARBALL=$ROOT/work/adapt-modules.tar
MANIFEST_TXT=$ROOT/work/adapt-modules.manifest
BUILD=$ROOT/work/adapt-build

say() { echo "[build] $*"; }
die() { echo "[build] FAILED: $*" >&2; exit 1; }
su_do() { "$ADB" shell "su -c '$1'" | tr -d '\r'; }
sha16() { sha256sum "$1" | cut -c1-16; }

# What gets staged, by group.  This is the payload list; the loader's own lists are the cross-check.
modules_list() {
	cat <<'EOF'
crypto	aes-ce-ccm.ko
crypto	aes-neon-blk.ko
crypto	arc4.ko
crypto	ghash-ce.ko
crypto	sha1-ce.ko
crypto	twofish_common.ko
crypto	twofish_generic.ko
usbnet	asix.ko
usbnet	ax88179_178a.ko
misc	apsys-dvfs.ko
misc	board_state.ko
misc	ion_cma_heap.ko
misc	ion_ipc_trusty.ko
misc	ledtrig-pattern.ko
misc	misc_sprd_uid.ko
misc	sensorhub.ko
misc	smartpa_stat.ko
misc	sprd-dma.ko
misc	sprd_map.ko
misc	virt-dma.ko
misc	zte_bootreason.ko
misc	zte_stats_info.ko
touch	lcd_state_notify.ko
touch	spi-sprd.ko
touch	zte_tpd.ko
EOF
}

# stage_module GROUP NAME.ko -- copy the one out-linux build of NAME.ko into the payload and record it
stage_module() {
	local grp=$1 name=$2 hits src vm
	hits=$(grep -c "/$name\$" "$BUILD/.tree-ko" || true)
	[ "$hits" = 1 ] || die "$name: $hits copies under out-linux, need exactly one"
	src=$(grep "/$name\$" "$BUILD/.tree-ko")
	vm=$(grep -a -o 'vermagic=[^ ]*' "$src" | head -1)
	[ "$vm" = "vermagic=$KREL" ] || die "$name carries $vm but the board runs $KREL -- rebuild (kernel/build-linux.sh)"
	cp "$src" "$BUILD/modules/$name"
	printf '%s\t%s\t%s\n' "$grp" "$name" "$(sha16 "$BUILD/modules/$name")" >> "$BUILD/opt/manifest.tsv"
}

build() {
	rm -rf "$BUILD"
	mkdir -p "$BUILD/modules" "$BUILD/opt" "$BUILD/etc"
	find "$ROOT/out-linux" -name '*.ko' > "$BUILD/.tree-ko" || die "cannot list out-linux (build the kernel first: kernel/build-linux.sh)"
	[ -s "$BUILD/.tree-ko" ] || die "out-linux holds no .ko -- build the kernel first"
	: > "$BUILD/opt/manifest.tsv"
	# The loaders themselves say what to stage and in what order (group_misc's order is load-bearing:
	# virt-dma before sprd-dma, ion_ipc_trusty before ion_cma_heap), so the manifest is read off them
	# rather than kept as a second list that can drift.  modules_list() below is the expected set, and
	# cross_check() compares the two -- which is how a module added to a loader without being staged
	# (or staged without a loader that would ever load it) gets caught here instead of on the device.
	local g m
	for g in crypto usbnet misc; do
		while read -r m; do [ -n "$m" ] || continue; stage_module "$g" "$m.ko"; done < <(group_members "$VMS_SRC" "$g")
	done
	while read -r m; do
		[ -n "$m" ] || continue; stage_module touch "$m.ko"
	done < <(sed -n 's/^LOAD="\(.*\)"/\1/p' "$TCTL_SRC" | tr ' ' '\n')
	say "modules: $(wc -l < "$BUILD/opt/manifest.tsv"), all vermagic $KREL"

	local f
	for f in vendor-modules touch-ctl bootdiag; do
		[ -f "$OV/opt/mu300/bin/$f" ] || die "missing $OV/opt/mu300/bin/$f"
		install -m 755 "$OV/opt/mu300/bin/$f" "$BUILD/opt/$f"
	done
	install -m 755 "$OV/etc/init.d/mu300-hw" "$BUILD/etc/mu300-hw"
	# parse with the host's /bin/sh (dash) -- stricter than the box's busybox ash, so a pass here is
	# not proof, but a failure here is proof the device would have choked
	for f in "$BUILD/opt/vendor-modules" "$BUILD/opt/touch-ctl" "$BUILD/opt/bootdiag" "$BUILD/etc/mu300-hw"; do
		sh -n "$f" || die "$(basename "$f") does not parse"
	done
	say "scripts: 3 into /opt/mu300/bin + etc/init.d/mu300-hw, all parse"

	# --sort/--mtime: same inputs, same tarball, so a device-side hash mismatch can only mean transit
	tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$TARBALL" -C "$BUILD" modules opt etc
	cp "$BUILD/opt/manifest.tsv" "$MANIFEST_TXT"
	say "payload: $TARBALL ($(stat -c %s "$TARBALL") bytes, sha256 $(sha256sum "$TARBALL" | cut -c1-16)…)"
}

# group_members FILE GROUP -> the module names one group_*() actually loads, in order
group_members() {
	sed -n "/^group_$2()/,/^}/p" "$1" \
		| awk '/for m in/{f=1} f{print} /; do/{f=0}' \
		| sed 's/.*for m in//; s/; do.*//' | tr ' ' '\n' | sed 's/\\//' | grep -v '^$'
}

# There are two overlays and build-rootfs.sh copies rootfs/overlay first and openwrt/overlay over it,
# so the newer tree wins wherever both carry a file.  Checks that are about what the *box* ends up
# running (as opposed to what we stage) have to read the winner, not a tree by name.
overlay_file() { # overlay_file RELPATH
	if [ -f "$OV/$1" ]; then echo "$OV/$1"
	elif [ -f "$ROOT/rootfs/overlay/$1" ]; then echo "$ROOT/rootfs/overlay/$1"
	fi
}


cross_check() {
	local vms=$BUILD/opt/vendor-modules tctl=$BUILD/opt/touch-ctl bdiag=$BUILD/opt/bootdiag
	local want got

	# 1. the staged set and the loaders' lists must be the same set (the order is the loaders' by
	# construction now, so only membership can drift) -- a module in a loader but not in the payload
	# would be a MISSING line at boot; one in the payload but in no loader would just sit there
	want=$(modules_list | sort)
	got=$(cut -f1,2 "$BUILD/opt/manifest.tsv" | sort)
	if [ "$want" != "$got" ]; then
		diff <(echo "$want") <(echo "$got") | sed 's/^-/  loaders only: /; s/^+/  payload only: /' >&2
		die "the payload and the loaders disagree about which modules exist (see above)"
	fi
	want=$(modules_list | cut -f1 | sort -u | tr '\n' ' ')
	say "cross-checks: payload == loaders ($(echo "$got" | wc -l) modules; groups: $want)"

	# 2. the default load set, read exactly as the boot path reads it
	grep -q 'MU300_VENDOR_GROUPS:-crypto usbnet}' "$vms" || \
		die "vendor-modules no longer defaults to 'crypto usbnet' -- misc in the default set is the CFI panic"
	grep -q 'bisect_verdict' "$vms" || die "vendor-modules lost the bisect verdict"
	grep -q 'usb_recover' "$bdiag" || die "bootdiag lost usb_recover (the late-UDC repair)"
	grep -q 'vendor-modules bisect' "$bdiag" || die "bootdiag lost the bisect hook"
	say "cross-checks: default groups safe, usb_recover + bisect hooks present"

	# 3. no init script or cron-run script may reach a touch module -- only touch-ctl may
	local f p bad
	for f in vendor-modules bootdiag extra-modules display-modules; do
		p=$(overlay_file "opt/mu300/bin/$f")
		[ -n "$p" ] || continue
		bad=$(sed 's/#.*//' "$p" | grep -nE 'zte[-_]tpd|spi[-_]sprd|lcd[-_]state[-_]notify' || true)
		[ -z "$bad" ] || die "$p loads a touch module ($bad); touch is off by default"
	done
	grep -q 'zte_tpd' "$tctl" || die "touch-ctl no longer knows the touch modules"
	local eh=$OV/etc/init.d/mu300-hw
	grep -q '/opt/mu300/bin/vendor-modules' "$eh" || die "mu300-hw lost the vendor-modules hook"
	grep -q 'mu300/bin/bootdiag' "$eh" || die "mu300-hw lost the bootdiag hook"
	say "cross-checks: touch reachable only through touch-ctl, mu300-hw hooks in place"
}

print_manifest() {
	printf '%-8s %-22s %s\n' GROUP MODULE "sha256[0:16]"
	while IFS=$'\t' read -r g n h; do printf '%-8s %-22s %s\n' "$g" "$n" "$h"; done < "$BUILD/opt/manifest.tsv"
}

# The point of the whole rebuild: prove the device is running these bytes, not older ones.  Reads what
# mu300-android-stage-adapt.sh reported (INSTALLED/MODULE lines), so it can also be run afterwards on
# a saved report -- --verify-log.
verify_report() { # verify_report FILE
	local out f want got n=0
	out=$(cat "$1")
	local grp m h
	for f in vendor-modules touch-ctl bootdiag; do
		want=$(sha16 "$OV/opt/mu300/bin/$f")
		got=$(echo "$out" | awk -v p="/opt/mu300/bin/$f" '$1=="INSTALLED" && $3==p {print $2}')
		[ "$got" = "$want" ] || die "device /opt/mu300/bin/$f is ${got:-absent}, repo says $want -- the device is not running the repo's bytes"
		say "  device == repo: /opt/mu300/bin/$f ($want)"
	done
	want=$(sha16 "$OV/etc/init.d/mu300-hw")
	got=$(echo "$out" | awk '$1=="INSTALLED" && $3=="/etc/init.d/mu300-hw" {print $2}')
	[ "$got" = "$want" ] || die "device /etc/init.d/mu300-hw is ${got:-absent}, repo says $want"
	say "  device == repo: /etc/init.d/mu300-hw ($want)"
	while IFS=$'\t' read -r grp m h; do
		got=$(echo "$out" | awk -v mm="$m" '$1=="MODULE" && $3==mm {print $2}')
		[ "$got" = "$h" ] || die "device reports module $m as ${got:-missing}, manifest says $h"
		n=$((n + 1))
	done < "$BUILD/opt/manifest.tsv"
	say "  device == manifest: all $n modules"
	echo "$out" | grep -q 'MU300-ADAPT-OK' || die "device-side install did not report OK"
	say "STAGE-ADAPT-OK"
}

stage() {
	[ "$(su_do 'getprop ro.boot.slot_suffix')" = "_a" ] || \
		die "device is not running Android on slot a (this mounts the ext4 rootfs; see tools/mu300-dtb-fix.sh for the same rule)"
	[ -f "$HERE/android-mount-mu300root.sh" ] || die "tools/android-mount-mu300root.sh is missing"
	say "pushing to the device ..."
	su_do 'rm -f /data/local/tmp/adapt-modules.tar'
	"$ADB" push "$TARBALL" /data/local/tmp/adapt-modules.tar >/dev/null || die "adb push tarball failed"
	"$ADB" push "$HERE/android-mount-mu300root.sh" /data/local/tmp/android-mount-mu300root.sh >/dev/null
	"$ADB" push "$HERE/mu300-android-stage-adapt.sh" /data/local/tmp/mu300-android-stage-adapt.sh >/dev/null
	local have; have=$(sha256sum "$TARBALL" | cut -d' ' -f1)
	[ "$(su_do 'sha256sum /data/local/tmp/adapt-modules.tar' | cut -d' ' -f1)" = "$have" ] || \
		die "tarball changed in transit (sha256 mismatch on the device)"

	say "running the device-side install (mounts the ext4 rootfs; ~1 min)"
	local LOG=$ROOT/work/adapt-stage-$(date +%Y%m%d-%H%M).log
	su_do 'sh /data/local/tmp/mu300-android-stage-adapt.sh' > "$LOG" 2>&1 || true
	cat "$LOG"
	say "device report kept: $LOG"
	verify_report "$LOG"
}

case "${1:-}" in
'')          build; cross_check; echo; print_manifest ;;
--manifest)  build; cross_check; print_manifest ;;
--verify-log) [ -n "${2:-}" ] || die "usage: stage-adapt.sh --verify-log FILE"
             build; cross_check; verify_report "$2" ;;
--stage)     build; cross_check; stage
             echo
             say "next: tools/mu300-dtb-fix.sh   (9 bytes in vendor_boot_b + arm slot b; no boot image touched)"
             say "then:  $ADB reboot  →  tools/mu300-verify-usb.sh --wait" ;;
*)           echo "usage: stage-adapt.sh [--manifest|--verify-log FILE|--stage]" >&2; exit 2 ;;
esac
