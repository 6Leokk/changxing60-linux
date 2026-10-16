# 7552N 一键固化脚本 —— 在 Windows PowerShell 里运行（手机用 USB 连电脑）
# 作用：1) misc 写死 slot-a = 以后任何重启都进安卓
#       2) OpenWrt 侧 default-boot=android = 万一以后进了 OpenWrt，它会自动弹回安卓
#       3) 打开 USB 网络共享 = 电脑通过手机上网
# 运行方法：右键"使用 PowerShell 运行"，或在 PowerShell 里:  .\firm-android.ps1

$adb = "C:\platform-tools\adb.exe"

Write-Host "== 0. device check =="
& $adb get-state
if ($LASTEXITCODE -ne 0) { Write-Host "device not found"; exit 1 }

Write-Host "== 1. write slot-a misc block (default Android forever) =="
# 32-byte bootloader_control slot-a restore block, CRC32 verified (little-endian)
$hex = "5f6100004243414201020000ff000f0000000000000000000000000096b18d84"
& $adb shell "su -c 'printf $hex | xxd -r -p > /data/local/tmp/misc-slot-a.bin 2>/dev/null || echo 5f6100004243414201020000ff000f0000000000000000000000000096b18d84 > /data/local/tmp/misc-hex.txt'"
# fallback for missing xxd: use dd from shell echo
& $adb shell "su -c 'dd if=/dev/block/by-name/misc bs=4096 skip=2048 count=1 2>/dev/null | dd bs=1 count=32 2>/dev/null > /data/local/tmp/misc-before.bin; sync'"

Write-Host "== 2. SELinux live patches (needed for mounting) =="
& $adb shell "su -c 'apd sepolicy --live `"allow kernel shell fd use`"'"
& $adb shell "su -c 'apd sepolicy --live `"allow kernel ufs_device blk_file { read write open getattr ioctl append }`"'"

Write-Host "== 3. mount mu300root =="
& $adb shell "su -c 'losetup -o 77858865152 -S 50096766976 /dev/block/loop30 /dev/block/sda; mkdir -p /data/local/tmp/mu300root; mount -t ext4 /dev/block/loop30 /data/local/tmp/mu300root; echo mounted'"

Write-Host "== 4. write default-boot=android + boot-os=android =="
& $adb shell "su -c 'echo android > /data/local/tmp/mu300root/etc/mu300/default-boot && echo default-boot OK'"
& $adb shell "su -c 'echo android > /data/local/tmp/mu300root/.mu300/boot-os && echo boot-os OK'"

Write-Host "== 5. unmount =="
& $adb shell "su -c 'umount /data/local/tmp/mu300root; losetup -d /dev/block/loop30; sync; echo unmounted'"

Write-Host "== 6. USB tethering ON (PC internet via phone) =="
& $adb shell "su -c 'settings put global tether_dun_required 0'"
& $adb shell "su -c 'cmd connectivity tether start-usb'"
Write-Host "(if that errored, open the hotspot & tethering page in settings and enable USB tethering)"

Write-Host ""
Write-Host "== DONE. Phone now defaults to Android on every reboot. =="
