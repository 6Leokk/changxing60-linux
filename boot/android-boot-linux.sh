#!/bin/sh
# From rooted Android: boot the Linux image already on boot_b once more (no reflash).
# usage: android-boot-linux.sh boot-linux-slotb.img   (uses its .json/.misc-slot-b-trial.bin for verification)
# Inside Linux, `sudo mu300-next-boot linux` then keeps Linux as the default.
set -eu
BASE=${1%.img}
EXP=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$BASE.json")
su_do() { adb shell "su -c '$1'" | tr -d '\r'; }
[ "$(su_do 'sha256sum /dev/block/by-name/boot_b' | cut -d' ' -f1)" = "$EXP" ] || { echo "boot_b does not contain $1; use flash-trial.sh" >&2; exit 1; }
adb push "$BASE.misc-slot-b-trial.bin" /data/local/tmp/mu300-bc-b.bin
su_do 'dd if=/data/local/tmp/mu300-bc-b.bin of=/dev/block/by-name/misc bs=1 seek=2048 conv=notrunc && sync'
[ "$(su_do 'dd if=/dev/block/by-name/misc bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1 -v' | tr -d ' \n')" = "$(xxd -p "$BASE.misc-slot-b-trial.bin" | tr -d '\n')" ] || { echo "misc verify failed" >&2; exit 1; }
adb reboot
