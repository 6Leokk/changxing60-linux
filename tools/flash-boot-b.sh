#!/bin/sh
# Replace boot_b on a device that is already running the kernel in it, and nothing else.
#
#   tools/flash-boot-b.sh status          read-only: what boot_b holds, how misc is armed
#   tools/flash-boot-b.sh --image IMG     push IMG, write boot_b, verify the readback
#   tools/flash-boot-b.sh --image IMG --reboot    ... and reboot into it
#
# The device half is tools/flash-boot-b.d/device.sh.
#
# When this is the right tool: the change lives in the ramdisk (boot/init, or anything else inside
# it), the kernel is unchanged, and the device is up in OpenWrt on the slot b it is replacing. That
# is the case after the rename -- see docs/changxing60/rename.md -- where the only thing wrong with
# the boot image was that its /init still created /run/mu300, mounted /mnt/mu300-disk and read
# /newroot/etc/mu300/default-boot.
#
# When it is not: a kernel change also needs vendor_boot_b, and that is changxing60-slot-b.sh, which
# writes boot_b + vendor_boot_b + misc together. This tool deliberately does not touch misc: slot b
# is re-armed on every successful boot by changxing60-post, so the state the running system left is
# already the state the next boot needs.
#
# boot_a and vendor_boot_a are never opened by either half.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
HOST=${CHANGXING60_HOST:-192.168.77.1}
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o LogLevel=ERROR root@$HOST"
DEV="$HERE/flash-boot-b.d/device.sh"

IMG=$ROOT/work/boot-linux-slotb.img
REBOOT=0
ACTION=
while [ $# -gt 0 ]; do
    case "$1" in
    status)  ACTION=status ;;
    --image) IMG=$2; shift ;;
    --reboot) REBOOT=1 ;;
    *) echo "usage: flash-boot-b.sh status | --image IMG [--reboot]" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$ACTION" ] || ACTION=flash

dev() { $SSH "sh -s -- $*" < "$DEV"; }
die() { echo "$*" >&2; exit 1; }

if [ "$ACTION" = status ]; then
    dev status
    exit 0
fi

# Verify against the .json the build wrote before pushing anything: a stale or truncated file would
# otherwise surface only in the readback, with the flash already half done.
base=${IMG%.img}
[ -f "$IMG" ] || die "missing image: $IMG"
[ -f "$base.json" ] || die "missing $base.json (holds the expected sha256)"
want=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$base.json")
got=$(sha256sum "$IMG" | cut -d' ' -f1)
[ "$want" = "$got" ] || die "local $IMG sha256 mismatch: $got != $want"
echo "local $(basename "$IMG") ok ($got)"
echo "size: $(stat -c %s "$IMG") bytes"

echo
echo "== boot_b as it is now =="
dev status

echo
echo "== pushing $(basename "$IMG") ($(( $(stat -c %s "$IMG") / 1048576 )) MiB) to /root =="
# /root, not /tmp: /tmp is a tmpfs and this image is 64 MiB of a partition that also has to stay
# writable while the copy is in flight. The disk area has room.
$SSH "cat > /root/changxing60-boot-b.new.img" < "$IMG"
$SSH "sha256sum /root/changxing60-boot-b.new.img | cut -d' ' -f1" | grep -qx "$got" \
    || die "the copy that arrived on the device does not match the local image"

echo
echo "== writing boot_b =="
dev flash "$want"

echo
echo "== boot_b as it is now =="
dev status

if [ "$REBOOT" = 1 ]; then
    echo
    echo "== rebooting =="
    # A plain reboot goes back to OpenWrt: slot b is armed and this is not one of the two-within-70s
    # reboots that would run its tries down to Android (docs/changxing60/reboot.md).
    $SSH 'sync; reboot' || true
else
    echo
    echo "boot_b is written but the device is still running the old image. Reboot when ready:"
    echo "  ssh root@$HOST reboot"
fi
