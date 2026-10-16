#!/bin/sh
# Bring the box back over USB: restore `status = "okay"` on /soc/ipa-apb/dummyphy in the DTB inside
# vendor_boot_b, from rooted Android over adb.
#
# Why the fix is 9 bytes: see mainline-7552n/tools/vendor-dtb-status.py (the "why this exists" note)
# and docs/mu300/drivers.md §USB.  Short version: patch-vendor-dtb.py disables that node for the 6.18
# mainline boot, vendor_boot_b is *also* the DT source for the 5.4 OpenWrt slot-b boot, and with the
# node disabled phy_sprd_dummy never probes -> no usb_phy -> dwc3-sprd "unable to get usb2.0 phy
# device" -> no UDC -> the OpenWrt boot comes up with no management interface at all.
#
# Steps (each one prints, nothing silent):
#   1. adb + slot must be _a (Android).  boot_a / vendor_boot_a are never opened by anything here.
#   2. push the two device scripts, run the read-only collect, pull the evidence into work/collect-*/
#   3. show the installed DTB's dummyphy status -- if it is already "okay" there is nothing to fix
#   4. vendor-dtb-status.py --prep: patched partition image + vb-patch.bin/offset/before/after shas
#   5. derive the slot-b bootloader_control block from the *live* misc word (boot/build-boot-image.py's
#      bootloader_control(), the same derivation every previous flash used -- never hand-built bytes)
#   6. run the device-side writer, which backs the partition up, checks the pre-write sha256 against
#      the image we patched, writes the bytes, and verifies a full-partition sha256 of the result
#
# usage: tools/mu300-dtb-fix.sh              # inspect + fix + arm slot b
#        NOARM=1 tools/mu300-dtb-fix.sh      # do not touch misc
#        REBOOT=1 tools/mu300-dtb-fix.sh     # reboot into OpenWrt at the end
#        COLLECT_ONLY=1 tools/mu300-dtb-fix.sh   # evidence only, no writes
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
T=/data/local/tmp
STAMP=$(date +%Y%m%d-%H%M)
OUT=${OUT:-$ROOT/work/collect-$STAMP}
PREP=$OUT/prep

say() { echo "[dtbfix] $*"; }
die() { echo "[dtbfix] FAILED: $*" >&2; exit 1; }
su_do() { "$ADB" shell "su -c '$1'" | tr -d '\r'; }

say "adb devices:"; "$ADB" devices | sed -n '2,$p' | grep -v '^$' || die "no device on adb"
slot=$(su_do 'getprop ro.boot.slot_suffix')
say "slot_suffix=$slot"
[ "$slot" = "_a" ] || die "device is running slot $slot, not _a (Android) -- the fix is written from Android"
mkdir -p "$OUT" "$PREP"

# ---------------------------------------------------------------- 1. device scripts + evidence
say "--- pushing device scripts"
for f in mu300-android-collect.sh mu300-android-dtb-fix.sh; do
    "$ADB" push "$HERE/$f" $T/$f >/dev/null || die "push $f failed"
done

say "--- collect (read-only)"
su_do "sh $T/mu300-android-collect.sh" | tee "$OUT/collect.log"
grep -q MU300-COLLECT-OK "$OUT/collect.log" || die "collect did not finish"

for f in state.txt vb-dtb.bin persist-boot_b.bin; do
    "$ADB" pull $T/$f "$OUT/$f" >/dev/null || die "pull $f failed"
done
say "pulled $OUT/{state.txt,vb-dtb.bin,persist-boot_b.bin}"
strings "$OUT/persist-boot_b.bin" 2>/dev/null | grep -E 'stage=usb|dummyphy|stage=udc|stage=modules-done' | tail -20 || true

say "--- vendor_boot_b backup (100 MiB, kept for the way back)"
"$ADB" pull $T/vendor_boot_b.backup.img "$OUT/vendor_boot_b.installed.img" >/dev/null || die "pull backup failed"
[ "$(stat -c %s "$OUT/vendor_boot_b.installed.img")" = "104857600" ] || die "backup is not 100 MiB"
live=$(sed -n 's/^vendor_boot_b=//p' "$OUT/state.txt")
say "installed vendor_boot_b sha256: $live"
[ "$(sha256sum "$OUT/vendor_boot_b.installed.img" | cut -d' ' -f1)" = "$live" ] || die "pulled backup != device content"

if [ "${COLLECT_ONLY:-0}" = "1" ]; then
    say "COLLECT_ONLY=1: stopping before any write.  Evidence in $OUT"
    exit 0
fi

# ---------------------------------------------------------------- 2. is there anything to fix?
say "--- dummyphy status in the installed DTB"
python3 "$ROOT/mainline-7552n/tools/vendor-dtb-status.py" \
    --image "$OUT/vendor_boot_b.installed.img" --node dummyphy --show
if python3 "$ROOT/mainline-7552n/tools/vendor-dtb-status.py" \
        --image "$OUT/vendor_boot_b.installed.img" --node dummyphy --show | grep -q "status = 'okay'"; then
    say "already okay -- no DTB change needed; USB should work on the next slot-b boot"
    NOARM=${NOARM:-1}
else
    # ------------------------------------------------------------ 3. build the patch
    say "--- patching (in place, size preserving)"
    python3 "$ROOT/mainline-7552n/tools/vendor-dtb-status.py" \
        --image "$OUT/vendor_boot_b.installed.img" --node dummyphy --set okay --prep "$PREP"

    # ------------------------------------------------------------ 4. the misc arm block
    if [ "${NOARM:-0}" != "1" ]; then
        say "--- deriving the slot-b bootloader_control from the live misc word"
        python3 - "$OUT/state.txt" "$PREP/vb-misc-arm.bin" "$ROOT" <<'PY'
import importlib.util, re, sys, zlib
state, dest, root = sys.argv[1], sys.argv[2], sys.argv[3]
hexw = re.search(r'^misc@2048=([0-9a-f]+)$', open(state).read(), re.M)
if not hexw or len(hexw.group(1)) != 64:
    sys.exit('no usable misc@2048 word in state.txt')
bc = bytes.fromhex(hexw.group(1))
spec = importlib.util.spec_from_file_location('bbi', root + '/boot/build-boot-image.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a_blk, b_blk = m.bootloader_control(b'\0' * m.MISC_BC_OFFSET + bc)   # from the LIVE state, not a constant
assert zlib.crc32(b_blk[:28]) == int.from_bytes(b_blk[28:], 'little')
open(dest, 'wb').write(b_blk)
print(f'  live  : {bc.hex()}')
print(f'  arm _b: {b_blk.hex()}')
PY
    fi

    # ------------------------------------------------------------ 5. write it
    say "--- pushing patch + arm block"
    for f in vb-patch.bin vb-offset vb-before.sha vb-after.sha; do
        "$ADB" push "$PREP/$f" $T/$f >/dev/null || die "push $f failed"
    done
    [ "${NOARM:-0}" = "1" ] || "$ADB" push "$PREP/vb-misc-arm.bin" $T/vb-misc-arm.bin >/dev/null

    say "--- device-side write"
    if [ "${NOARM:-0}" = "1" ]; then
        su_do "NOARM=1 sh $T/mu300-android-dtb-fix.sh" | tee "$OUT/fix.log"
    else
        su_do "sh $T/mu300-android-dtb-fix.sh" | tee "$OUT/fix.log"
    fi
    grep -q MU300-DTB-FIX-OK "$OUT/fix.log" || die "device-side fix did not report OK"
    say "vendor_boot_b now: $(su_do 'sha256sum /dev/block/by-name/vendor_boot_b' | cut -d' ' -f1)"
fi

# ---------------------------------------------------------------- 6. readback + next step
say "--- readback of the DTB as the device has it now"
su_do "dd if=/dev/block/by-name/vendor_boot_b bs=1 skip=$(cat "$PREP/vb-offset") count=16 2>/dev/null | od -An -tx1 -v" \
    | tr -d ' \n' | tee "$OUT/dtb-bytes-after.txt"; echo
say "evidence + backup: $OUT"

if [ "${REBOOT:-0}" = "1" ]; then
    say "rebooting into OpenWrt (slot b armed); USB should come up as usb0 on 192.168.77.1"
    "$ADB" reboot
else
    say "next: adb reboot   (slot b is armed; slot a stays the fallback if the boot fails)"
fi
