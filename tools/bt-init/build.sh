#!/bin/bash
# Build the Unisoc Marlin3 Bluetooth vendor-initialisation binary for the device.
#
#   changxing60-bt-init   uploads the PSKey and RF parameter blocks and enables the controller,
#                         on the H4 tty before `btattach -P h4` runs. Without it the firmware
#                         answers only a subset of HCI commands and BlueZ cannot power the adapter.
#
# Static, like every other binary on this box: the rootfs is OpenWrt's musl, and a static link means a
# rootfs rebuild can never strand it.
#
# WHY THIS SCRIPT EXISTS. build-rootfs.sh has always copied the binary in --
#
#     $(opt tools/bt-init/changxing60-bt-init bt-init)          # build input, line 39
#     [ -e /in/bt-init ] && { cp /in/bt-init $R/opt/... }       # install, line 143
#
# -- but the binary was never in the repository: tools/bt-init/ held only the .c. `$(opt ...)` expands
# to nothing when the file is absent, so a rebuilt rootfs silently shipped without it, and nothing
# noticed because the device was still running the one built by hand. A missing build input that is
# only ever referenced through a conditional is invisible in exactly the same way a missing mode bit
# is (see docs/changxing60/README.md). This is the same failure the screen and modem tools avoid by
# committing their binaries next to their sources.
#
# Usage: tools/bt-init/build.sh [OUTDIR]      (default: this directory, where build-rootfs.sh looks)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-$here}"

CC_IMG=changxing60-kbuild-cross
CFLAGS="-O2 -Wall -Wextra -static -s"

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	aarch64-linux-gnu-gcc $CFLAGS -o "$out/changxing60-bt-init" "$here/changxing60-bt-init.c"
else
	docker run --rm -v "$here":/src:ro -v "$out":/out "$CC_IMG" sh -euc "
		aarch64-linux-gnu-gcc $CFLAGS -o /out/changxing60-bt-init /src/changxing60-bt-init.c
	"
fi

file "$out/changxing60-bt-init"
echo "built: $out/changxing60-bt-init"
