#!/bin/bash
# Build the Mali kbase driver for the 5.4 kernel and stage it, in one repro'd step.
#
# Why this exists: the .ko was built once by hand into the docker volume and then lost when the
# volume was rebuilt. On the next boot `extra-modules` logged "FAILED mali_kbase: " (the module
# was simply not in /lib/modules) and there was no /dev/mali0 -- i.e. no GPU. Nothing in the
# pipeline noticed, because mali is an out-of-tree build that stage-modules.py listed as optional.
#
# The driver is Mali-G57 (Valhall) DDK r40p0-01eac0, UK 11.36, platform qogirn6pro -- the same DDK
# Android's userspace (libGLES_mali.so, which is also libOpenCL.so and the Vulkan ICD) speaks. The
# DDK that ships with the device does not load: 166 of its 335 imported symbol CRCs differ.
#
# Source: realme C51/C53 AndroidT kernel source, kernel_modules/kernel5.4/gpu/natt/mali (GPL).
# Pinned to the upload commit, because the repo is a vendor source drop and will not move again.
#
# Usage: tools/build-mali-54.sh [--fetch]     (--fetch re-clones the vendor source)
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
SRC_CACHE=${SRC_CACHE:-$HOME/.cache/mali-src}
REPO=https://github.com/realme-kernel-opensource/realme_C51_C53_Narzo-N53-AndroidT-kernel-source.git
COMMIT=4381465ccaf87fcf3215b9cd42f4a685df40e5e0
SPARSE=kernel_modules/kernel5.4/gpu/natt/mali
VOLUME=${VOLUME:-mu300-kernel}
IMAGE=${IMAGE:-mu300-kbuild-cross}      # needs clang-12 + llvm-strip, see kernel/Dockerfile.cross
BUILT=${BUILT:-$TOP/out-linux}          # where stage-modules.py looks for .ko
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
docker run --rm -v "$VOLUME":/src -v "$SRC":/mnt/mali alpine:3.20 \
	sh -c 'rm -rf /src/ext-mali && cp -a /mnt/mali /src/ext-mali'

# CROSS_COMPILE is read from the environment by make; build-mali.sh does not pass it itself.
docker run --rm -e CROSS_COMPILE=aarch64-linux-gnu- -e JOBS="$(nproc)" \
	-v "$VOLUME":/src -v "$TOP/kernel":/work "$IMAGE" bash /work/build-mali.sh

# build-mali.sh writes the .ko into the volume's out-linux; the tree stage-modules.py indexes is
# the checked-out one, so put it there too. Keep the debug info out of it (llvm-strip ran already).
mkdir -p "$BUILT"
docker run --rm -v "$VOLUME":/src -v "$BUILT":/out alpine:3.20 \
	sh -c 'cp /src/out-linux/mali_kbase.ko /out/mali_kbase.ko'

got=$(modinfo "$BUILT/mali_kbase.ko" 2>/dev/null | awk '/^vermagic:/{print $2}')
[ "$got" = "$WANT_VERMAGIC" ] || { echo "vermagic $got != $WANT_VERMAGIC" >&2; exit 1; }
echo "mali_kbase.ko: $(modinfo "$BUILT/mali_kbase.ko" | awk '/^version:/{print $2, $3, $4, $5}')"
echo "next: sudo python3 tools/stage-modules.py   (mali_kbase is a hard root there)"
