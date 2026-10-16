#!/system/bin/sh
# Restore `status = "okay"` on /soc/ipa-apb/dummyphy in the DTB inside vendor_boot_b.
#
# Why: patch-vendor-dtb.py disables that node for the 6.18 mainline boot, but vendor_boot_b is the
# DT source for the *5.4 OpenWrt* slot-b boot too.  Disabled there means no platform device, so
# phy_sprd_dummy never probes and never registers a usb_phy -- and the vendor dwc3-sprd glue then
# bails with "unable to get usb2.0 phy device", leaving no UDC, no gadget and no management
# interface (2026-10-16: the box booted every time and was unreachable every time).
#
# The write is 8 bytes, in place, inside the DT blob: "disabled\0" -> "okay\0\0\0\0\0" in a slot
# that is already padded to 12, so nothing moves -- same blob size, same table entry, no repack, no
# AVB bookkeeping.  Do not "improve" this into a whole-image write: the 8 bytes are the whole fix,
# and the readback check below is a full-partition sha256 of the result.
#
# Pushed by tools: /data/local/tmp/vb-patch.bin (the 8 bytes), vb-offset, vb-before.sha, vb-after.sha
# Usage on device:  su -c 'sh /data/local/tmp/changxing60-android-dtb-fix.sh'        (writes + arms slot b)
#                   NOARM=1 su -c 'sh ...'                                    (writes only)
set -eu
T=/data/local/tmp
DBPATH=$(cat $T/vb-partition 2>/dev/null || echo /dev/block/by-name/vendor_boot_b)
PATCH=$T/vb-patch.bin
OFF=$(cat $T/vb-offset)
WANT_BEFORE=$(cat $T/vb-before.sha)
WANT_AFTER=$(cat $T/vb-after.sha)
say() { echo "[dtbfix] $*"; }
die() { say "FAILED: $*"; exit 1; }

resolve() {
    p=$(readlink -f "$1" 2>/dev/null) || p="$1"
    [ -e "$p" ] || return 1
    echo "$p"
}
partname() {
    n=$(basename "$1")
    grep -m1 '^PARTNAME=' "/sys/class/block/$n/uevent" 2>/dev/null | cut -d= -f2
}

DB=$(resolve "$DBPATH") || die "no vendor_boot_b partition"
pn=$(partname "$DB")
say "node = $DB  PARTNAME=$pn"
# the one mistake that matters: vendor_boot_a belongs to Android on slot a and is never opened
[ "$pn" = "vendor_boot_b" ] || die "resolved vendor_boot_b is not PARTNAME=vendor_boot_b (got '$pn')"
[ -f "$PATCH" ] || die "vb-patch.bin not pushed"
[ "$(wc -c < $PATCH)" -ge 8 ] || die "vb-patch.bin is $(wc -c < $PATCH) bytes, expected >= 8"

say "--- backup the whole partition first"
dd if="$DB" of=$T/vendor_boot_b.backup.img bs=4M 2>&1 | tail -1
sync
bsha=$(sha256sum $T/vendor_boot_b.backup.img | cut -d' ' -f1)
say "backup sha256: $bsha"
[ "$bsha" = "$WANT_BEFORE" ] || die "device content $bsha is not the image we patched (expected $WANT_BEFORE)"
say "device matches the locally patched original: OK"

say "--- status bytes before: $(dd if=$DB bs=1 skip=$OFF count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')"
dd if=$PATCH of="$DB" bs=1 seek=$OFF conv=notrunc 2>&1 | tail -1
sync
say "--- status bytes after:  $(dd if=$DB bs=1 skip=$OFF count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')"
asha=$(sha256sum "$DB" | cut -d' ' -f1)
say "partition sha256 now: $asha"
[ "$asha" = "$WANT_AFTER" ] || die "readback $asha != expected $WANT_AFTER"
say "vendor_boot_b is byte-identical to the patched image (sha256 match)"

if [ "${NOARM:-0}" != "1" ]; then
    DM=$(resolve /dev/block/by-name/misc) || die "no misc partition"
    ARM=$T/vb-misc-arm.bin
    [ -f "$ARM" ] && [ "$(wc -c < $ARM)" = "32" ] || die "vb-misc-arm.bin missing or not 32 bytes"
    # Derived on the host from the *live* misc word by boot/build-boot-image.py:bootloader_control(),
    # i.e. the same function every previous flash used, CRC32 included.  Check what can be checked
    # from a shell (magic + target slot) and then compare the readback byte for byte.
    magic=$(dd if=$ARM bs=1 skip=4 count=4 2>/dev/null)
    [ "$magic" = "BCAB" ] || die "pushed arm blob has no BCAB magic at 4"
    [ "$(dd if=$ARM bs=1 count=2 2>/dev/null)" = "_b" ] || die "pushed arm blob does not target slot _b"
    say "--- arm slot b (32-byte bootloader_control @ 2048)"
    dd if=$ARM of="$DM" bs=1 seek=2048 conv=notrunc 2>&1 | tail -1
    sync
    got=$(dd if="$DM" bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
    want_arm=$(od -An -tx1 -v $ARM | tr -d ' \n')
    say "misc bootloader_control: $got"
    [ "$got" = "$want_arm" ] || die "misc readback wrong"
    say "slot b armed (suffix _b, prio 15, tries 2)"
fi

say "running slot now: $(getprop ro.boot.slot_suffix)"
echo CHANGXING60-DTB-FIX-OK
