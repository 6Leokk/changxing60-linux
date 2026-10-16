#!/bin/sh
# Deploy the OpenWrt container to the phone from the host (WSL), over adb (Windows adb.exe per project rule).
#   container/deploy.sh
# Pushes the built rootfs tarball + the APatch module, extracts the rootfs on-device,
# installs the module, and (optionally) starts the container immediately.
set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
TARBALL=$TOP/container/changxing60-openwrt-container-rootfs.tar.gz
MODSRC=$TOP/container/apatch-module/changxing60-openwrt
ROOT=/data/openwrt

[ -f "$TARBALL" ] || { echo "run container/build-rootfs.sh first" >&2; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "no adb device (booted into Android?)" >&2; exit 1; }

echo "== pushing rootfs tarball (extracts on device) =="
"$ADB" push "$TARBALL" /data/local/tmp/openwrt-rootfs.tar.gz

echo "== extracting container rootfs =="
"$ADB" shell su -c 'rm -rf /data/openwrt && mkdir -p /data/openwrt && cd /data/openwrt && tar -xzf /data/local/tmp/openwrt-rootfs.tar.gz && chmod 755 /data/openwrt/opt/changxing60/bin/sing-box /data/openwrt/opt/changxing60/bin/changxing60-vpn /data/openwrt/etc/init.d/changxing60-vpn && rm /data/local/tmp/openwrt-rootfs.tar.gz'

echo "== installing APatch module =="
"$ADB" push "$MODSRC/service.sh" /data/local/tmp/changxing60-openwrt-service.sh
"$ADB" push "$MODSRC/module.prop" /data/local/tmp/changxing60-openwrt-module.prop
"$ADB" shell su -c 'mkdir -p /data/adb/modules/changxing60_openwrt && cp /data/local/tmp/changxing60-openwrt-service.sh /data/adb/modules/changxing60_openwrt/service.sh && cp /data/local/tmp/changxing60-openwrt-module.prop /data/adb/modules/changxing60_openwrt/module.prop && chmod 755 /data/adb/modules/changxing60_openwrt/service.sh && rm /data/local/tmp/changxing60-openwrt-service.sh /data/local/tmp/changxing60-openwrt-module.prop'

echo "== done. Start now (y) or on next boot? Starting now: =="
"$ADB" shell su -c 'sh /data/adb/modules/changxing60_openwrt/service.sh start; sleep 5; sh /data/adb/modules/changxing60_openwrt/service.sh status'
