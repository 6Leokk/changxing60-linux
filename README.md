# Linux on the ZTE F50 / MU300 (Unisoc T760)

Ubuntu 26.04 LTS with systemd, SSH, telnet, a USB serial console, a working modem/PM co-processor and
Wi-Fi on the ZTE F50 5G mobile hotspot (hardware MU300, Unisoc T760 / UMS9620). It runs a custom
5.4.254 kernel built from ZTE's GPL source and boots next to Android without changing the partition table.

> **Türkçe özet:** ZTE F50 / MU300 (Unisoc T760) üzerinde, Android'e ve bölüm tablosuna dokunmadan,
> ZTE'nin GPL kaynağından derlenmiş 5.4.254 kernel ile Ubuntu 26.04 LTS (systemd, SSH, telnet, USB seri
> konsol, modem ve Wi-Fi) çalıştırmak için gereken her şey. Ayrıntılar İngilizce; teknik bulguların tamamı
> [`docs/FINDINGS.md`](docs/FINDINGS.md) içinde.

> **Warning.** This writes to `boot_b` and to the `misc` partition, and creates a filesystem in unused eMMC space.
> It requires an unlocked/verification-bypassed device with root on Android and a working SPD download-mode
> recovery path. You can brick your device. Nothing here is endorsed by ZTE or Unisoc.

## Status

| Feature | State |
|---|---|
| Custom kernel (5.4.254, ZTE U30 Air source + fragment) | ✅ boots, 86 vendor modules rebuilt from source |
| Boot without touching `boot_a`, GPT or `userdata` | ✅ slot b one-shot trial, init restores slot a |
| USB Ethernet (ECM) + DHCP | ✅ `192.168.77.1`, host gets `192.168.77.2-9` |
| USB serial console (CDC-ACM) | ✅ `serial-getty@ttyGS0` |
| Ubuntu 26.04.1 LTS, systemd 259 | ✅ `running` (kernel 5.4 = systemd minimum baseline) |
| SSH and telnet | ✅ |
| PM co-processor watchdog / no power cut after ~290 s | ✅ via Android `modem_control` in a chroot |
| Modem firmware boot (`Modem Alive`) | ✅ |
| Wi-Fi (SC2355 / Marlin3) | ✅ station scan and access-point mode (`hostapd` AP-ENABLED) |
| Mobile data | ⏳ planned (AT commands + `sipa_eth`) |
| Default boot to Linux | ⏳ planned (currently a one-shot trial, reboot returns to Android) |
| OpenWrt rootfs | ⏳ planned |

## How it works

```
LK (slot b, tries=2) ─► custom 5.4 kernel + vendor_boot DTB
   └─► initramfs /init (boot/init)
         ├─ load 86 modules in a fixed order (boot/module-order.txt)
         ├─ write slot-a bootloader_control back to misc  (next reboot = Android)
         ├─ bind USB gadget: ECM (usb0 up immediately) + ACM console
         ├─ losetup -o 27762098176 /dev/mmcblk0 → ext4 "mu300root" (free space after userdata)
         └─ switch_root → systemd
               ├─ mu300-vendor   : Android modem_control in a chroot (disarms PM watchdog, boots modem)
               ├─ mu300-usb-net  : usb0 192.168.77.1 + dnsmasq DHCP
               ├─ mu300-wifi     : pcie-sprd, wcn_bsp, sprd_wlan_combo
               └─ ssh.socket, telnetd, serial-getty@ttyGS0
```

Read [`docs/FINDINGS.md`](docs/FINDINGS.md) for the reasoning behind each step (LK slot rules, LZ4 ramdisk,
USB dependency chain, the PM watchdog, the `modem_control` process-name check, macOS ECM link state, …).

## Repository layout

| Path | Contents |
|---|---|
| `kernel/` | Docker build env, stock F50 config, `mu300-linux.fragment`, build scripts, Wi-Fi driver patch |
| `boot/` | `init`, `module-order.txt`, `build-boot-image.py`, `flash-trial.sh` |
| `rootfs/` | Ubuntu 26.04 `Dockerfile`, `assemble.sh`, systemd units and helper scripts (`overlay/`) |
| `android-vendor/` | Scripts to extract the Android runtime subset from *your* device, permission generator |
| `tools/` | `logdw` (liblog sink), SSH/SCP/telnet/serial helpers, log collector, Android-side mount helper |
| `docs/` | Findings and notes |

Related: the kernel source used here is mirrored at
[`dikeckaan/zte-ums9620-kernel-5.4.254`](https://github.com/dikeckaan/zte-ums9620-kernel-5.4.254)
(ZTE U30 Air GPL release, 5.4.254).

**Not included** (proprietary or device-specific): stock partition images, Android vendor binaries and libraries,
`/dev/__properties__`, Wi-Fi/modem firmware, device dumps and identifiers. The scripts extract these from your own device.

## Requirements

* A rooted MU300/F50 with the boot verification bypass (Android must already boot a modified `boot` image),
  `adb` access, and a tested SPD/BROM recovery path.
* macOS or Linux host with Docker (arm64 native or emulation), Python 3, `lz4`, `adb`.
* Your own dumps: `boot_a.img` and the first 4 KiB of `misc` (`dd if=/dev/block/by-name/misc bs=4096 count=1`).

## Build and run

### 1. Kernel
```sh
git clone https://github.com/dikeckaan/zte-ums9620-kernel-5.4.254   # or the Enceka U30 Air repo
docker build -t mu300-kbuild kernel/
docker volume create mu300-kernel
docker run --rm -v mu300-kernel:/src -v "$PWD/../zte-ums9620-kernel-5.4.254":/tree mu300-kbuild cp -a /tree /src/zte-u30air
cp kernel/f50-stock-B09.config kernel/device.config
docker run --rm -v mu300-kernel:/src -v "$PWD/kernel":/work mu300-kbuild bash /work/build-linux.sh
```
`build-linux.sh` merges `mu300-linux.fragment` into the stock config, switches to ThinLTO and builds `Image` + modules
into `/src/out-linux`. Copy `Image`, `modules.builtin*` and all `*.ko` (flattened, `llvm-strip --strip-debug`) to `out/`.

Wi-Fi driver: extract `kernel_modules/kernel5.4/wcn/wlan/wlan_combo` from the realme C51/C53 AndroidT kernel source into
the volume as `/src/ext-wlan_combo`, then run `kernel/build-wlan.sh` (applies `patches/wlan_combo-default-board-config.patch`).

### 2. Android vendor subset (from your device)
```sh
android-vendor/extract-subset.sh android-subset
python3 android-vendor/gen-ueventd-perms.py android-subset/vendor/etc/ueventd.rc <vendor init *.rc> > android-vendor/ueventd-perms.sh
```

### 3. Boot image
```sh
docker build -t mu300-ubuntu:26.04 rootfs/
docker run --rm mu300-ubuntu:26.04 cat /bin/busybox > busybox && chmod +x busybox   # static, has mdev/losetup/switch_root/telnetd
docker run --rm -v "$PWD/tools/logdw":/w mu300-kbuild gcc -O2 -static -o /w/logdw /w/logdw.c
python3 boot/build-boot-image.py --stock-boot dumps/boot_a.img --misc-head dumps/misc-head.bin \
  --kernel out/Image --modules out/modules --busybox busybox --logdw tools/logdw/logdw \
  --ueventd-perms android-vendor/ueventd-perms.sh --android-subset android-subset --out boot-linux-slotb.img
```

### 4. Root filesystem on the free eMMC region
1. Check on *your* device that the space after `userdata` is really unallocated (compare the last partition end with
   the GPT's last usable LBA) and adjust `ROOT_OFFSET` in `boot/init` and `tools/android-mount-mu300root.sh`.
2. On Android (root), create the filesystem through a bounded loop device and verify offset/size first.
3. Assemble and deploy:
```sh
cid=$(docker create mu300-ubuntu:26.04); docker export $cid > rootfs/base.tar; docker rm $cid
docker run --rm -v "$PWD/rootfs":/w -v "$PWD/out/modules":/kmods:ro -v "$PWD/out":/kout:ro \
  -v "$PWD/firmware":/firmware:ro -v "$PWD/android-subset":/android-subset:ro -v "$PWD/tools/logdw/logdw":/logdw:ro \
  mu300-ubuntu:26.04 bash /w/assemble.sh
```
Push `mu300-ubuntu-26.04-rootfs.tar.gz` to the device and extract it with `tools/android-mount-mu300root.sh`.
`firmware/` holds `wcnmodem.bin`, `gnssmodem.bin` and `wifi_board_config*.ini` from the device's `/odm/firmware`.

### 5. Boot Linux (one-shot)
```sh
boot/flash-trial.sh boot-linux-slotb.img
```
After about 50 s: `ssh ubuntu@192.168.77.1` (password `ubuntu`, **change it**), `telnet 192.168.77.1`, or
`screen /dev/cu.usbmodem* 115200`. `sudo reboot` returns to Android. If a trial fails, collect logs from Android with
`tools/collect-logs.sh`.

## Credits and licenses

* Kernel source: ZTE GPL release for the U30 Air (mirrored by Enceka), Unisoc drivers therein — GPL-2.0.
* Wi-Fi driver source: realme C51/C53 AndroidT kernel release (`wlan_combo`) — GPL-2.0; the patch in `kernel/patches` is GPL-2.0.
* Scripts, tools and documentation in this repository: MIT (see `LICENSE`).
* Stock firmware, Android vendor components and bootloaders belong to their owners and are not distributed here.
