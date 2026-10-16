#!/bin/bash
# From Android, put the box back into OpenWrt in one command, in the one order that is safe, and then
# check that it actually came up reachable.
#
# Two things must happen before the reboot, and their order is not arbitrary:
#
#   1. tools/stage-adapt.sh --stage
#      Reinstall the driver-adaptation payload.  This goes first because the payload's vendor-modules
#      is what decides what the NEXT boot loads, and the copy on the device right now is the 02:42
#      hand-assembled snapshot, whose default group set still contains `misc` -- the group that takes
#      the kernel down with `CFI failure (target: 0x0)` about three seconds after it loads.  Rebooting
#      with that in place turns "no USB" into "no boot at all".
#   2. tools/changxing60-dtb-fix.sh
#      9 bytes in vendor_boot_b: /soc/ipa-apb/dummyphy back to `status = "okay"`, then arm slot b for
#      one try.  Without it the next slot-b boot has no usb2.0 phy provider, no UDC and no way in.
#   3. reboot + tools/changxing60-verify-usb.sh --wait   (UDC, dummyphy bound, gadget attached, usb0 up)
#
# Each step is a tool in its own right that verifies itself and prints its own OK marker; this script
# only sequences them and refuses to move on when a marker is missing.  That matters because the box
# is only intermittently on adb: a half-done sequence that reboots anyway is worse than no sequence.
#
#   tools/changxing60-back-to-openwrt.sh              stage → dtb fix → reboot → verify
#   tools/changxing60-back-to-openwrt.sh --dry-run    probe the device and print the plan; write nothing
#   tools/changxing60-back-to-openwrt.sh --no-reboot  both writes, no reboot
#   NOSTAGE=1 ...    skip step 1 (e.g. `tools/stage-adapt.sh --verify-log` already showed the device
#                    holds the repo's bytes)
#   NOARM=1 ...      passed through to changxing60-dtb-fix.sh: do not touch the misc tries word
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
DRY=0
REBOOT=1
for a in "$@"; do
	case "$a" in
	--dry-run)   DRY=1 ;;
	--no-reboot) REBOOT=0 ;;
	*) echo "usage: changxing60-back-to-openwrt.sh [--dry-run|--no-reboot]" >&2; exit 2 ;;
	esac
done

say() { echo "[back] $*"; }
die() { echo "[back] FAILED: $*" >&2; exit 1; }
su_do() { "$ADB" shell "su -c '$1'" | tr -d '\r'; }
LOG=$ROOT/work/back-to-openwrt-$(date +%Y%m%d-%H%M).log
mkdir -p "$(dirname "$LOG")" || die "cannot write $LOG"

# ---------------------------------------------------------------- where is the box
dev=$("$ADB" devices 2>/dev/null | sed -n '2,$p' | grep -v '^$')
[ -n "$dev" ] || die "no device on adb. From an unreachable OpenWrt on slot b the way back is two power cycles inside the first ~70 s of boot (misc tries 2→1→0); the third boot lands on Android. Nothing here can be done from the host."
slot=$(su_do 'getprop ro.boot.slot_suffix')
say "device: $(echo "$dev" | sed 's/\t/ /g' | paste -sd' ')"
say "slot_suffix=$slot"
[ "$slot" = "_a" ] || die "device is running slot $slot, not _a (Android) -- both writes are made from Android; boot_a/vendor_boot_a are never touched by either tool"

# Preflight the steps.  This script execs them by path, so a missing executable bit shows up as nothing
# but "Permission denied" (exit 126) from the shell -- which is exactly how the 2026-10-16 08:11 run
# ended, after the payload had already been reinstalled.  Name it here instead.
for s in stage-adapt.sh changxing60-dtb-fix.sh changxing60-verify-usb.sh; do
	[ -f "$HERE/$s" ] || die "missing step: $HERE/$s"
	[ -x "$HERE/$s" ] || die "step not executable: $HERE/$s (chmod 755 it -- this script runs its steps directly, so without the bit they exit 126 with only 'Permission denied' to go on)"
done

if [ "$DRY" = 1 ]; then
	if [ "${NOSTAGE:-0}" = 1 ]; then s1="SKIPPED (NOSTAGE=1)"; else s1="reinstall the payload from the repo"; fi
	if [ -n "${NOARM:-}" ]; then s2="; NOARM=1, so the misc tries word is untouched"; else s2=""; fi
	say "--dry-run: nothing will be written or rebooted.  The plan, and what the payload would be:"
	say "  1/3 tools/stage-adapt.sh --stage             ($s1)"
	say "  2/3 REBOOT=$REBOOT tools/changxing60-dtb-fix.sh    (dummyphy → okay, arm slot b$s2)"
	say "  3/3 tools/changxing60-verify-usb.sh --wait"
	"$HERE/stage-adapt.sh" | sed 's/^/      /'
	exit 0
fi

# ---------------------------------------------------------------- 1/3 the payload
if [ "${NOSTAGE:-0}" = 1 ]; then
	say "1/3 skipped (NOSTAGE=1)"
else
	say "1/3 staging the adaptation payload, built from this repo (log: $LOG)"
	"$HERE/stage-adapt.sh" --stage 2>&1 | tee -a "$LOG" | grep -E '^\[build\]|^INSTALLED|^MODULE|^\[stage\]' | tail -25
	grep -q 'STAGE-ADAPT-OK' "$LOG" || \
		die "stage-adapt.sh did not report STAGE-ADAPT-OK -- do NOT reboot: the device may still default to the misc group, which panics the kernel.  Full log: $LOG"
	say "1/3 ok: the device's loaders are this repo's bytes"
fi

# ---------------------------------------------------------------- 2/3 the DTB
say "2/3 DTB: dummyphy back to okay, then arm slot b$([ "$REBOOT" = 1 ] && echo ' and reboot')"
REBOOT=$REBOOT "$HERE/changxing60-dtb-fix.sh" 2>&1 | tee -a "$LOG" | tail -18
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || die "changxing60-dtb-fix.sh exited $rc -- nothing has been rebooted by it unless it printed 'rebooting'.  Log: $LOG"
grep -q 'CHANGXING60-DTB-FIX-OK\|already okay' "$LOG" || \
	die "the DTB write did not report CHANGXING60-DTB-FIX-OK (log: $LOG)"

# ---------------------------------------------------------------- 3/3 verify
if [ "$REBOOT" = 1 ]; then
	say "3/3 waiting for the box to come up in OpenWrt -- this is the moment of truth"
	exec "$HERE/changxing60-verify-usb.sh" --wait
else
	say "stopped before the reboot (--no-reboot).  When ready:  $ADB reboot"
	say "then:  tools/changxing60-verify-usb.sh --wait"
fi
