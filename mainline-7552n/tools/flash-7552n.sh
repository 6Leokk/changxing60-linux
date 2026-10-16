#!/bin/sh
# Flash the 7552N 6.18 trial to **slot b only** -- boot_b, vendor_boot_b and the 32-byte misc tries word.
# boot_a / vendor_boot_a are never written, so LK's tries fallback always returns to the Android on slot a.
#
# Why vendor_boot_b at all: LK does not take its DTB from the boot image -- it takes it from the selected
# slot's vendor_boot DT table.  Our whole UFS fix is four properties added to that DTB (see
# patch-vendor-dtb.py), so the trial is boot_b AND vendor_boot_b, both slot b.
#
# usage: flash-7552n.sh [boot-image]     (default: work/boot-618-slotb.img, flashed via boot/flash-trial.sh)
#        flash-7552n.sh --restore-vendor-boot     (put the stock vendor_boot_b back, e.g. to back out)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}   # the project rule: Windows-side adb only (5037 must not be shared)
su_do() { "$ADB" shell "su -c '$1'" | tr -d '\r'; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

[ "$(su_do 'getprop ro.boot.slot_suffix')" = "_a" ] || { echo "device is not running slot a" >&2; exit 1; }

backup_vendor_boot() {   # keep the live slot-b vendor_boot once, so --restore-vendor-boot always works
    [ -f "$ROOT/work/dumps/vendor_boot_b.stock.img" ] && return
    echo "backing up live vendor_boot_b ..."
    su_do 'dd if=/dev/block/by-name/vendor_boot_b of=/data/local/tmp/vbb-stock.img bs=1M' >/dev/null
    "$ADB" pull /data/local/tmp/vbb-stock.img "$ROOT/work/dumps/vendor_boot_b.stock.img" >/dev/null
    su_do 'rm -f /data/local/tmp/vbb-stock.img'
    [ "$(stat -c %s "$ROOT/work/dumps/vendor_boot_b.stock.img")" = "104857600" ] ||
        { echo "backup is not 100 MiB -- refusing to touch vendor_boot_b" >&2; exit 1; }
}

flash_vendor_boot() {   # flash_vendor_boot SRC  (SRC must be a full 100 MiB vendor_boot_b partition image)
    # NOTE: work/vendor_boot_b-7552n.img carries mainline's `dummyphy { status = "disabled" }`, and
    # that partition is *also* the DTB source for the 5.4 OpenWrt slot-b boot -- where the disabled node
    # means no usb_phy, no UDC and no management interface (the 2026-10-14..16 unreachable box).  Going
    # back to OpenWrt therefore needs the 9-byte in-place restore, not just a boot_b flash:
    #     tools/mu300-dtb-fix.sh          # from Android, over adb; NOARM=1 if misc is already armed
    # `--restore-vendor-boot` flashes the *stock* DTB, which also fixes 5.4 USB (but drops the ufs/gpu
    # mainline edits, so the next 6.18 trial has to re-run patch-vendor-dtb.py).
    src=$1
    [ "$(stat -c %s "$src")" = "104857600" ] || { echo "not a full 100 MiB vendor_boot_b image: $src" >&2; exit 1; }
    have=$(sha_of "$src")
    "$ADB" push "$src" /data/local/tmp/vbb.img >/dev/null
    [ "$(su_do 'sha256sum /data/local/tmp/vbb.img' | cut -d' ' -f1)" = "$have" ] || { echo "pushed hash mismatch" >&2; exit 1; }
    su_do 'dd if=/data/local/tmp/vbb.img of=/dev/block/by-name/vendor_boot_b bs=4M && sync'
    got=$(su_do 'sha256sum /dev/block/by-name/vendor_boot_b' | cut -d' ' -f1)
    [ "$got" = "$have" ] || { echo "vendor_boot_b verify FAILED: $got != $have -- slot a is untouched, restore with --restore-vendor-boot" >&2; exit 1; }
    su_do 'rm -f /data/local/tmp/vbb.img'
    echo "vendor_boot_b written and verified ($have)"
}

if [ "${1:-}" = "--restore-vendor-boot" ]; then
    flash_vendor_boot "$ROOT/work/dumps/vendor_boot_b.stock.img"
    exit 0
fi

# the stock backup must exist before we touch anything that depends on it
backup_vendor_boot
flash_vendor_boot "$ROOT/work/vendor_boot_b-7552n.img"
# boot_b + the misc tries word (boot/flash-trial.sh verifies both ends itself and reboots)
exec "$ROOT/boot/flash-trial.sh" "${1:-$ROOT/work/boot-618-slotb.img}"
