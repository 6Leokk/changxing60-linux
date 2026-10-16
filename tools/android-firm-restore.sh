#!/bin/bash
# 一键固化：手机回到安卓后执行一次，永久默认安卓 + OpenWrt 侧自动弹回 + USB 网络共享
set -e
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
WORK=/home/kk/code/zte7552n/mu300-linux/work
BCA=$WORK/misc-slot-a-restore.bin   # 32-byte slot-a restore block (CRC verified)

echo "== 0. device check =="
"$ADB" get-state

echo "== 1. write slot-a misc block (default Android forever) =="
"$ADB" push "$BCA" /data/local/tmp/misc-slot-a.bin
"$ADB" shell su -c 'dd if=/data/local/tmp/misc-slot-a.bin of=/dev/block/by-name/misc bs=4096 seek=2048 count=1 conv=fsync'
"$ADB" shell su -c 'dd if=/dev/block/by-name/misc bs=4096 skip=2048 count=1 2>/dev/null | dd bs=1 count=32 2>/dev/null | od -An -tx1 -v | tr -d " \n"'
echo "   ^ expect: 5f6100004243414201020000ff000f0000000000000000000000000096b18d84"

echo "== 2. SELinux live patches (needed to mount mu300root) =="
"$ADB" shell su -c 'apd sepolicy --live "allow kernel shell fd use"' || true
"$ADB" shell su -c 'apd sepolicy --live "allow kernel ufs_device blk_file { read write open getattr ioctl append }"' || true

echo "== 3. mount mu300root, set OpenWrt default-boot=android (auto-bounce-back) =="
"$ADB" shell su -c '/data/local/tmp/mu300root-mount.sh 2>/dev/null || (losetup -o 77858865152 -S 50096766976 /dev/block/sda || losetup /dev/block/loop30 -o 77858865152 -S 50096766976 /dev/block/sda; mkdir -p /data/local/tmp/mu300root; mount -t ext4 /dev/block/loop30 /data/local/tmp/mu300root) 2>&1 || echo MOUNT_MAYBE_RUNNING_ALREADY'

echo "== 4. write default-boot=android + boot-os=android =="
"$ADB" shell su -c 'echo android > /data/local/tmp/mu300root/etc/mu300/default-boot 2>/dev/null && echo default-boot=android OK || echo default-boot FAILED'
"$ADB" shell su -c 'echo android > /data/local/tmp/mu300root/.mu300/boot-os 2>/dev/null && echo boot-os=android OK || echo boot-os FAILED'

echo "== 5. unmount =="
"$ADB" shell su -c 'umount /data/local/tmp/mu300root 2>/dev/null; losetup -D 2>/dev/null; echo unmounted'

echo "== 6. USB tethering ON (PC gets internet) =="
"$ADB" shell su -c 'settings put global tether_dun_required 0; svc usb setFunctions rndis; cmd connectivity tether start-usb 2>/dev/null || svc tether enable 2>/dev/null; echo tether-cmds-done'

echo "== 7. done. reboot test: any reboot now stays in Android. =="
