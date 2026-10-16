#!/bin/sh
# After a trial falls back to Android: collect LK log, pstore and the init log persisted in boot_b.
# 7552n-port (A5): no exec-out — WSL interop corrupts binary stdout. Stage on device + adb pull.
set -eu
OUT=${1:-logs-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
T=/data/local/tmp/changxing60-logs
adb shell "su -c 'getprop ro.boot.slot_suffix; ls -la /sys/fs/pstore'" | tr -d '\r' | tee "$OUT/state.txt"
adb shell "su -c 'rm -rf $T; mkdir -p $T/pstore; cp /sys/fs/pstore/* $T/pstore/ 2>/dev/null || true; \
  dd if=/dev/block/by-name/uboot_log of=$T/uboot_log.raw bs=1M 2>/dev/null; \
  dd if=/dev/block/by-name/boot_b of=$T/linux-persist.raw bs=4096 skip=14336 count=1024 2>/dev/null; \
  dd if=/dev/block/by-name/boot_b of=$T/linux-persist-legacy.raw bs=4096 skip=12288 count=2048 2>/dev/null; \
  chmod -R a+r $T; ls -la $T $T/pstore'" | tr -d '\r'
adb pull "$T/." "$OUT/" >/dev/null
[ -f "$OUT/uboot_log.raw" ] && strings -n 6 "$OUT/uboot_log.raw" > "$OUT/uboot_log.txt"
[ -f "$OUT/linux-persist.raw" ] && tr -d '\000' < "$OUT/linux-persist.raw" > "$OUT/linux-persist.txt"
[ -f "$OUT/linux-persist-legacy.raw" ] && tr -d '\000' < "$OUT/linux-persist-legacy.raw" > "$OUT/linux-persist-legacy.txt"
echo "--- persist (new/init, 56MiB)"; sed -n '/CHANGXING60-PERSIST-BEGIN/,/--- lsmod/p' "$OUT/linux-persist.txt" 2>/dev/null || true
echo "--- persist (legacy/early-recorder, 48MiB)"; sed -n '/CHANGXING60-PERSIST-BEGIN/,/--- lsmod/p' "$OUT/linux-persist-legacy.txt" 2>/dev/null || true
adb shell "su -c 'rm -rf $T'" >/dev/null 2>&1 || true
echo "saved: $OUT"
