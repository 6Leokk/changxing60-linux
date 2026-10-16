#!/bin/bash
# Build tools/modem/changxing60-modemd.c into a static aarch64 binary.
#
# Static, like every other binary on this box: the rootfs is OpenWrt's musl, and a static link means a
# rootfs rebuild can never strand the daemon. There is no aarch64 compiler on the host, so the cross
# toolchain in the changxing60-kbuild-cross image does it (the same image tools/screen/build.sh uses).
#
# The output is committed next to the source and copied in by openwrt/build-rootfs.sh, which is how
# logdw, changxing60-bt-init and the screen tools work too. Run from anywhere.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_IMG=changxing60-kbuild-cross
CFLAGS="-O2 -Wall -Wextra -static -s"

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	aarch64-linux-gnu-gcc $CFLAGS -o "$here/changxing60-modemd" "$here/changxing60-modemd.c"
else
	docker run --rm -v "$here":/src:ro -v "$here":/out "$CC_IMG" sh -euc "
		aarch64-linux-gnu-gcc $CFLAGS -o /out/changxing60-modemd /src/changxing60-modemd.c
	"
fi

file "$here/changxing60-modemd"
echo "built: $here/changxing60-modemd"
