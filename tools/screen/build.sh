#!/bin/bash
# Build the static device binaries (aarch64 musl-ish: we link statically so the rootfs's musl
# version does not matter, and so a rootfs rebuild never strands the binaries):
#
#   changxing60-screen  the status page on the internal panel, and the power key as a screen switch
#   keyinject     synthetic key presses via uinput, so the key path can be tested without a finger
#   wifimac       apply the factory Wi-Fi MAC through the vendor's SPRDWLSETNDEVMAC ioctl (see the
#                 comment in wifimac.c: the AP's BSSID is random every boot without it)
#
# The device rootfs has no libdrm and no fbdev, so everything is raw syscalls. Run from anywhere;
# output lands in out/.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"

CC_IMG=changxing60-kbuild-cross
CFLAGS="-O2 -Wall -Wextra -static -s"

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    CC="aarch64-linux-gnu-gcc"
    "$CC" $CFLAGS -I"$here" -o "$out/changxing60-screen" "$here/changxing60-screen.c" "$here/qr.c"
    "$CC" $CFLAGS -o "$out/keyinject" "$here/keyinject.c"
    "$CC" $CFLAGS -o "$out/wifimac" "$here/wifimac.c"
else
    # the cross toolchain lives in the build image; same tree, bind-mounted read-only
    docker run --rm -v "$here":/src:ro -v "$out":/out "$CC_IMG" sh -euc "
        aarch64-linux-gnu-gcc $CFLAGS -I/src -o /out/changxing60-screen /src/changxing60-screen.c /src/qr.c
        aarch64-linux-gnu-gcc $CFLAGS -o /out/keyinject /src/keyinject.c
        aarch64-linux-gnu-gcc $CFLAGS -o /out/wifimac /src/wifimac.c
    "
fi

file "$out/changxing60-screen" "$out/keyinject" "$out/wifimac"
echo "built: $out/changxing60-screen $out/keyinject $out/wifimac"
