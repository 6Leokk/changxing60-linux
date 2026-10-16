#!/system/bin/sh
# Read-only evidence grab, run from Android before touching vendor_boot_b.
#
#   1. vendor_boot_b.backup.img  -- the whole partition (the DTB we are about to fix, and the way back)
#   2. vb-dtb.bin                -- just the DT blob region, for a quick local `--show`
#   3. persist-boot_b.bin        -- the initramfs' persist log region in boot_b (offset 56 MiB), i.e.
#                                   what the *last* OpenWrt boot wrote before switch_root: the
#                                   `stage=usb-*` lines are the ground truth for the USB failure.
#   4. state.txt                 -- slot, cmdline, partname of the partitions involved
set -eu
T=/data/local/tmp
DTB_OFF=${DTB_OFF:-23560256}     # vendor_boot_b: dtb_table(32) + 1 entry(32) into the dtb section
DTB_LEN=${DTB_LEN:-170136}
PERSIST_OFF=${PERSIST_OFF:-58720256}   # 56 MiB into boot_b, 4 MiB window (dd bs=4096 skip=14336)
PERSIST_LEN=${PERSIST_LEN:-4194304}

resolve() { p=$(readlink -f "$1" 2>/dev/null) || p="$1"; [ -e "$p" ] && echo "$p"; }
partname() { n=$(basename "$1"); grep -m1 '^PARTNAME=' "/sys/class/block/$n/uevent" 2>/dev/null | cut -d= -f2; }

VB=$(resolve /dev/block/by-name/vendor_boot_b); BB=$(resolve /dev/block/by-name/boot_b)
echo "[collect] vendor_boot_b = $VB PARTNAME=$(partname "$VB")"
echo "[collect] boot_b       = $BB PARTNAME=$(partname "$BB")"

{
    echo "slot_suffix=$(getprop ro.boot.slot_suffix)"
    echo "bootloader=$(getprop ro.boot.bootloader)"
    echo "cmdline=$(cat /proc/cmdline)"
    echo "vendor_boot_b=$(sha256sum "$VB" | cut -d' ' -f1)"
    echo "boot_b=$(sha256sum "$BB" | cut -d' ' -f1)"
    echo "misc@2048=$(dd if=/dev/block/by-name/misc bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1 -v | tr -d ' \n')"
} > $T/state.txt
cat $T/state.txt

echo "[collect] vendor_boot_b backup ($(blockdev --getsize64 "$VB" 2>/dev/null || echo '?') bytes)"
dd if="$VB" of=$T/vendor_boot_b.backup.img bs=4M 2>&1 | tail -1
sync
sha256sum $T/vendor_boot_b.backup.img

echo "[collect] DT blob region"
dd if="$VB" of=$T/vb-dtb.bin bs=1 skip=$DTB_OFF count=$DTB_LEN 2>&1 | tail -1
od -An -tx1 -N4 $T/vb-dtb.bin    # must read d0 0d fe ed

echo "[collect] boot_b persist region (last OpenWrt boot's pre-switch_root log)"
dd if="$BB" of=$T/persist-boot_b.bin bs=4096 skip=14336 count=1024 2>&1 | tail -1
strings $T/persist-boot_b.bin | tail -40
echo CHANGXING60-COLLECT-OK
