#!/bin/sh
# Pull the Android vendor runtime needed by modem_control from a rooted device (adb + su) and build
# the chroot subset used by the initramfs (/android) and the rootfs (/opt/changxing60/android).
# These files are proprietary (ZTE/Unisoc/Google) and are NOT part of this repository.
set -eu
OUT=${1:-android-subset}
RCS=${2:-vendor-init-rcs}   # 7552n-port: side output dir for /vendor/etc/init/*.rc (gen-ueventd-perms.py input)
TMP=$(mktemp -d)
# 7552n-port (A5): WSL interop corrupts binary stdout — never pipe `adb exec-out`.
# tar to a device file, adb pull (verified binary-safe), extract host-side.
DEV_TAR=/data/local/tmp/android-subset.tar
adb shell "su -c 'rm -f $DEV_TAR; tar -chf $DEV_TAR /apex/com.android.runtime /system/lib64 /vendor/bin/modem_control /vendor/bin/cp_diskserver /vendor/bin/refnotify /vendor/lib64/lib_crypto.so /vendor/bin/sh /vendor/bin/toybox_vendor /vendor/bin/getprop /vendor/lib64/libkernelbootcp.trusty.so /vendor/etc /dev/__properties__ 2>/dev/null; chmod 0644 $DEV_TAR'"
adb pull "$DEV_TAR" "$TMP/subset.tar" >/dev/null
adb shell "su -c 'rm -f $DEV_TAR'"
adb shell "su -c 'for k in ro.serialno ro.boot.serialno ro.boot.emmcid persist.adb.wifi.guid; do printf \"%s=%s\\n\" \"\$k\" \"\$(getprop \$k)\"; done'" </dev/null | tr -d '\r' > "$TMP/props.txt"
tar -xf "$TMP/subset.tar" -C "$TMP"
rm -rf "$OUT" && mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
mkdir -p "$RCS" && RCS=$(cd "$RCS" && pwd)   # absolutize before cd $TMP
cd "$TMP"
tar -cf - apex/com.android.runtime/bin/linker64 apex/com.android.runtime/lib64/bionic \
  system/lib64/libcutils.so system/lib64/libexpat.so system/lib64/liblog.so system/lib64/libhardware_legacy.so \
  system/lib64/libc++.so system/lib64/libbase.so system/lib64/libbinder.so system/lib64/libbinder_ndk.so \
  system/lib64/libhidlbase.so system/lib64/libutils.so system/lib64/android.system.suspend-V1-ndk.so \
  system/lib64/libtrusty.so system/lib64/libandroid_runtime_lazy.so system/lib64/libvndksupport.so \
  system/lib64/libz.so system/lib64/libcrypto.so system/lib64/libselinux.so system/lib64/libpcre2.so \
  system/lib64/libpackagelistparser.so system/lib64/libprocessgroup.so system/lib64/libcgrouprc.so \
  vendor/lib64/libkernelbootcp.trusty.so vendor/lib64/lib_crypto.so vendor/bin/modem_control vendor/bin/cp_diskserver vendor/bin/refnotify vendor/bin/sh vendor/bin/toybox_vendor vendor/bin/getprop \
  vendor/etc/modem_cp_info.xml vendor/etc/modem_sp_info.xml vendor/etc/modem_ch_info.xml vendor/etc/cp_dump_info.xml \
  vendor/etc/ueventd.rc dev/__properties__ | tar -xf - -C "$OUT"
cd /
# Neutralize the pulled /dev/__properties__ regions. The regions are bionic's property-area mmap
# files, taken whole so the vendor chroot can resolve SELinux property contexts -- and a whole
# region includes this device's *values* for ro.serialno, ro.boot.serialno, ro.boot.emmcid and the
# adbd wifi guid. Those must not ride into a rootfs image that gets shared ("flash it on your own
# device" means your serial, not the builder's). The replacement is same-length (every byte of the
# value becomes '0'), which is what the fixed-slot prop_info layout tolerates; the keys stay, so
# anything that enumerates properties still sees the same shape. Values come from THIS device's
# getprop, so it works for every device, not just the one the port was developed on.
python3 - "$OUT/dev/__properties__" "$TMP/props.txt" <<'PY'
import glob, os, re, sys
root, propfile = sys.argv[1], sys.argv[2]
vals = []
for line in open(propfile, encoding='utf-8', errors='replace'):
    _, _, v = line.partition('=')
    v = v.strip()
    if len(v) >= 4:
        vals.append(v)
n = 0
for f in glob.glob(os.path.join(root, '**', '*'), recursive=True):
    if not os.path.isfile(f):
        continue
    data = open(f, 'rb').read()
    for v in vals:
        b = v.encode('ascii', 'ignore')
        if b and b in data:
            data = data.replace(b, b'0' * len(b))
            n += 1
    open(f, 'wb').write(data)
print('neutralize-properties: %d value(s) zeroed across %d region files' % (n, sum(1 for x in glob.glob(os.path.join(root, '*')) if os.path.isfile(x))))
PY
rm -f "$TMP/props.txt"
mkdir -p "$OUT/system/bin" "$OUT/linkerconfig"
ln -sfn /apex/com.android.runtime/bin/linker64 "$OUT/system/bin/linker64"
: > "$OUT/linkerconfig/ld.config.txt"
cp "$TMP"/vendor/etc/init/*.rc "$RCS"/ 2>/dev/null || true   # 7552n-port: rc bundle for gen-ueventd-perms.py
rm -rf "$TMP"
du -sh "$OUT" "$RCS"
