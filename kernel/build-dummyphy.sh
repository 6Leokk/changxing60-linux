#!/bin/bash
# Build phy-sprd-dummy (sprd,usb-dummy-phy) as an external module against out-linux.
# 7552n-port: the live 7552N DT sets usb3.usb-phy = <&dummyphy>,<&ssphy>; the GPL zte tree
# has no dummy-phy driver, so dwc3-sprd glue defers forever on usb-phy[0]. Source is the
# realme C51/C53 phy-sprd-dummy.c (Unisoc, GPL), self-contained against usb/phy.h.
set -e
DSRC=${DSRC:-/src/ext-dummy-phy}
cd /src/zte-u30air
make O=/src/out-linux ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} -j"$(nproc)" M="$DSRC" modules
llvm-strip --strip-debug -o /src/out-linux/phy-sprd-dummy.ko "$DSRC/phy-sprd-dummy.ko"
