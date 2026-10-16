#!/system/bin/sh
# Attach the changxing60root ext4 (free eMMC region) on Android via a bounded loop device and mount it.
# usage: android-mount-changxing60root.sh <mountpoint>   |   android-mount-changxing60root.sh -u <mountpoint>
set -e
# region of the Linux area (7552N B5: fixed geometry after the shrunk userdata, UFS /dev/block/sda;
# install.sh passes the values it computed via CHANGXING60_OFF/CHANGXING60_SIZE)
OFF=${CHANGXING60_OFF:-77858865152}
SIZE=${CHANGXING60_SIZE:-50096766976}
# Writes to a loop device are issued by the loop kworker, which runs as u:r:kernel:s0; writing the
# backing node (/dev/block/sda, ufs_device) is denied by the AOSP policy. The filesystem therefore
# takes no writes at all -- and dd still reports success, because the failure surfaces later as an
# avc denial plus "loop: Write error" in dmesg. Reading is unaffected, so `mount -o ro`, tune2fs -l
# and e2fsck's read passes all look healthy. Anything that writes (a read-write mount's journal,
# mke2fs, resize2fs, untar) silently does nothing until SELinux is permissive.
# The window is exactly "while this filesystem is mounted read-write": -u closes it again.
SELINUX_PREV=/data/local/tmp/.changxing60-selinux.prev
if [ "$1" = -u ]; then
    # Teardown must not be able to fail its caller.  Android attaches these loops with autoclear, so by
    # the time we get here the kernel has usually detached the loop already and `losetup -d` answers
    # ENXIO ("No such device or address").  Under `set -e` that used to end this script non-zero, and
    # through it the installer's cleanup -- which is how the 2026-10-16 08:06 run, which had failed for
    # an unrelated reason, left the box running Android with SELinux still Permissive.  Every step here
    # is therefore tolerated, and the restore always reports.
    L=$(grep " $2 " /proc/mounts 2>/dev/null | cut -d' ' -f1 || true)
    umount "$2" 2>/dev/null || true
    if [ -n "$L" ]; then losetup -d "$L" 2>/dev/null || true; fi
    if [ -f "$SELINUX_PREV" ]; then
        setenforce "$(cat "$SELINUX_PREV")" 2>/dev/null || true
        rm -f "$SELINUX_PREV"
        echo "selinux back to $(getenforce 2>/dev/null)"
    fi
    echo UNMOUNTED; exit 0
fi
MP=$1
# never attach the same ext4 twice (two loops mounting one filesystem corrupts it)
for o in /sys/block/loop*/loop/offset; do
    [ "$(cat "$o" 2>/dev/null)" = "$OFF" ] && { echo "ALREADY-ATTACHED ${o%/loop/offset}"; exit 1; }
done
f=$(losetup -f 2>&1 | grep -o '/dev/block/loop[0-9]*' | head -1)
n=${f##*loop}
[ -n "$n" ] || { echo NO-LOOP-INDEX; exit 1; }
[ -e /sys/block/loop$n/dev ] || { echo NO-SYSFS-loop$n; exit 1; }
L=/dev/block/loop$n
# ueventd may create the node concurrently; only fail if it still does not exist
[ -b "$L" ] || mknod "$L" b $(cut -d: -f1 /sys/block/loop$n/dev) $(cut -d: -f2 /sys/block/loop$n/dev) 2>/dev/null || [ -b "$L" ]
[ ! -e /sys/block/loop$n/loop/backing_file ] || { echo LOOP-BUSY-$L; exit 1; }
losetup -o $OFF -S $SIZE "$L" /dev/block/sda
# the kernel prints the canonical path of the opened backing node; accept both spellings
bf=$(cat /sys/block/loop$n/loop/backing_file 2>/dev/null)
case "$bf" in /dev/block/sda|/dev/sda) ;; *) echo "LOOP-BACKING-MISMATCH $bf"; losetup -d "$L"; exit 1 ;; esac
[ "$(cat /sys/block/loop$n/loop/offset)" = "$OFF" ] && [ "$(blockdev --getsize64 $L)" = "$SIZE" ] || { echo LOOP-MISMATCH; losetup -d "$L"; exit 1; }
# ext4 superblock at 1024: s_magic @+56 (0xEF53), s_volume_name @+120 (16 bytes)
magic=$(dd if="$L" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$magic" = 53ef ] || { echo "NO-EXT4 magic=$magic"; losetup -d "$L"; exit 1; }
label=$(dd if="$L" bs=1 skip=1144 count=16 2>/dev/null | tr -d '\000')
[ "$label" = changxing60root ] || { echo "NOT-CHANGXING60ROOT label=$label"; losetup -d "$L"; exit 1; }
mkdir -p "$MP"
# The window has to open BEFORE mount(2), not after it.  The rootfs was last written by a Linux boot
# that never unmounted, so mounting it read-write replays the journal -- and that replay is a write
# issued by the loop kworker as u:r:kernel:s0, which the policy denies on ufs_device.  With SELinux
# still enforcing, mount fails outright and nothing is attached:
#     avc: denied { write } for comm="loop30" path="/dev/block/sda" ... tclass=blk_file permissive=0
#     EXT4-fs (loop30): error loading journal
#     mount: '/dev/block/loop30'->'/mnt/changxing60': I/O error
# which is exactly how the first real run (2026-10-16 08:01) died, having set permissive one line too
# late.  -u closes the window again.
if [ "$(getenforce 2>/dev/null)" != Permissive ]; then
    getenforce > "$SELINUX_PREV"
    if setenforce 0 2>/dev/null; then
        echo "NOTE: SELinux was $(cat "$SELINUX_PREV"); it is Permissive across the mount and everything written through it (loop writes run as the kernel loop kworker, which the policy denies on this device node). -u restores it."
    else
        rm -f "$SELINUX_PREV"
        echo "WARNING: cannot set SELinux permissive; the mount itself will fail with EIO while the journal is dirty (reads are fine)"
    fi
fi
if ! mount -t ext4 -o noatime "$L" "$MP"; then
    echo "MOUNT-FAILED $L -> $MP"
    losetup -d "$L" 2>/dev/null
    if [ -f "$SELINUX_PREV" ]; then
        setenforce "$(cat "$SELINUX_PREV")" 2>/dev/null && rm -f "$SELINUX_PREV"
        echo "selinux back to $(getenforce 2>/dev/null)"
    fi
    exit 1
fi
echo "MOUNTED $L on $MP"
