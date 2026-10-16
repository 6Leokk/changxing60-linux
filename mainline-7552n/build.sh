#!/bin/bash
# 7552N (ZTE 7552N / 畅行60, UMS9620) build wrapper around upstream's mu300-linux build.
#
# Upstream targets F50/MU300/U30 Air (eMMC, no panel).  We keep their whole tree and graft only the two
# board deltas the 7552N needs, so every upstream fix stays reachable by re-syncing upstream/:
#
#   1. config-7552n.config -- UFS instead of eMMC.  Merged by bind-mounting a concatenation over
#      /work/mu300-mainline.config, which build.sh both merge_config's and *verifies* option by option
#      (build.sh:35, 40-45).  No edit to upstream's build.sh, and our options get asserted too.
#   2. tools/patch-vendor-dtb.py -- additively patch the *stock* vendor DTB (LK takes the DT from
#      vendor_boot; upstream proved a *replacement* DTB hangs in setup_machine_fdt).  See the tool docstring.
#
# usage: build.sh [kernel|dtb|image|all]     (env KV=6.18.56)
set -eo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
UP=$ROOT/upstream
KV=${KV:-6.18.56}
cmd=${1:-kernel}

KERNEL_DOCKER=(docker run --rm -e CROSS_COMPILE=aarch64-linux-gnu- -e KV="$KV"
               -v changxing60-mainline:/src -v "$UP":/work)

build_kernel() {
    # merge_config takes fragments in order and later ones win; concatenating is exactly equivalent to a
    # second merge_config call, and it keeps build.sh's per-option verification covering our delta as well.
    cat "$UP/mu300-mainline.config" "$HERE/config-7552n.config" > "$HERE/merged-7552n.config"
    # Our kernel-source delta rides in on upstream's *own* patch loop: build.sh runs port/install.py first and
    # then applies every /work/patches/*.patch (idempotently, by checksum, and it stops the build if a patch
    # neither applies nor is already applied).  Binding our patches into that directory -- rather than copying
    # them there -- keeps upstream/ exactly as it shipped, so a re-sync of upstream/ cannot lose them, and puts
    # them after install.py's edits, which is the only order that works for a file install.py also rewrites.
    # Our names sort after upstream's 00xx (glob order) and no upstream patch touches the same hunks.
    ours=()
    for p in "$HERE"/patches/*.patch; do
        [ -e "$p" ] || continue
        ours+=(-v "$p":/work/patches/"$(basename "$p")":ro)
    done
    echo "== kernel $KV =="
    "${KERNEL_DOCKER[@]}" "${ours[@]}" -v "$HERE/merged-7552n.config":/work/mu300-mainline.config:ro \
        changxing60-cross bash /work/build.sh
    echo "== modules =="
    "${KERNEL_DOCKER[@]}" changxing60-cross bash /work/build-modules.sh
    # our out-of-tree module deltas, applied to build-modules.sh's own copy under /src/mod-build
    # (never to upstream/) and rebuilt there -- see the script's header for what and why.
    echo "== module deltas =="
    "${KERNEL_DOCKER[@]}" -v "$HERE":/work/mainline-7552n:ro \
        changxing60-cross bash /work/mainline-7552n/module-deltas.sh
    # LK copies the kernel to 0x80080000 and 6.18 has text_offset 0, so the Image must be wrapped first
    python3 "$UP/wrap-image.py" "$UP/out/Image" "$UP/out/Image.lk"
}

build_dtb() {
    echo "== patched vendor_boot (slot b) =="
    docker run --rm -v "$ROOT":/w -v /tmp:/tmp changxing60-cross \
        python3 /w/mainline-7552n/tools/patch-vendor-dtb.py \
            --vendor-boot /w/work/dumps/vendor_boot_b.img \
            --out        /w/work/vendor_boot_b-7552n.img
}

build_image() {
    echo "== boot image (slot b) =="
    python3 "$ROOT/boot/build-boot-image.py" \
        --stock-boot     "$ROOT/work/dumps/boot_ori.img" \
        --misc-head      "$ROOT/work/dumps/misc-head.bin" \
        --kernel         "$UP/out/Image.lk" \
        --modules        "$UP/out/modules" \
        --module-order   "$UP/module-order.txt" \
        --init           "$ROOT/boot/init" \
        --busybox        "$ROOT/work/busybox" \
        --logdw          "$ROOT/tools/logdw/logdw" \
        --ueventd-perms  "$ROOT/android-vendor/ueventd-perms.sh" \
        --android-subset "$ROOT/work/android-subset" \
        --out            "$ROOT/work/boot-618-slotb.img"
}

case "$cmd" in
    kernel) build_kernel ;;
    dtb)    build_dtb ;;
    image)  build_image ;;
    all)    build_kernel; build_dtb; build_image ;;
    *)      echo "usage: build.sh [kernel|dtb|image|all]" >&2; exit 2 ;;
esac
