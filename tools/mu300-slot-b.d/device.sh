#!/bin/sh
# Device-side half of tools/mu300-slot-b.sh.  Never run this directly on a host -- it is fed to the
# 7552N over ssh stdin (`ssh root@... sh -s -- <cmd>`), so the quoting stays one level deep and the
# code below is the only thing the device's busybox sh has to parse.
#
# Partitions are found by PARTNAME in /sys/class/block/*/uevent, not /dev/block/by-name: this rootfs
# is a plain OpenWrt and the UFS comes up as sdaN with no by-name symlinks (same reason boot/init
# scans for them).  boot_a / vendor_boot_a are not in any list here and must never be added.
set -eu

part() {
    for u in /sys/class/block/*/uevent; do
        grep -qx "PARTNAME=$1" "$u" 2>/dev/null || continue
        echo "/dev/$(basename "$(dirname "$u")")"
        return 0
    done
    return 1
}

psize() {  # psize /dev/sdaN -> bytes
    n=$(basename "$1")
    s=$(cat "/sys/class/block/$n/size" 2>/dev/null) || return 1
    echo $((s * 512))
}

hexdump32() { dd if="$1" bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1 -v | tr -d ' \n'; }

case "${1:-}" in

status)
    echo "uname      : $(uname -r)"
    echo "uptime     : $(cut -d. -f1 /proc/uptime)s"
    echo "sha256sum  : $(command -v sha256sum || echo MISSING)"
    for p in boot_a boot_b vendor_boot_a vendor_boot_b misc; do
        if d=$(part "$p"); then
            echo "$(printf '%-13s' "$p"): $d  $(psize "$d" 2>/dev/null || echo '?') B"
        else
            echo "$(printf '%-13s' "$p"): NOT-FOUND"
        fi
    done
    echo "lib/modules: $(ls /lib/modules 2>/dev/null | tr '\n' ' ')"
    echo "rootfs     : $(df -h / | awk 'NR==2{print $4" free of "$2}')"
    echo "--- live sha256 ---"
    for p in boot_b vendor_boot_b; do
        d=$(part "$p") || continue
        echo "$(printf '%-13s' "$p"): $(sha256sum "$d" 2>/dev/null | cut -d' ' -f1)"
    done
    echo "--- misc bootloader_control (32 B @ 2048) ---"
    if d=$(part misc); then hexdump32 "$d"; echo; fi
    ;;

backup)  # backup PART -> writes /tmp/PART.live.img and prints its sha256
    p=$2
    d=$(part "$p") || { echo "no partition named $p" >&2; exit 1; }
    echo "dumping $p from $d ($(psize "$d" 2>/dev/null || echo '?') B)" >&2
    dd if="$d" of="/tmp/$p.live.img" bs=1M 2>&1 | tail -1 >&2
    sha256sum "/tmp/$p.live.img"
    ;;

flash)
    want_boot=$2
    want_vb=$3
    bc_sum=$4
    db=$(part boot_b) || { echo "no boot_b" >&2; exit 1; }
    dv=$(part vendor_boot_b) || { echo "no vendor_boot_b" >&2; exit 1; }
    dm=$(part misc) || { echo "no misc" >&2; exit 1; }
    echo "targets: boot_b=$db vendor_boot_b=$dv misc=$dm"
    echo "live misc bc before: $(hexdump32 "$dm")"

    # The images arrived over ssh as raw bytes; check them again here rather than trusting the push.
    [ "$(sha256sum /tmp/mu300-boot.img | cut -d' ' -f1)" = "$want_boot" ] ||
        { echo "PUSHED boot image hash mismatch -- nothing written" >&2; exit 1; }
    [ "$(sha256sum /tmp/mu300-vb.img | cut -d' ' -f1)" = "$want_vb" ] ||
        { echo "PUSHED vendor_boot hash mismatch -- nothing written" >&2; exit 1; }
    [ "$(sha256sum /tmp/mu300-bc.bin | cut -d' ' -f1)" = "$bc_sum" ] ||
        { echo "PUSHED misc blob hash mismatch -- nothing written" >&2; exit 1; }

    dd if=/tmp/mu300-boot.img of="$db" bs=4M 2>&1 | tail -1
    sync
    got=$(sha256sum "$db" | cut -d' ' -f1)
    [ "$got" = "$want_boot" ] ||
        { echo "boot_b verify FAILED: $got -- slot a untouched, safe to reboot" >&2; exit 1; }
    echo "boot_b written and verified"

    dd if=/tmp/mu300-vb.img of="$dv" bs=4M 2>&1 | tail -1
    sync
    got=$(sha256sum "$dv" | cut -d' ' -f1)
    [ "$got" = "$want_vb" ] ||
        { echo "vendor_boot_b verify FAILED: $got -- slot a untouched, safe to reboot" >&2; exit 1; }
    echo "vendor_boot_b written and verified"

    dd if=/tmp/mu300-bc.bin of="$dm" bs=1 seek=2048 conv=notrunc 2>/dev/null
    sync
    new=$(hexdump32 "$dm")
    [ "$new" = "$bc_sum" ] || { echo "misc verify FAILED: $new != $bc_sum" >&2; exit 1; }
    echo "misc armed: $new"

    rm -f /tmp/mu300-boot.img /tmp/mu300-vb.img /tmp/mu300-bc.bin
    sync
    echo "rebooting into slot b (6.18 trial)"
    reboot
    ;;

*)
    echo "usage: device.sh status|backup PART|flash BOOTSHA VBSHA BCSHA" >&2
    exit 1
    ;;
esac
