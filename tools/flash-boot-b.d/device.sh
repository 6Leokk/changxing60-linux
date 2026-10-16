#!/bin/sh
# Device-side half of tools/flash-boot-b.sh. Never run this directly on a host -- it is fed to the
# 7552N over ssh stdin (`ssh root@... sh -s -- <cmd>`), so the quoting stays one level deep.
#
# It replaces boot_b and nothing else. That is the whole point of it existing next to
# changxing60-slot-b.d/device.sh: that one writes boot_b, vendor_boot_b and misc together because it
# installs a different kernel, and a kernel change is the only thing that needs the other two. Here
# the kernel is the one already running, only the ramdisk's /init differs, so vendor_boot_b stays as
# it is and misc is left armed exactly as the running system left it.
#
# boot_a and vendor_boot_a are not in any list here and must never be added.
set -eu

# od is not in this rootfs's default PATH -- the busybox that has it is the one this port ships
# (the same export changxing60-next-boot does). Without it the misc line below comes out empty and
# looks like a partition with no bootloader_control rather than a missing tool.
PATH="$PATH:/opt/changxing60/busybox-bin"
export PATH

part() {
    for u in /sys/class/block/*/uevent; do
        grep -qx "PARTNAME=$1" "$u" 2>/dev/null || continue
        echo "/dev/$(basename "$(dirname "$u")")"
        return 0
    done
    return 1
}

hexdump32() { dd if="$1" bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1 -v | tr -d ' \n'; }

case "${1:-}" in

status)
    db=$(part boot_b) || { echo "no boot_b" >&2; exit 1; }
    dm=$(part misc) || { echo "no misc" >&2; exit 1; }
    echo "boot_b          : $db"
    echo "boot_b sha256   : $(sha256sum "$db" | cut -d' ' -f1)"
    echo "misc bootloader_control: $(hexdump32 "$dm")"
    echo "default-boot    : $(cat /etc/changxing60/default-boot 2>/dev/null || echo '(absent)')"
    echo "running kernel  : $(uname -r)"
    ;;

flash)  # flash WANT_SHA256
    want=$2
    db=$(part boot_b) || { echo "no boot_b" >&2; exit 1; }
    [ -f /root/changxing60-boot-b.new.img ] || { echo "the pushed image is not at /root/changxing60-boot-b.new.img" >&2; exit 1; }

    # Check what arrived over the wire again here rather than trusting the push.
    got=$(sha256sum /root/changxing60-boot-b.new.img | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "PUSHED image hash mismatch ($got) -- nothing written" >&2; exit 1; }

    # Keep the image that is about to be replaced. If the new one does not come up, this is the
    # rollback: dd it back over boot_b and reboot. Skipped when a copy is already there, so a
    # second run cannot overwrite the good copy with the suspect one.
    if [ ! -f /root/changxing60-boot-b.old.img ]; then
        echo "keeping the current boot_b as /root/changxing60-boot-b.old.img"
        dd if="$db" of=/root/changxing60-boot-b.old.img bs=1M 2>&1 | tail -1
    else
        echo "/root/changxing60-boot-b.old.img already exists; keeping it"
    fi

    echo "writing $db"
    dd if=/root/changxing60-boot-b.new.img of="$db" bs=4M 2>&1 | tail -1
    sync
    got=$(sha256sum "$db" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "boot_b verify FAILED: $got != $want -- do not reboot; boot_a is untouched" >&2; exit 1; }
    echo "boot_b written and verified"
    rm -f /root/changxing60-boot-b.new.img
    ;;

*)
    echo "usage: device.sh status|flash SHA256" >&2
    exit 1
    ;;
esac
