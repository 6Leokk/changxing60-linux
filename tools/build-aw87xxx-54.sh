#!/bin/bash
# Build the AW87xxx speaker amplifier driver for the 5.4 kernel and stage it, in one repro'd step.
#
# Why this exists: the internal panel and the call page are done, the AGDSP/ASoC card is up, and the
# voice PCM path runs -- but the speaker is silent, and this is the one driver standing between that
# and audible sound. The DT has carried the node all along:
#
#   /sys/firmware/devicetree/base/soc/ap-ahb/i2c@22a0000/aw87xxx@58
#     compatible = "awinic,aw87xxx_pa"   reg = <0x58>   status = "okay"
#
# and /sys/bus/i2c/devices/6-0058/ is a real, populated i2c device whose modalias matches this
# driver's of_device_id exactly -- with no `driver` symlink under it, i.e. nothing has ever bound.
# That is the whole reason the speaker is mute: the amp is on the bus, addressable and powered, and
# no driver claims it. (docs/changxing60/telephony.md, docs/changxing60/amp-aw87xxx.md)
#
# Source: Enceka/kernel_sprd_ums9158, sound/soc/sprd/unisoc/codec/aw87xxx/ -- a UMS9158 vendor tree.
# It is the right one and the only one: the driver the device ships with is an Android prebuilt
# (work/audio/vendor_dlkm_a.img, 285806 B) whose vermagic is 5.4.254-android12-9-gd5a8ab235157 and
# whose module_layout CRC differs from ours, so it cannot be insmod'd -- same story as every other
# vendor audio module in this project. The trees we already have do NOT contain aw87xxx: the realme
# C51/C53 audio drop has only aw881xx/aw883xx, and neither has this part.
#
# Chip identity: the amplifier is an AW87390 (pid 0x76) or AW87391 (pid 0xC1), not an AW87566. Read
# out of the firmware rather than guessed: firmware/aw87xxx_acf.bin carries profiles for aw87390 and
# aw87391 only. The driver auto-detects via register 0x00, so nothing here depends on which.
#
# The source tree is 5.15.211 but the driver carries an explicit AW_KERNEL_VER_OVER_5_4_0 guard and
# uses no post-5.4 API (no sysfs_emit, no proc_create, no dev_err_probe), so it builds against 5.4
# unmodified. That is not a guess: this script's build has been run, and the resulting .ko carries
# vermagic 5.4.254-gb50db5b6224c with every imported symbol resolved.
#
# WHAT THIS DOES NOT DO. Building and loading the module binds the driver to the amp; it does not by
# itself unmute it. The machine card reaches the PA through sprd-asoc-card-utils-hook.c, whose i2c-PA
# path is compiled out behind an `#if 0`, and the block cannot simply be re-enabled because it looks
# up aw87xxx_i2c_pa / aw87xxx_audio_scene_load with kallsyms_lookup_name and neither this driver nor
# the Android prebuilt exports them. The fix is the one e5-linux uses
# (kernel/patches/0012-aw87xxx-hook-without-gpio.patch): a hook_general_spk_for_aw87xxx() that calls
# the exported aw87xxx_set_profile(0, "Music"/"Off") and skips the GPIO lookup -- our DT has no
# sprd,spk-ext-pa-gpio, which is what makes the current code fail with "gpio is invalid!".
#
# Usage: tools/build-aw87xxx-54.sh           (build; source is downloaded if absent)
#        tools/build-aw87xxx-54.sh --fetch   (re-download the source)
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
SRC_CACHE=${SRC_CACHE:-$HOME/.cache/aw87-src}
COMMIT=9b36195d554d18c17dc30733a977ee69ce888ac1
RAW=https://raw.githubusercontent.com/Enceka/kernel_sprd_ums9158/$COMMIT/sound/soc/sprd/unisoc/codec/aw87xxx
VOLUME=${VOLUME:-changxing60-kernel}
IMAGE=${IMAGE:-changxing60-kbuild-cross}
BUILT=${BUILT:-$TOP/out-linux}
OUT=${OUT:-$TOP/work/aw87xxx-modules}
WANT_VERMAGIC=${WANT_VERMAGIC:-5.4.254-gb50db5b6224c}

# The module is named after Android's factory module (snd-soc-sprd-pa-aw87xxx) so that anything
# grepping for it -- the staging manifest, a boot log, a bisect list -- sees the same name the
# vendor build would have produced.
FILES="aw87xxx.c aw87xxx.h aw87xxx_device.c aw87xxx_device.h aw87xxx_monitor.c aw87xxx_monitor.h
       aw87xxx_bin_parse.c aw87xxx_bin_parse.h aw87xxx_dsp.c aw87xxx_dsp.h aw87xxx_acf_bin.c
       aw87xxx_acf_bin.h aw87xxx_log.h aw87xxx_platform.h"

if [ "${1:-}" = "--fetch" ]; then rm -rf "$SRC_CACHE"; fi
if [ ! -f "$SRC_CACHE/aw87xxx.c" ]; then
	mkdir -p "$SRC_CACHE"
	# Downloaded one file at a time rather than cloned: the tree is a full vendor kernel drop and we
	# want 14 files out of it, and the raw URLs are pinned to a commit so this stays reproducible.
	for f in $FILES; do
		curl -fsSL -o "$SRC_CACHE/$f" "$RAW/$f" || { echo "download failed: $f" >&2; exit 1; }
	done
fi

# The in-tree Makefile would drag in the whole codec directory; this builds the one module.
cat > "$SRC_CACHE/Makefile" <<'EOF'
obj-m := snd-soc-sprd-pa-aw87xxx.o
snd-soc-sprd-pa-aw87xxx-y := aw87xxx.o aw87xxx_device.o aw87xxx_monitor.o \
			     aw87xxx_bin_parse.o aw87xxx_dsp.o aw87xxx_acf_bin.o
EOF

docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "no docker volume $VOLUME" >&2; exit 1; }

docker run --rm -v "$VOLUME":/src -v "$SRC_CACHE":/mnt/aw -e CROSS_COMPILE=aarch64-linux-gnu- \
	"$IMAGE" bash -c '
set -e
cd /src/zte-u30air
make O=/src/out-linux ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld \
     -j"$(nproc)" M=/mnt/aw modules
'

mkdir -p "$OUT"
cp "$SRC_CACHE/snd-soc-sprd-pa-aw87xxx.ko" "$OUT/"
# refresh out-linux too: it is the tree stage-modules.py indexes, and a stale copy there would
# quietly keep shipping the previous build (this has happened with the audio set).
docker run --rm -v "$SRC_CACHE":/mnt/aw -v "$TOP/out-linux":/out alpine:3.20 \
	sh -c 'cp /mnt/aw/snd-soc-sprd-pa-aw87xxx.ko /out/'

ko=$OUT/snd-soc-sprd-pa-aw87xxx.ko
got=$(modinfo "$ko" 2>/dev/null | awk '/^vermagic:/{print $2}')
[ "$got" = "$WANT_VERMAGIC" ] || { echo "vermagic $got != $WANT_VERMAGIC: $ko" >&2; exit 1; }

# CFI matters on this kernel: a module built without it is rejected at load. The signal is the
# per-function .cfi_jt jump tables, not the __cfi_* stubs -- every function gets one and there are
# only a couple of stubs, so counting the wrong class gives a number small enough to look alarming
# (3 vs 77 here) while saying nothing. For scale, an existing module in this set (agdsp_access) has
# 12; this one has 77 because it is a much larger driver.
cfi=$(nm "$ko" 2>/dev/null | grep -c 'cfi_jt' || true)
[ "$cfi" -gt 0 ] || { echo "no CFI instrumentation in $ko -- this kernel requires it" >&2; exit 1; }

echo "amp module: $ko  ($(stat -c%s "$ko") B, $cfi cfi_jt symbols)"
echo "firmware:   firmware/aw87xxx_acf.bin must exist for the driver to find its profiles"
echo "next: the machine-card hook is still required for audible output -- see the header."
