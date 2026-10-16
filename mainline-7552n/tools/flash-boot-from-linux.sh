#!/bin/bash
# Flash a Linux boot image to slot b (boot_b) from the *running OpenWrt* on the 7552N.
#
# Why this exists: boot/flash-trial.sh is the Android-side path and is unusable here --
#   * while Linux runs there is no adb (the only USB link is our NCM management port), and
#   * it refuses unless the device is on slot a and misc holds the slot-a block; ours is on
#     slot b, whose live misc *is* the slot-b block mu300-next-boot --rearm rewrites anyway.
#
# This writes ONLY boot_b (/dev/sda40).  misc is deliberately left alone: the running system
# re-arms slot b on every boot via /opt/mu300/bin/mu300-next-boot --rearm, and its BC_B is
# byte-identical to the block our image embeds (checked below), so re-writing it would only
# risk a torn misc for no gain.  boot_a / vendor_boot_a are never touched.
#
# usage: flash-boot-from-linux.sh work/boot-618-slotb.img [--no-reboot] [--force]
set -euo pipefail

DEV=${DEV:-root@192.168.77.1}
SSH=(ssh -o ConnectTimeout=10 "$DEV")
IMG=$1
shift || true
DO_REBOOT=1
FORCE=0
for o in "$@"; do
    case "$o" in
        --no-reboot) DO_REBOOT=0 ;;
        --force)     FORCE=1 ;;
        *) echo "unknown option $o" >&2; exit 2 ;;
    esac
done

BASE=${IMG%.img}
JSON=$BASE.json
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
[ -f "$JSON" ] || { echo "no $JSON next to the image; rebuild with build.sh image" >&2; exit 1; }

jget() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$JSON" "$1"; }
EXP=$(jget sha256)
BC_B=$(jget misc_slot_b_trial_hex)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PULLDIR=$HERE/../../work/dumps

[ "$(sha256sum "$IMG" | cut -d' ' -f1)" = "$EXP" ] || { echo "local image hash mismatch" >&2; exit 1; }
echo "local image  $(stat -c%s "$IMG") bytes  sha256 $EXP"

# --- device-side facts ---------------------------------------------------------------------
dev_sh() { "${SSH[@]}" "$1" 2>/dev/null; }

suffix=$(dev_sh 'cat /etc/mu300/default-boot 2>/dev/null || echo android')
[ "$suffix" = linux ] || { echo "device default-boot is '$suffix', not linux -- refusing" >&2; exit 1; }

PART=$(dev_sh 'readlink -f /dev/block/by-name/boot_b')
[ -n "$PART" ] || { echo "cannot resolve boot_b on the device" >&2; exit 1; }
echo "device boot_b -> $PART"

live_bc=$(dev_sh 'export PATH=$PATH:/opt/mu300/busybox-bin; dd if=/dev/block/by-name/misc bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1 -v | tr -d " \n"')
if [ "$live_bc" = "$BC_B" ]; then
    echo "misc already holds this image's slot-b block; leaving misc untouched"
elif [ "$FORCE" = 1 ]; then
    echo "WARNING: misc is $live_bc, image expects $BC_B -- --force given, still leaving misc alone" >&2
else
    echo "misc slot-b block is $live_bc, image expects $BC_B." >&2
    echo "Refusing (the running system re-arms on boot anyway); pass --force to override." >&2
    exit 1
fi

state=$(dev_sh 'cat /sys/class/block/'"$(basename "$PART")"'/size')
[ -n "$state" ] || { echo "device did not answer (is OpenWrt up?)" >&2; exit 1; }
devsz=$((state * 512))
imgsz=$(stat -c%s "$IMG")
[ "$imgsz" -le "$devsz" ] || { echo "image $imgsz > boot_b $devsz" >&2; exit 1; }

# --- back up what is there now -------------------------------------------------------------
mkdir -p "$PULLDIR"
prev=$PULLDIR/boot_b-prev.img
echo "saving current boot_b to $prev"
"${SSH[@]}" "dd if=$PART bs=1M 2>/dev/null" > "$prev"
psz=$(stat -c%s "$prev")
[ "$psz" -eq "$devsz" ] || { echo "backup short: got $psz, expected $devsz -- aborting" >&2; rm -f "$prev"; exit 1; }
echo "  saved $(sha256sum "$prev" | cut -d' ' -f1)"

# --- push + flash --------------------------------------------------------------------------
echo "pushing image to the device"
"${SSH[@]}" 'cat > /tmp/boot-trial.img' < "$IMG"
got=$(dev_sh "sha256sum /tmp/boot-trial.img | cut -d' ' -f1")
[ "$got" = "$EXP" ] || { echo "pushed image hash mismatch: $got" >&2; exit 1; }
echo "  push verified"

echo "writing $PART"
dev_sh "dd if=/tmp/boot-trial.img of=$PART bs=4M conv=fsync 2>/dev/null; sync" || true
back=$(dev_sh "sha256sum $PART | cut -d' ' -f1")
[ "$back" = "$EXP" ] || { echo "read-back mismatch: $back" >&2; exit 1; }
dev_sh 'rm -f /tmp/boot-trial.img'
echo "  boot_b verified (slot a untouched)"

if [ "$DO_REBOOT" = 1 ]; then
    echo "rebooting"
    "${SSH[@]}" reboot || true
fi
