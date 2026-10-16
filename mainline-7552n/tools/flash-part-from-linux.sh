#!/bin/bash
# Write one image to one named partition on the 7552N *from the running OpenWrt*, over SSH.
#
# This is the Linux-side counterpart of boot/flash-trial.sh (which needs adb + rooted Android).  While
# Linux runs there is no adb -- the only USB link is our NCM management port -- so images are pushed over
# SSH instead.  Every step is checked: local hash, push hash, write, read-back hash.  A partition is only
# ever written after all earlier checks passed.
#
# usage: flash-part-from-linux.sh <partition> <image> [--no-reboot] [--no-backup]
#   partition  by-name entry on the device, e.g. boot_b, vendor_boot_b
#
# Never point this at boot_a / vendor_boot_a: slot a is the Android fallback.
set -euo pipefail

DEV=${DEV:-root@192.168.77.1}
SSH=(ssh -o ConnectTimeout=10 "$DEV")
PARTNAME=$1
IMG=$2
shift 2
DO_REBOOT=1
DO_BACKUP=1
for o in "$@"; do
    case "$o" in
        --no-reboot) DO_REBOOT=0 ;;
        --no-backup) DO_BACKUP=0 ;;
        *) echo "unknown option $o" >&2; exit 2 ;;
    esac
done

case "$PARTNAME" in
    boot_a|vendor_boot_a) echo "refusing to write $PARTNAME (slot a is the Android fallback)" >&2; exit 1 ;;
esac
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PULLDIR=$HERE/../../work/dumps
mkdir -p "$PULLDIR"

dev_sh() { "${SSH[@]}" "$1" 2>/dev/null; }

PART=$(dev_sh "readlink -f /dev/block/by-name/$PARTNAME")
[ -n "$PART" ] || { echo "cannot resolve /dev/block/by-name/$PARTNAME on the device" >&2; exit 1; }
sectors=$(dev_sh "cat /sys/class/block/$(basename "$PART")/size")
[ -n "$sectors" ] || { echo "device did not answer (is OpenWrt up?)" >&2; exit 1; }
devsz=$((sectors * 512))
imgsz=$(stat -c%s "$IMG")
echo "$PARTNAME -> $PART ($devsz bytes); image $imgsz bytes sha256 $(sha256sum "$IMG" | cut -d' ' -f1)"
[ "$imgsz" -le "$devsz" ] || { echo "image is larger than the partition" >&2; exit 1; }

if [ "$DO_BACKUP" = 1 ]; then
    prev=$PULLDIR/$PARTNAME-prev.img
    echo "saving current $PARTNAME to $prev"
    "${SSH[@]}" "dd if=$PART bs=1M 2>/dev/null" > "$prev"
    [ "$(stat -c%s "$prev")" -eq "$devsz" ] || { echo "backup short; aborting" >&2; rm -f "$prev"; exit 1; }
    echo "  saved $(sha256sum "$prev" | cut -d' ' -f1)"
fi

echo "pushing"
"${SSH[@]}" 'cat > /tmp/part-flash.img' < "$IMG"
[ "$(dev_sh "sha256sum /tmp/part-flash.img | cut -d' ' -f1")" = "$(sha256sum "$IMG" | cut -d' ' -f1)" ] ||
    { echo "pushed image hash mismatch" >&2; exit 1; }

echo "writing $PART"
dev_sh "dd if=/tmp/part-flash.img of=$PART bs=4M conv=fsync 2>/dev/null; sync" || true
[ "$(dev_sh "sha256sum $PART | cut -d' ' -f1")" = "$(sha256sum "$IMG" | cut -d' ' -f1)" ] ||
    { echo "read-back mismatch -- DO NOT reboot" >&2; exit 1; }
dev_sh 'rm -f /tmp/part-flash.img'
echo "  $PARTNAME verified"

if [ "$DO_REBOOT" = 1 ]; then
    echo "rebooting"
    "${SSH[@]}" reboot || true
fi
