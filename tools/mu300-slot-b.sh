#!/bin/sh
# Drive the 6.18 trial from the device's *own* OpenWrt shell -- no adb, no Android.
#
# Why a second flash path: boot/flash-trial.sh and mainline-7552n/tools/flash-7552n.sh both assume the
# device is sitting in Android on slot a with `adb` + `su`, because that is how the first trials were
# run.  But the device spends its life in OpenWrt on slot b, and slot b is exactly what we are
# replacing -- so pushing the images over the management link and doing the dd on the device itself is
# strictly less work, and it never has to leave OpenWrt.  The partition writes are identical; what
# differs is only who runs them.
#
# Safety is the same as the adb path: boot_a and vendor_boot_a are never opened, and the only misc
# write is the 32-byte bootloader_control that arms slot b for a one-shot trial.  If the 6.18 kernel
# fails to come up, mu300-post never runs to re-arm slot b, the tries run out, and LK drops back to
# the Android on slot a by itself.
#
# The device-side half lives in mu300-slot-b.d/device.sh and is fed over ssh stdin, so the quoting
# never nests.
#
# usage:
#   mu300-slot-b.sh status                 read-only: what is running, live sha256, /lib/modules
#   mu300-slot-b.sh backup DIR             dump live boot_b + vendor_boot_b into DIR on the host
#   mu300-slot-b.sh stage-modules          push upstream/out/modules -> /lib/modules/<release>/ on device
#   mu300-slot-b.sh flash                  write boot_b + vendor_boot_b + misc, verify, reboot
#
# MU300_HOST overrides the default management address (192.168.77.1, the USB side).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
HOST=${MU300_HOST:-192.168.77.1}
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o LogLevel=ERROR root@$HOST"
DEV="$HERE/mu300-slot-b.d/device.sh"

BOOTIMG=$ROOT/work/boot-618-slotb.img
VENDORIMG=$ROOT/work/vendor_boot_b-7552n.img
BCBLOB=$ROOT/work/boot-618-slotb.misc-slot-b-trial.bin
MODTAR=$ROOT/work/618-modules.tar.gz

dev() { $SSH "sh -s -- $*" < "$DEV"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
die() { echo "$*" >&2; exit 1; }

# Verify a local image against the .json the build wrote before anything is pushed: a stale or
# truncated file would otherwise surface only in the readback, with the flash already half done.
check_local() {
    img=$1; base=${img%.img}
    [ -f "$img" ] || die "missing image: $img"
    [ -f "$base.json" ] || die "missing $base.json (holds the expected sha256)"
    want=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$base.json")
    got=$(sha "$img")
    [ "$want" = "$got" ] || die "local $img sha256 mismatch: $got != $want"
    echo "local $(basename "$img") ok ($got)"
}

case "${1:-}" in

status)
    dev status
    ;;

backup)
    DIR=${2:-} ; [ -n "$DIR" ] || die "usage: $0 backup DIR"
    mkdir -p "$DIR"
    # Dump into the device's tmpfs, pull with a plain `cat` over ssh, then remove.  No sftp-server on
    # this rootfs, so scp without -O would fail.
    for p in boot_b vendor_boot_b; do
        echo "== $p =="
        want=$(dev backup "$p")
        devcat=$($SSH "cat /tmp/$p.live.img" | tee "$DIR/$p.live.img" | sha256sum | cut -d' ' -f1)
        $SSH "rm -f /tmp/$p.live.img"
        printf 'device %-14s %s\nhost   %-14s %s\n' "$p" "$want" "$p" "$devcat"
        [ "$want" = "$devcat" ] || die "$p: pulled image does not match what the device wrote"
    done
    echo "backups in $DIR"
    ;;

stage-modules)
    [ -f "$MODTAR" ] || die "missing $MODTAR (tar -C upstream/out/modules -czf $MODTAR .)"
    rel=$(grep -aoh 'vermagic=[0-9][0-9.]*' "$ROOT"/upstream/out/modules/*.ko | head -1 | cut -d= -f2)
    [ -n "$rel" ] || die "no vermagic in upstream/out/modules -- rebuild them first"
    # The release is read out of the modules themselves, never hardcoded: build-rootfs.sh carries a
    # scar from exactly that (a 6.18.52 directory holding 6.18.56 modules), and a mismatched
    # directory makes every module load fail one by one at boot.
    n=$(tar -tzf "$MODTAR" | grep -c '\.ko$')
    echo "release $rel, $n modules"
    $SSH "mkdir -p /lib/modules/$rel && tar -xzf - -C /lib/modules/$rel && ls /lib/modules/$rel/*.ko | wc -l" < "$MODTAR"
    $SSH "df -h / | awk 'NR==2{print \"rootfs free: \"\$4}'"
    ;;

flash)
    check_local "$BOOTIMG"
    check_local "$VENDORIMG"
    [ -f "$BCBLOB" ] || die "missing $BCBLOB"
    # Refuse to touch anything until both live partitions are on the host.  The device is running the
    # kernel we are about to overwrite; boot_a is the only way back, so slot b must exist elsewhere.
    for p in boot_b vendor_boot_b; do
        [ -f "$ROOT/work/dumps/$p.live.img" ] ||
            die "no backup of live $p -- run: $0 backup $ROOT/work/dumps"
    done
    echo "writing boot_b + vendor_boot_b + misc[2048:32].  boot_a and vendor_boot_a are never opened."
    $SSH "cat > /tmp/mu300-boot.img" < "$BOOTIMG"
    $SSH "cat > /tmp/mu300-vb.img"   < "$VENDORIMG"
    $SSH "cat > /tmp/mu300-bc.bin"   < "$BCBLOB"
    echo "pushed $(stat -c %s "$BOOTIMG") + $(stat -c %s "$VENDORIMG") bytes"
    dev flash "$(sha "$BOOTIMG")" "$(sha "$VENDORIMG")" "$(sha "$BCBLOB")"
    ;;

*)
    sed -n '/^# usage:/,/^# MU300_HOST/p' "$0" | sed 's/^# \?//'
    exit 1
    ;;
esac
