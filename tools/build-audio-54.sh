#!/bin/bash
# Build the Unisoc ASoC/AGDSP audio driver set for the 5.4 kernel and stage it, in one repro'd step.
#
# Why this exists: call audio needs the AGDSP stack (audio_sipc/audiosipc, audio_mem, mcdt_hw_r2p0,
# agdsp_access, sprd_audcp_boot, ...) plus the ASoC machine card that binds the DT's sound@0 node
# ("sprdphone-sc2730"). Android runs exactly these drivers as out-of-tree modules from
# vendor_dlkm/lib/modules; our kernel has CONFIG_SND_SOC_SPRD off and the same Kbuilds build the
# whole set out of tree, so no config change is needed. The Android *prebuilt* .ko cannot be used:
# 7 of the 21 modversions its vbc-fe imports mismatch our kernel's CRCs (module_layout included)
# and 10 more symbols (mcdt_*, agdsp_access_*) are only exported by the audio modules themselves,
# which must be built against the same kernel anyway. (See docs/changxing60/telephony.md.)
#
# Source: realme C51/C53 AndroidT kernel source, kernel_modules/kernel5.4/audio_driver (GPL),
# pinned to the same upload commit as tools/build-mali-54.sh (same vendor drop).
# Patches: kernel/patches/audio-*.patch, applied by kernel/build-audio.sh with grep guards.
#
# Usage: tools/build-audio-54.sh          (build; source is fetched automatically if absent)
#        tools/build-audio-54.sh --fetch  (re-clone the vendor source drop)
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
SRC_CACHE=${SRC_CACHE:-$HOME/.cache/mali-src}
REPO=https://github.com/realme-kernel-opensource/realme_C51_C53_Narzo-N53-AndroidT-kernel-source.git
COMMIT=4381465ccaf87fcf3215b9cd42f4a685df40e5e0
SPARSE=kernel_modules/kernel5.4/audio_driver
VOLUME=${VOLUME:-changxing60-kernel}
IMAGE=${IMAGE:-changxing60-kbuild-cross}      # needs clang-12 + llvm-strip, see kernel/Dockerfile.cross
BUILT=${BUILT:-$TOP/out-linux}                # where stage-modules.py looks for .ko
OUT=${OUT:-$TOP/work/audio-modules}           # the audio set on its own, for tools/audio
WANT_VERMAGIC=${WANT_VERMAGIC:-5.4.254-gb50db5b6224c}

if [ "${1:-}" = "--fetch" ] || [ ! -d "$SRC_CACHE/realme/$SPARSE" ]; then
	rm -rf "$SRC_CACHE"
	mkdir -p "$SRC_CACHE"
	git clone --depth 1 --filter=blob:none --sparse "$REPO" "$SRC_CACHE/realme"
	git -C "$SRC_CACHE/realme" sparse-checkout set "$SPARSE"
fi
SRC=$SRC_CACHE/realme/$SPARSE
have=$(git -C "$SRC_CACHE/realme" rev-parse HEAD)
[ "$have" = "$COMMIT" ] || echo "warning: vendor drop is $have, pinned is $COMMIT" >&2

docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "no docker volume $VOLUME" >&2; exit 1; }

docker run --rm -v "$VOLUME":/src -v "$SRC":/mnt/audio -v "$TOP/kernel":/work \
	-e CROSS_COMPILE=aarch64-linux-gnu- \
	"$IMAGE" bash /work/build-audio.sh

mkdir -p "$OUT"
rm -f "$OUT"/*.ko
# build-audio.sh leaves the stripped set in the kernel/ work dir it was given (/work/out)
docker run --rm -v "$TOP/kernel/out":/out-src -v "$OUT":/out alpine:3.20 \
	sh -c 'cp /out-src/*.ko /out/ 2>/dev/null || true'

# refresh out-linux too: it is the tree stage-modules.py indexes, and a stale copy there
# would quietly keep the OLD module in the staged set (this actually happened: rebuild
# produced new .ko, staging kept shipping the previous build).
docker run --rm -v "$VOLUME":/src -v "$TOP/out-linux":/out alpine:3.20 \
	sh -c 'cp /src/ext-audio/*/*.ko /out/ 2>/dev/null || true'
docker run --rm -v "$TOP/kernel/out":/out-src -v "$TOP/out-linux":/out alpine:3.20 \
	sh -c 'cp /out-src/*.ko /out/ 2>/dev/null || true'

n=$(ls "$OUT"/*.ko 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "no audio modules produced" >&2; exit 1; }

# every module must carry our kernel's vermagic or it will never load
bad=0
for ko in "$OUT"/*.ko; do
	got=$(modinfo "$ko" 2>/dev/null | awk '/^vermagic:/{print $2}')
	[ "$got" = "$WANT_VERMAGIC" ] || { echo "vermagic $got != $WANT_VERMAGIC: $ko" >&2; bad=1; }
done
[ "$bad" = 0 ] || exit 1

echo "audio modules: $n in $OUT"
echo "next: sudo python3 tools/stage-modules.py --built out-linux   (see telephony.md for load order)"
