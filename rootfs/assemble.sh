#!/bin/bash
# Assemble the changxing60 rootfs tarball from the exported Ubuntu image + overlay + kernel modules
set -e
KREL=5.4.254-gb50db5b6224c
R=/build/rootfs
rm -rf $R && mkdir -p $R
tar -xf /w/base.tar -C $R
cp -a /w/overlay/. $R/
# /lib is a symlink to usr/lib on Ubuntu; always write through usr/lib
mkdir -p $R/usr/lib/modules/$KREL/extra
cp /kmods/*.ko $R/usr/lib/modules/$KREL/extra/
cp /kout/modules.builtin /kout/modules.builtin.modinfo $R/usr/lib/modules/$KREL/
depmod -b $R $KREL
# per-device identity is created on first boot
# exported from a docker container: without this systemd-detect-virt says "docker" and skips timesyncd, pstore, random-seed
rm -f $R/.dockerenv
rm -f $R/etc/ssh/ssh_host_* ; : > $R/etc/machine-id; rm -f $R/var/lib/dbus/machine-id
# docker manages /etc/hostname, so the exported file is empty
echo changxing60 > $R/etc/hostname
ln -sfn ../run/systemd/resolve/stub-resolv.conf $R/etc/resolv.conf
# vendor firmware for Wi-Fi (wcnmodem.bin, wifi_board_config*.ini) is copied from the device's /odm/firmware
if [ -d /firmware ]; then mkdir -p $R/usr/lib/firmware && cp /firmware/* $R/usr/lib/firmware/; fi
# the Android vendor subset (modem_control + libs + properties) comes from android-vendor/extract-subset.sh
if [ -d /android-subset ]; then mkdir -p $R/opt/changxing60/android && cp -a /android-subset/. $R/opt/changxing60/android/ && mv $R/opt/changxing60/android/dev/__properties__ $R/opt/changxing60/android/dev-properties && rmdir $R/opt/changxing60/android/dev; fi
cp /logdw $R/opt/changxing60/bin/logdw
# tools/bt-init build (static arm64); Bluetooth also needs bt_configure_pskey.ini/bt_configure_rf.ini from Android /vendor/etc in /firmware
# optional Mali GPU userspace (android-vendor/extract-gpu-subset.sh) and OpenCL test (tools/gpu)
if [ -d /android-gpu-subset ]; then cp -an /android-gpu-subset/. $R/opt/changxing60/android/; fi
if [ -e /cltest ]; then install -D -m755 /cltest $R/opt/changxing60/android/system/bin/cltest; fi
if [ -e /bt-init ]; then cp /bt-init $R/opt/changxing60/bin/changxing60-bt-init; fi
for u in changxing60-vendor.service:sysinit.target changxing60-lan.service:multi-user.target changxing60-ssh-hostkeys.service:sysinit.target changxing60-telnetd.service:multi-user.target serial-getty@ttyGS0.service:getty.target ssh.socket:sockets.target changxing60-wifi.service:multi-user.target changxing60-mobile-data.service:multi-user.target changxing60-mobile-data-watch.service:multi-user.target changxing60-fixups.service:sysinit.target changxing60-zram.service:swap.target changxing60-boot-ok.service:multi-user.target changxing60-cp_diskserver.service:multi-user.target changxing60-refnotify.service:multi-user.target changxing60-extra-modules.service:multi-user.target changxing60-hotspot.service:multi-user.target changxing60-bluetooth.service:multi-user.target changxing60-thermal-guard.service:multi-user.target changxing60-firewall.service:sysinit.target changxing60-kmsg.service:sysinit.target systemd-networkd.service:multi-user.target; do
  svc=${u%%:*}; tgt=${u##*:}
  mkdir -p $R/etc/systemd/system/$tgt.wants
  src=/etc/systemd/system/$svc; [ -e $R$src ] || src=/usr/lib/systemd/system/$svc
  case $svc in serial-getty@*) src=/usr/lib/systemd/system/serial-getty@.service;; esac
  ln -sfn $src $R/etc/systemd/system/$tgt.wants/$svc
done
# no graphical/serial login noise on a headless dongle; keep ttyS1 console for debugging
ln -sfn /dev/null $R/etc/systemd/system/getty@tty1.service
cd $R && tar --numeric-owner -czf /w/changxing60-ubuntu-26.04-rootfs.tar.gz .
ls -la /w/changxing60-ubuntu-26.04-rootfs.tar.gz; du -sh $R
