#!/bin/bash
# Assemble the MU300 rootfs tarball from the exported Ubuntu image + overlay + kernel modules
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
rm -f $R/etc/ssh/ssh_host_* ; : > $R/etc/machine-id; rm -f $R/var/lib/dbus/machine-id
# docker manages /etc/hostname, so the exported file is empty
echo mu300 > $R/etc/hostname
# vendor firmware for Wi-Fi (wcnmodem.bin, wifi_board_config*.ini) is copied from the device's /odm/firmware
if [ -d /firmware ]; then mkdir -p $R/usr/lib/firmware && cp /firmware/* $R/usr/lib/firmware/; fi
# the Android vendor subset (modem_control + libs + properties) comes from android-vendor/extract-subset.sh
if [ -d /android-subset ]; then mkdir -p $R/opt/mu300/android && cp -a /android-subset/. $R/opt/mu300/android/ && mv $R/opt/mu300/android/dev/__properties__ $R/opt/mu300/android/dev-properties && rmdir $R/opt/mu300/android/dev; fi
cp /logdw $R/opt/mu300/bin/logdw
for u in mu300-vendor.service:sysinit.target mu300-usb-net.service:multi-user.target mu300-ssh-hostkeys.service:multi-user.target mu300-telnetd.service:multi-user.target serial-getty@ttyGS0.service:getty.target ssh.socket:sockets.target mu300-wifi.service:multi-user.target systemd-networkd.service:multi-user.target; do
  svc=${u%%:*}; tgt=${u##*:}
  mkdir -p $R/etc/systemd/system/$tgt.wants
  src=/etc/systemd/system/$svc; [ -e $R$src ] || src=/usr/lib/systemd/system/$svc
  case $svc in serial-getty@*) src=/usr/lib/systemd/system/serial-getty@.service;; esac
  ln -sfn $src $R/etc/systemd/system/$tgt.wants/$svc
done
# no graphical/serial login noise on a headless dongle; keep ttyS1 console for debugging
ln -sfn /dev/null $R/etc/systemd/system/getty@tty1.service
cd $R && tar --numeric-owner -czf /w/mu300-ubuntu-26.04-rootfs.tar.gz .
ls -la /w/mu300-ubuntu-26.04-rootfs.tar.gz; du -sh $R
