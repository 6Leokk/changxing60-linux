# Findings: running Linux on the ZTE F50 / MU300 (Unisoc T760)

Everything below was verified on a ZTE F50 (hardware MU300, firmware `MU300_ZYV1.0.0B09`,
Android 13, stock kernel `5.4.254-android12-9-g9c6342244991`) during September 2026.
Each item lists the symptom, the root cause and the fix, so it can be reused for other
UMS9620 devices (for example the ZTE U30 Air).

## Hardware and firmware facts

| Item | Value |
|---|---|
| SoC | Unisoc T760 (UMS9620, "qogirn6pro"), board `ums9620_2h10_feimao` |
| RAM | 2 GiB (about 1.4 GiB visible to Linux, the rest is reserved for modem/TEE) |
| Storage | eMMC, about 58.25 GiB (122159104 sectors) |
| PMIC | UMP9620 (+ UMP9621), charger IC bq2560x/sgm41513, fuel gauge sc27xx-fgu |
| Wi-Fi/BT | SC2355 "Marlin3" on PCIe, firmware `MARLIN3_20A_RLS2_W24.45.4` |
| USB | DWC3 (`25100000.dwc3`) + MUSB (`musb-hdrc.1.auto`), Type-C on the PMIC |
| Bootloader | Unisoc LK ("sprdlk"), Trusty TEE, A/B slots |
| Boot images | boot and vendor_boot are Android header v4, page 4096, LZ4 legacy ramdisks |

## Boot chain and safe testing

### 1. Slot b one-shot trial (never touch boot_a)
* Linux is written to **boot_b** only, and the 32-byte AOSP `bootloader_control` block at
  offset `0x800` of `misc` is set so that slot b has the highest priority.
* **Unisoc LK treats `tries_remaining == 1 && successful_boot == 0` as an already failed boot**
  (`ANDROID: slot 1 booted fail, rolling back spl and reboot into normal`). A one-shot trial therefore
  needs `tries_remaining = 2`: LK decrements it to 1 and boots slot b; if that boot fails, the next boot
  rolls back to slot a.
* Linux `init` writes the original slot-a block back to `misc` as one of its first steps, so any later
  reboot returns to Android.
* The `uboot_log` partition contains LK's ring log. It is the best source for "which slot was chosen" and
  "why did it reset" (`rst_mode`, `charge first poweron reset`, watchdog flags).

### 2. Boot ramdisk must be LZ4 legacy
* Symptom: `RAMDISK: lz4 image found at block 0`, `RAMDISK: incomplete write (-28 != 8388608)`, then
  `VFS: Unable to mount root fs on unknown-block(1,0)`.
* Cause: vendor_boot's ramdisk is LZ4 legacy; a gzip boot ramdisk appended to it is not unpacked as an
  initramfs by this 5.4 kernel, which then falls back to the legacy `/dev/ram0` image path.
* Fix: compress the boot ramdisk with `lz4 -l`. Also add a `dev/console` node to the cpio.

### 3. Logs without a serial console
* The stock cmdline has `loglevel=1`, so nothing reaches `console-ramoops`.
* pstore only survives a warm reset. Most failures on this device end in a power cut, so init also
  persists its stage list and `dmesg` into unused space inside **boot_b at 48 MiB (8 MiB)**; it is read
  back from Android.
* A USB CDC-ACM function (`acm.GS0`) next to ECM gives a login console on the host
  (`/dev/cu.usbmodem*` on macOS) that works even when networking does not.

## Hardware bring-up with the vendor modules

### 4. USB gadget dependency chain
The UDC only appears when the whole chain probes, in this order:
`extcon-usb-gpio` (the PHY node references `extcon-gpio`) → PHYs → `sc27xx_adc` → `sprd_battery_info`
→ `sprd-charger-manager` → `sc27xx_fuel_gauge` → `bq2560x-charger` (provides the `otg-vbus` regulator used as
`vbus-supply` by DWC3 and MUSB) → `dwc3-sprd` / `musb_sprd`.
* **`sc27xx_adc` must be loaded before the fuel gauge.** The vendor `sc27xx-fgu` driver returns a hard error
  (not `-EPROBE_DEFER`) when its IIO channel is missing and is never probed again.
* The exact working order of the 86 modules is in `boot/module-order.txt`.

### 5. The ~290 s power cut (PM co-processor watchdog)
* Symptom: Linux runs normally, then the device loses power about 290 s after boot. LK shows
  `charge first poweron reset`, not a watchdog reset.
* Cause: the PM co-processor (CM4, `pm_sys`) runs its own watchdog. `sprd_pmic_wdt` disarms it by sending
  `watchdog rstoff` over an SIPC sbuf channel, but that channel only becomes ready after Android's
  `modem_control` reloads `pm_sys` (and the modem) through Trusty (`kernelbootcp` TA).
* Fix: run Android's own `/vendor/bin/modem_control` in a chroot with Android's bionic linker and
  libraries. Requirements that were each discovered by failure:
  1. Copy `/dev/__properties__` from a running Android so property reads work.
  2. Create `/dev/block/by-name` links and apply Android's node ownership (`ueventd.rc` plus `chown`/`chmod`
     from vendor `init*.rc`), because `modem_control` drops to uid `system` (1000).
  3. Bind-mount a copy of `/proc/cmdline` with `androidboot.slot_suffix=_a` so it loads the `_a` modem images
     (LK passes `_b` when booting the trial slot).
  4. **Exec the binary directly.** `sprd_modem_loader` rejects every ioctl/write unless `current->comm` is
     exactly `modem_control` (`drivers/unisoc_platform/modem_loader`); running it as
     `linker64 /vendor/bin/modem_control` makes the task name `linker64`.
  5. Provide a sink for liblog (`tools/logdw`, listens on `/dev/socket/logdw`), otherwise the daemon's logs vanish.
* Result: `kbc_verify_all_avb2() ret = 0`, `SEC_KBC_START_CP() ret = 0`,
  `sprd-pmic-wdt: sbuf ready for pmic wdt init!`, `Modem Alive`, and no more power cut.

### 6. Load average of about 12 is not CPU usage
Vendor kernel threads (`sprd-rotation/N`, `sipa-*`, `slog`) wait in `D` state; Linux counts them in the load
average. `top` shows about 98 % idle.

## Custom kernel

### 7. Matching source
* The ZTE U30 Air kernel (`github.com/Enceka/android_kernel_zte_ums9620_mifi_u30air`, "downloaded from ZTE
  opensource") is exactly 5.4.254, covers 137 of the 150 F50 vendor modules and all but one derived config
  symbol of the F50 stock config.
* Missing from that tree: camera/GPU modules and the Wi-Fi driver `sprd_wlan_combo`, which is taken from
  the realme C51/C53 AndroidT kernel_modules drop.
  **Correction (2026-10-13):** display and touch drivers are *not* missing. The ZTE tree carries
  `drivers/gpu/drm/sprd` in full — the config simply leaves `CONFIG_DRM_SPRD` off (the F50 has no panel),
  so `sprd-drm.ko` was never built, not absent. Touch is on SPI (`axs15205`), and `spi-sprd.ko` /
  `zte_tpd.ko` are in the tree too. See `docs/mu300/screen-plan.md` (in the parent repo).
  Only `sprd,vpu-pd` is genuinely absent from the ZTE tree and comes from elsewhere.
* An older Unisoc 5.4.147 tree lacks the whole qogirn6pro USB stack and is not usable.

### 8. Build notes
* Full LTO needs more than 8 GiB in the linker step; ThinLTO keeps CFI and links fine.
* Stock config + `kernel/mu300-linux.fragment` adds devtmpfs, fhandle, autofs, SysV IPC, namespaces, nftables,
  btrfs/xfs/squashfs, NFS/CIFS, USB serial/modem/audio host drivers, crypto user API, CDC-ACM gadget, and removes
  `STATIC_USERMODEHELPER` and forced module signatures.
* All vendor modules must be rebuilt from the same tree (symbol CRCs change).

## Root filesystem on free eMMC space

### 9. Unused space after userdata
* `userdata` is 20 GiB and ends at sector 54218752; the GPT's last usable LBA is 122155007 and the backup GPT
  is at the very end. About **32.4 GiB between them belongs to no partition** and read back as zeros.
* The rootfs is an ext4 filesystem (`mu300root`) at byte offset `27762098176` (sector 54222848), 32.39 GiB,
  accessed through a loop device with an offset. **The GPT, userdata and all Android partitions are unchanged.**
* `userdata` uses metadata encryption (`dm-default-key`, `inlinecrypt`), so it cannot be shrunk or shared.

### 10. Mounting gotchas
* busybox `mount -o loop,offset=` only creates a loop for regular files; for a block device the options go to
  ext4 and fail with `EINVAL`. Use `losetup -o` and verify `/sys/block/loopN/loop/offset`.
* Android's `losetup -f` can return a loop index whose node does not exist yet; allocate, wait for the node and
  refuse to attach the same offset twice (two loops mounting one ext4 corrupted it once).
* Toybox `od` on 64 MiB is extremely slow; never interrupt a safety check, an interrupted pipeline "passed" once.

## Ubuntu 26.04 LTS on kernel 5.4

### 11. systemd 259 works on 5.4
5.4 is systemd's minimum baseline; the system boots to `running` with the `old-kernel` taint.

### 12. USB Ethernet must be up before the host activates ECM
* Symptom: macOS shows the "MU300 Linux USB Ethernet" interface as `inactive` forever, no DHCP, although on the
  device `usb0` is UP with carrier.
* Cause: `usb0` was only brought up by a systemd unit a few seconds after the UDC was bound. f_ecm reports the link
  in its first CONNECT notification and macOS' `AppleUserECM` does not pick up a later "connected" notification.
* Fix: `ifconfig usb0 up` immediately after binding the UDC in the initramfs.

### 13. Userland needing newer syscalls
* Ubuntu 26.04's GNU `tar` fails with `Function not implemented` when extracting (it relies on `openat2`,
  Linux 5.6). Use busybox `tar` on the device or extract from another system.
* `ssh.service` is socket-activated on 26.04; enable `ssh.socket`, not only `ssh.service`.
* Extracting an archive that contains a `lib/` directory over Ubuntu replaces the `/lib -> usr/lib` symlink with a
  directory (systemd then disappears). Always ship files under `usr/lib/...`.
* `docker export` leaves `/etc/hostname` empty.

## Wi-Fi (SC2355 / Marlin3)

### 14. Bring-up
* Modules: `pcie-sprd-misc`, `pcie-sprd`, `wcn_bsp`, `sprd_wlan_combo`.
* Firmware and board config come from Android's `/odm/firmware`: `wcnmodem.bin`, `gnssmodem.bin`,
  `wifi_board_config.ini`, `wifi_board_config_ab.ini`. Place them in `/usr/lib/firmware`.
* The realme `wlan_combo` driver falls back to `wifi_board_config_hulk.ini` for unknown projects; the firmware then
  asserts with `CMD_DOWNLOAD_INI / LOAD_INI_DATA_FAILED` and the chip stays in "card dump" state, so `wlan0` cannot
  be brought up (`RTNETLINK answers: No such device`). `kernel/patches/wlan_combo-default-board-config.patch` fixes it.
* `rmmod wcn_bsp` crashes the kernel; reboot instead of reloading the Wi-Fi stack.
* The driver logs `API version not match` for a few command IDs (the realme driver is slightly older than the ZTE
  firmware) and a `WARNING` in `sc2355_free_cmd_buf` (spin_unlock_bh in IRQ context).
* Verified after the fix: the driver parses `wifi_board_config.ini`, `wlan0` comes up, `iw dev wlan0 scan` lists
  nearby networks and `hostapd` (nl80211, WPA2) reaches `AP-ENABLED`. The MAC address is randomized on each load.
* A crash right after installing a module can leave a 0-byte `.ko` on ext4; run `sync` after installing files.

## Mobile data without Android RIL

### 15. Radio, registration and the data bearer
* AT channels: `/dev/stty_nr0` carries unsolicited results (URCs); `/dev/stty_nr1` is a clean command channel.
* After `modem_control` boots the modem the radio is off (`+CFUN: 0`). Android's RIL (`libimpl-ril.so`) uses the Unisoc
  commands `AT+SFUN=2` (SIM on) and `AT+SFUN=4` (protocol stack on); afterwards `+CFUN: 1` and the modem registers
  (`+CEREG: 2,1,...,13` = E-UTRA-NR dual connectivity, i.e. 5G NSA).
* The network activates the default EPS bearer (CID 1, IPv4v6) by itself. `AT+CGCONTRDP=1` returns the address as
  `a.b.c.d.m.m.m.m` plus DNS servers. `AT+CGDATA="M-ETHER",1` answers `CONNECT` and binds the bearer to
  `sipa_eth0` (`sipa_eth<cid-1>`, raw IP, `NOARP`). Assign the address as /32 and route `default dev sipa_eth0`.
* Measured on a Turkcell 5G NSA SIM: about 9.3 MB/s download and 1.3 MB/s upload. `rootfs/.../mobile-data` implements
  up/down/status/sim-reset and NAT (`nftables masquerade` + MSS clamping) so USB/Wi-Fi clients can share the link.
* AT responses can arrive after a short read timeout and then show up as answers to the next command. Drain the channel
  before sending and read until the final result code (`OK`, `ERROR`, `+CME ERROR`, `CONNECT`).
* Hot-swapping the SIM leaves it busy (`+CME ERROR: 14`) and registration stays at emergency-only (`+CEREG: 2,8`);
  reboot after changing the SIM.
* A SIM without an active data plan still registers and gets an address; TCP handshakes may even succeed, but no data
  flows. Check the plan before debugging the data path.

### 16. Rootfs details found while testing data
* `docker export` leaves an empty `/etc/resolv.conf`: `resolvectl query` works but glibc programs cannot resolve names.
  Link it to `../run/systemd/resolve/stub-resolv.conf`.
* busybox/toybox tar drop xattrs, so `ping` loses `cap_net_raw`; `mu300-fixups.service` restores it.
* Android's uid `system` (1000) is also Ubuntu's first user, so modem device nodes show up as owned by `ubuntu`.

## Default boot

### 17. Linux as default without losing the Android fallback
* LK decrements `tries_remaining` before booting a slot and rolls back when it finds `tries == 1 && !successful`.
  The one-shot trial arms slot b with `tries = 2`.
* Default-Linux mode never sets `successful_boot`. Instead:
  1. init skips the slot-a restore when `/etc/mu300/default-boot` in the rootfs says `linux` (slot b is left at `tries = 1`);
  2. `mu300-boot-ok.service` runs 30 s after `multi-user.target` and writes the `tries = 2` block again.
* A boot that never reaches `mu300-boot-ok` therefore leaves `tries = 1`, and the next boot rolls back to Android.
* Verified: `mu300-next-boot linux` + reboot returned to Linux and re-armed slot b; `mu300-next-boot android` + reboot
  booted slot a.

## Parity with Android

### 18. Services and drivers Android runs that the minimal port lacked
* `cp_diskserver` persists modem NV (`nr_fixnv*`, `nr_runtimenv*`); on first start it immediately wrote pending
  "dirty" NV data, so without it modem NV changes are lost. `refnotify` handles modem reference-clock requests.
  Both run from the same chroot; `srtd` needs Android's binder radio HAL and is skipped.
* Drivers that load cleanly after the modem is up: `sprd_soc_thm`, `thermal-generic-adc`, `sprd_cpu_cooling` (binds
  cpufreq and CPU hotplug cooling to `soc-thmzone` with trips at 70/85/110 °C), `leds-sc27xx-bltc` (RGB status LED),
  `zte_card_holder_det`, `sc27xx-vibra`, `sprd_cp_dvfs`, `sprd_ddr_dvfs`. `zte_sar` loads but the aw9610x SAR sensor
  is not populated on this board (`-201`).
* Android disables audio entirely (`ro.audioserver.disabled=true`, no sound cards) although the device tree has an
  enabled sound card (`unisoc,vbc-v4-codec-sc2730`), the UMP9620 codec and an AW883xx smart amplifier that answers on I2C.
* Android's hotspot (`WifiConfigStoreSoftAp.xml`) lives on the metadata-encrypted `/data`, so Linux cannot read it; it
  has to be copied while Android runs. No factory default Wi-Fi credential is stored in a readable partition.
* RAM: Android uses about 960 MiB of the 1.4 GiB; Ubuntu with all services about 480 MiB, of which ~100 MiB is
  unreclaimable vendor-driver slab. journald is capped (`RuntimeMaxUse=16M`).

### 19. systemd ordering pitfall
* A unit `Before=ssh.socket` that keeps default dependencies is ordered after `basic.target`, while `ssh.socket` is
  before `sockets.target` (before `basic.target`). systemd silently drops `ssh.socket` from the boot transaction and SSH
  never starts. Units that must run before sockets need `DefaultDependencies=no`.

### 20. Diagnosing early power cuts
* The initramfs log loop ends at `switch_root` and journald flushes only after local filesystems are up, so a power cut in
  the first seconds of systemd leaves no log. `mu300-early-recorder.service` keeps writing `dmesg` to the boot_b log area
  for the first five minutes.

## LAN, Wi-Fi bands and regulatory

### 21. One LAN for USB and Wi-Fi
* `br-lan` (192.168.77.1/24, `usb0`) is the USB management link; `br-wifi` (192.168.8.1/24, `wlan0`)
  is the hotspot. Split 2026-10-13 so the device stops advertising itself as router/DNS to the PC
  on the other end of the cable -- see `opt/mu300/bin/net-split`.
* cfg80211 refuses to bridge `wlan0` ("Device does not allow enslaving to a bridge") because `IFF_DONT_BRIDGE` stays set:
  the SC2355 driver marks the interface as AP but returns an error from `change_virtual_intf` when tearing down the
  previous firmware mode fails, so cfg80211 skips clearing the flag. `kernel/patches/wlan_combo-allow-bridging-ap.patch`.
* After moving modules, delete old copies: `depmod` indexes every subdirectory and `modprobe` loaded stale drivers from
  an `extra.old/` directory for several boots.

### 22. Regulatory database
* This 5.4 kernel only has the `sforshee` regdb certificate; current `wireless-regdb` is signed by `wens`, so
  `iw reg reload` fails with `-ENODATA`, the domain stays `00` and 5 GHz is `NO-IR`. Android's own `regulatory.db` is
  signed by a different certificate and is rejected too. `kernel/patches/regdb-wens-certificate.patch` adds mainline's
  `wens.hex`. cfg80211 tries to load the database before the rootfs is mounted, so userspace runs `iw reg reload` first.

### 23. Only one AP; 5 GHz AP needs the DS Parameter Set element
* `iw list`: `#{ managed, AP } <= 1` — only one AP interface, so 2.4 and 5 GHz cannot be served simultaneously.
* Symptom: with hostapd on channel 36 the firmware answered `CMD_START_AP` with `SPRD_CMD_STATUS_NOT_SUPPORT_ERROR`
  (HT/VHT), or accepted it and never sent beacons (non-HT), for every country, channel, rate set and HT/VHT/PMF setting
  tried. Android's SoftAP on the same firmware runs on 5180 MHz with 80 MHz.
* Stock (ZTE) and realme `sc2355_start_ap` are identical, so the command payload was captured on Android with a kprobe
  on `sc2355_send_cmd_recv_rsp` (`msg->data` at +24, command id at data-11). Android's beacon contains a DS Parameter Set
  element (`03 01 24`) on 5 GHz — Unisoc's hostapd adds it — while upstream hostapd only adds it on 2.4 GHz. The
  firmware takes the AP channel from that element.
* `kernel/patches/wlan_combo-5ghz-ap-ds-params.patch` inserts the element when hostapd omits it. Verified: 802.11a/n/ac
  AP on channel 36 at 80 MHz (seen by a client, disappears when hostapd stops). The firmware offers 5 GHz AP only on
  36-48 and 149-165 (its ACS channel list); `hotspot-start` uses HT40/VHT80 there, and `hotspot-verify` still falls back
  to 2.4 GHz if the firmware refuses.
* The wiphy rate table lists HT MCS rates as legacy bitrates, so hostapd advertises odd "extended rates" (some with the
  basic-rate bit); Android does the same and the firmware ignores them.
* hostapd's 20/40 MHz coexistence scan (`HT_SCAN`) completes on this driver; the log line after it can lag because
  hostapd's stdout is block-buffered.
* The stock driver prints the SoftAP passphrase to the kernel log (`vendor_softap_convert_para`); Android `dmesg`
  captures contain it.

### 26. Modem resets and mobile data recovery
* The modem firmware occasionally resets: it sends an smsg (type 12, "channel 0 not opened" on the AP side),
  `sipa_delegate: modem_reset`, and `modem_control` stops and reloads the modem through Trusty. It comes back with
  `+CFUN: 0`, no registration and no PDP context, while `sipa_eth0` keeps its stale address, so clients lose internet.
  Android's RIL reconnects silently.
* `mobile-data watch` (procd instance `cellwatch`, started by `mu300-post`) no longer polls `AT+CGACT?`: the live data
  call holds the AT channel (`/dev/stty_nr1`), so the watchdog must not touch it. It judges the link by *reachability*
  instead. While idle (every third cycle, ~90 s) it sends ICMP probes to the carrier DNS plus 223.5.5.5/119.29.29.29;
  moving packet counters count as proof of life without probing at all, which both saves the probe and avoids false
  alarms where the carrier drops ICMP. Three consecutive failures make it repair with `ifdown`+`ifup` -- plain `ifup`
  is a no-op while netifd still believes the interface is up, which is exactly the failure seen in practice ("fake
  alive": address present, operstate `up`, `tx +0 rx +0`), rate-limited to one repair per 10 minutes; three failed
  repairs trigger one `sim-reset`. It publishes `/tmp/mu300-wan-health` (`ok|dead` + uptime) so the status page can
  report red instead of a green lie. `mobile-data down` sets `/run/mu300-mobile-data-down` so a manual disconnect is
  respected.
* Last resort (2026-10-13, commit `6c6fe97`): some wedges survive both the repair and `sim-reset` -- after
  `SIPA_RM` released the WWAN bearer, or after a 6-stream 279 Mbps burst, `mobile-data up` hangs in `do_select` and
  the cellular AT channel goes silent (bare `AT` unanswered, while the WCN `atcmd` attribute still answers `rc=0`,
  i.e. it is the cellular AT channel that died, not WCN). Only a reboot recovers it. `watch` now reboots when all
  four hold: health `dead` for >=300 s, a repair in flight for >=60 s (i.e. repairs are not helping), a bare `AT` on
  `/dev/stty_nr1` going unanswered, and this boot has not rebooted yet (`/var/run/mu300-wan-rebooted`; `/var` is
  tmpfs, so the marker is per-boot for free). The probe refuses to send AT at all while `$IFACE` still holds an
  address, which keeps the "never put AT traffic on a live data call" rule. Verified against a stubbed copy with the
  thresholds lowered: it fired exactly once, at the cooldown plus threshold, and never again.
* Verified by switching the radio off: data returned without intervention.

### 27. Where the missing ~550 MiB of RAM goes
* `Memory: 1430144K/2097084K available ... 617788K reserved`. The device tree reserves 464 MiB for the modem firmware
  (`cp-modem@88000000`, needed for 4G/5G), 24 MiB for Trusty (`tos-mem`), 8 MiB SIPC shared memory, 3 MiB DDR training
  data and a few small areas; the kernel image (~35 MiB) and the page tables for 2 GiB (~32 MiB) make up the rest.
  `cma_share` (48 MiB) is still usable for movable pages.
* Not needed on Linux: `logobuffer` (9 MiB) and `sysdump-uboot` (16 MiB, bootloader crash dumps). `logobuffer`
  was skipped on the belief that there is no display — that belief was wrong (2026-10-13: the internal MIPI panel
  is fully described in the live DT and now driven by our own `sprd-drm.ko`), but the reservation is still not
  needed, because OpenWrt drives the panel through DRM instead of the Android logo buffer.
  `kernel/patches/of-reserved-mem-skip.patch` adds `CONFIG_OF_RESERVED_MEM_SKIP` (the boot image command line is not
  passed on by LK, so a cmdline option alone would not work); MemTotal grew from 1447 to 1473 MiB.
* `mu300-zram.service` adds lz4 zram swap of half the RAM (swappiness 100).


### 28. Mali-G57 GPU (OpenCL) without Android
* The stock `mali_kbase.ko` (DDK r40p0) does not load: 166 of its 335 imported symbol CRCs differ from this kernel.
  realme's `kernel_modules` master branch has the same DDK (`gpu/natt/mali`, r40p0-01eac0, UK 11.36, platform
  `qogirn6pro`); an older checkout of the tree has r34p0 (UK 11.31), which Android's r40p0 userspace would not accept.
  `kernel/build-mali.sh` builds it; it probes `23140000.gpu` as "arch 9.0.9 r0p1" and creates `/dev/mali0`.
* Userspace is Android's `libGLES_mali.so` (it is also `libOpenCL.so` and the Vulkan ICD), a bionic library with a
  37-library closure (VNDK apex, bionic, gralloc/mapper HIDL stubs). It runs in the existing vendor chroot with
  `LD_LIBRARY_PATH` covering vendor, egl, VNDK and bionic; `/dev/ion` is enough for OpenCL buffers.
* Test programs are built for bionic with plain clang (`--target=aarch64-linux-android29`, linked against the device's
  `libc.so`/`libdl.so`/`libOpenCL.so`) and a small `_start` that calls `__libc_init` (`tools/gpu/`), so no NDK is needed.
  `android-gpu-run /system/bin/cltest`: "OpenCL 3.0 v1.r40p0-01eac0", device "Mali-G57 r0p1", 4M-element kernel
  verified correct.
* GLES/Vulkan are only usable off-screen, since there is no GPU compositor wired to the panel. The driver adds
  about 45 MiB of memory use. (The panel itself does exist and is driven — see the display correction above.)

## OpenWrt

### 29. OpenWrt 25.12 next to Ubuntu
* Layout: the ext4 area holds `/openwrt` (and `/ubuntu`, or Ubuntu directly in the root on first installs);
  `/.mu300/boot-os` selects the system and `init` starts `/lib/systemd/systemd` or procd's `/sbin/init`. The disk stays
  mounted at `/mnt/mu300-disk`; `mu300-os ubuntu|openwrt` switches. `openwrt/build-rootfs.sh` builds the rootfs from the
  official armsr/armv8 tarball (checksum-verified) with apk, our kernel modules flat in `/lib/modules/<release>`
  (ubox kmodloader), the vendor chroot and procd services (`mu300-vendor`, `mu300-hw`, `mu300-post`).
* Cellular WAN is a netifd protocol (`proto mu300cell`, option `apn`), so LuCI/fw4 handle routing, DNS and NAT;
  `mobile-data watch` keeps it honest -- ICMP probes plus a health file, `ifdown`/`ifup` repairs, a `sim-reset` after
  three failures, and a once-per-boot reboot as the last resort (see 26).
* Pitfalls found on the device:
  * procd mounts `/dev` as a 512 KiB tmpfs: copying the 85 MiB Android property area gives empty files and
    `modem_control` never boots the modem (power cut at ~290 s). The property area is now bind-mounted (also on Ubuntu,
    saving the RAM).
  * procd preloads `/lib/libsetlbf.so` into services; the chroot runners unset `LD_PRELOAD` or the bionic linker fails.
  * `ujail` drops capability 38 (CAP_PERFMON), unknown to 5.4, so jailed services crash-loop; `procd-ujail` is removed.
  * OpenWrt's busybox lacks `od`, `timeout`, `losetup`, `telnetd`; the static busybox provides them, plus a tiny
    `mountpoint` script (neither busybox has it).
  * GNU `stty` fails on the modem tty ("unable to perform all requested operations"); it is non-fatal now.
  * `wifi`/netifd wireless handlers are in `wifi-scripts` (with `iwinfo`, `wireless-regdb`), not pulled in by `wpad`.
  * macOS keeps the ECM link inactive after netifd reconfigures `usb0`; a hotplug hook re-enumerates the gadget on every
    LAN ifup.
  * The kernel had no nftables sets (`CONFIG_NF_TABLES_SET`), so fw4's ruleset (`ct state vmap {...}`) was rejected as a
    whole and there was no NAT; the fragment now enables sets, objref, flow offload, redirect, quota and friends.
  * OpenWrt's `regulatory.db` is unsigned; this kernel wants the signed one (Debian's `wireless-regdb`).
  * cfg80211 requests `regulatory.db` at 1.6 s, before the rootfs exists; the direct load fails and the request sits in the
    sysfs firmware fallback for 60 s (no userspace helper answers it, neither on OpenWrt nor with systemd-udevd), and
    `iw reg reload` returns ENOENT meanwhile. `regdb-load` answers the pending requests through `/sys/class/firmware`,
    then reloads; the country is applied before netifd starts hostapd.
  * Attended sysupgrade ("Check online for firmware upgrades") and `sysupgrade` would flash a whole-disk armsr image
    (own GPT, kernel 6.12) over the eMMC and brick the device. The packages are removed and `/sbin/sysupgrade` only allows
    configuration backups.
  * `wifi-scripts` generates an open "OpenWrt" network on first boot; `openwrt-wifi-config` replaces it once (marker
    `/etc/mu300/wifi-configured`) with the imported SSID/WPA2 settings.
* Verified after reboots: 5 GHz AP (channel 36), cellular WAN, a USB client's traffic leaves with the modem's public IP;
  memory use about 140 MiB.
* The early recorder runs from preinit, so a failed OpenWrt boot leaves dmesg, `ps`, `logread` and the Android logcat in
  boot_b for `tools/collect-logs.sh`.


### 30. Installer notes
* Android's `/system/bin/sh` (mksh) does 32-bit arithmetic: byte offsets of the Linux region (27 GiB) overflow, so the
  device script works in sectors. mksh also lets a failing EXIT trap replace the exit status; the installer checks for an
  explicit success line instead.
* `adb shell`/`exec-out` read stdin and swallow answers piped into a script; every call uses `</dev/null`.
* Android restarts once shortly after booting back from a Linux fallback; start the installer when Android has settled.
* A first-generation install (Ubuntu directly in the filesystem root) is replaced by `/ubuntu`; `init` still boots the
  old layout if no `/ubuntu` exists.

## IPv6

### 31. Nothing solicits, so nothing arrives (the bearer, China Mobile, 5.4.254)
* Symptom: the bearer has an IPv4 address and no IPv6 at all, on a SIM whose APN is dual-stack.
* The PDP context is **not** the problem. `AT+CGDCONT?` already reports `IPV4V6` (the configured APN is
  empty, so the network default `cmnet` applies) and `AT+CGCONTRDP=1` does carry IPv6 fields -- but its
  address field holds the interface identifier with the prefix zeroed (`::18dd:fcd3:369a:2978`), which is
  why reading the prefix out of AT looks like "this carrier delegates nothing". The prefix exists; it is
  only ever in a router advertisement.
* The carrier sends no unsolicited advertisement. It answers a router solicitation -- and on a plain
  kernel nothing sends one, because `net.ipv6.conf.all.forwarding=1` (needed for the hotspot) makes each
  interface's `accept_ra` default to 0, and this bearer is configured by nothing: it is a raw-IP link
  (`sipa_eth0`, arptype 519), so netifd has no IPv6 protocol handler on it.
* Which step actually emits the solicitation, measured with a capture on the bearer (all three tried on
  the same live bearer):

  | step | solicitations sent | advertisement |
  |---|---|---|
  | `accept_ra` 0 -> 2 alone | 0 | none |
  | `disable_ipv6` 1 -> 0, `accept_ra` already 2 | 2 | back in 57 ms |
  | addrconf restart, **then** `accept_ra` 0 -> 2 | 0 | none |

  The third row is the trap: the address-configuration restart schedules the solicitation, and writing
  `accept_ra` afterwards cancels it -- silence for another 30 s, which is easy to misread as "this SIM
  has no IPv6". So the order is `accept_ra` first, restart second, nothing after.
* Fix: `proto mu300cell` (`openwrt/overlay/lib/netifd/proto/mu300cell.sh`, option `ipv6 'relay'`). The
  address and the RA default route are then installed by the kernel's own SLAAC -- nothing is reported
  to netifd, and odhcpd reads the advertisement off the wire rather than out of netifd's records.
* Lifetimes are infinite (address `valid_lft forever`, router lifetime ~18 h), so an address, once
  learnt, is never renewed or expired. That is why the setup **flushes** the bearer's IPv6 on every dial:
  after a renumber the old prefix would otherwise stay configured for the life of the boot. Verified by
  forcing a teardown/setup: the advertisement returned on its own, with a different prefix.

### 32. Sharing that prefix with the hotspot: relay, NAT66, and one /64 route
Three separate things have to be true, and each fails invisibly on its own:

* **Relay.** odhcpd needs `dhcp.wan` as `master` (the interface that owns the bearer, so the carrier's
  RS/RA are picked up there) and the hotspot as `ra 'relay'` / `dhcpv6 'relay'`. The hotspot then gets an
  advertisement built by odhcpd, measured on the wire:

  ```
  fe80::.. > ff02::1: ICMP6, router advertisement
    hop limit 0, Flags [other stateful], pref medium, router lifetime 65535s
    prefix info option: 2409:8947:39b:557::/64, Flags [auto], valid time infinity, pref. time infinity
  ```

  So clients SLAAC their own public addresses out of the carrier's /64 and route via the hotspot's
  link-local. Two details worth knowing: the flags are odhcpd's own (the `ra_flags` list in the config
  is inert in relay mode -- here `other stateful` without `managed`, i.e. addresses by SLAAC), and the
  advertisement carries **no RDNSS**, so a client gets no IPv6 resolver from it. That is not a defect
  in practice -- a dual-stack client resolves over its IPv4 resolver, and AAAA over IPv4 is ordinary --
  but it means IPv6 is not deployable to a client that has no other resolver.
* **NAT66.** The carrier routes the single address it assigned and would drop a reply addressed to a
  client, so the wan zone needs `masq6` (`net-split` sets it). Proven on the wire rather than inferred:
  with a client on the hotspot, every echo request on the bearer leaves with the **bearer's** address as
  source, never the client's, and the replies come back to the bearer.
* **A route to the LAN.** None exists by default: `mu300cell` flushes the bearer's IPv6 routes on setup,
  so a lookup for a client address falls through to the default route and the reply leaves via the modem
  towards the carrier gateway, where it disappears. `ndp-learn` installs the bearer's /64 on the hotspot
  bridge at metric 128 -- below the RA's own route for the same /64 on the bearer (metric 256) -- and
  follows a renumber. NDP then resolves each client on demand, with no race for addresses that never
  appeared in the neighbour table. Upstream's extra `/128` pins per neighbour entry are deliberately
  left out: any host creates such an entry with one spoofed advertisement, and it would pin an unrelated
  address (another client's, the router's own, an internet host's) to the LAN -- a route hijack.
* The first solicitation from a brand-new client is answered only after it retransmits ~4 s later
  (measured 65 ms after the retransmit); the interface is registered with odhcpd a moment after it comes
  up. Every client retransmits, so this costs nothing, but a single-shot probe would call the relay dead.
* A netifd **reload does not restart an interface whose protocol options changed** (measured: after
  adding `network.wan.ipv6` the wan kept its original uptime and its IPv4-only state), and the relay
  branch runs only on setup. A boot or a fresh install is fine -- the interface is configured after the
  config lands -- but an install that is already up needs one re-attach, which is what `net-split --apply`
  now does (guarded by the bearer having no public address, so it fires at most once per install).
* The IPv6 split follows the IPv4 one: the USB management link (`br-lan`) gets no router advertisement
  and no DHCPv6, because a second default route on the PC's management link outranks its real uplink
  (see `### 21` and `net-split`). Only the hotspot relays.
* **Not verified: IPv6 over the Wi-Fi radio.** The client used above is a veth in a network namespace on
  the bridge -- a real forwarded client, but not one crossing the WiFi driver. Upstream records IPv6
  TCP/UDP from Wi-Fi clients failing on 5.4 where it works on 6.18, with this port's
  `wlan_combo-rx-software-checksum.patch` (unconditional `CHECKSUM_NONE`) as the only difference in that
  path. Until a real Wi-Fi client is tested, that remains open.
* **The device cannot test this itself, and that is a hardware property**: `iw phy` reports
  `#{ managed, AP } <= 1` -- one managed-or-AP interface, so an `AP + STA` self-loop (join your own
  hotspot and bounce packets through the radio) is not possible on Marlin3 with this driver. A second
  physical client is the only way to cross the radio. Worth knowing before planning any air-interface
  test: there is no self-contained variant.
* The upstream RX-hang fix (`6519748`, "Wi-Fi RX no longer hangs the device under load") does **not**
  apply here, and it is worth knowing why rather than backporting it blind: the vendor's
  `mm_check_mh_buffer()` refreshes an RX buffer with `dma_sync_single_for_device()`, which on arm64
  *invalidated* FROM_DEVICE buffers up to 5.19 and *cleans* them from then on. On 6.18 that left the CPU
  reading a stale cache line, so every check failed and the machine hung under load; on 5.4 the call
  still invalidates, i.e. it does what the loop wants. The 5.4-side companion (`294deb8`, which added the
  software-checksum patch) is already in this branch. Fixing 6.18 meant a different call, not a different
  intent.

### 33. The veth-on-the-bridge test client panicked the kernel (and where the evidence lived)
The teardown half of the test in `### 32`, not its traffic, killed the machine. The boot came back with
`bootcause="Reboot into ap watchdog"`, which is what a panic looks like from the outside (sprd's hardware
watchdog resets the SoC), so the first thing worth knowing is where the real story is kept:

**`/sys/fs/pstore/console-ramoops-0` survives the panic.** On a Unisoc boot the kernel is built with
ramoops (`ramoops: using 0x40000@0xfff80000`), and pstore keeps the *previous* boot's console -- read it
on the boot after a death and you get the Oops verbatim, timestamps and call trace included. The port's
own `early-recorder` (`/opt/mu300/bin/early-recorder`) writes to a region inside `boot_b` every 5 s for
the first 300 s, which is the right tool for a *power cut*, but it stops long before a crash hours later
and this boot's writes overwrite it byte for byte -- so for a panic, **pstore first**:

```sh
for f in /sys/fs/pstore/*ramoops*; do echo "== $f"; cat "$f"; done
```

What it said, in the dead boot's last 30 ms:

```
[ 1336.712180] Unable to handle kernel paging request at virtual address e399ba28ab68c7c5
[ 1336.720979] Internal error: Oops: 96000004 [#1] PREEMPT SMP
[ 1336.768197] Workqueue: events_unbound call_usermodehelper_exec_work
[ 1336.781174] pc : kmem_cache_alloc_trace+0xc4/0x398
[ 1336.116387] Call trace:
              kmem_cache_alloc_trace+0xc4/0x398
              __get_vm_area_node.llvm...  -> __vmalloc_node_range -> scs_alloc -> scs_prepare
              dup_task_struct -> copy_process -> _do_fork -> kernel_thread
              call_usermodehelper_exec_work -> process_one_work -> worker_thread -> kthread
[ 1338.278671] Kernel panic - not syncing: Fatal exception
[ 1338.329889] Unable to handle kernel paging request at virtual address dead000000000100   # LIST_POISON
```

So the fault is not in the packet path at all: it is in **`fork()`** -- a corrupt pointer is taken while
allocating the Shadow Call Stack for a new task -- on `kworker/u16:3` running a usermode helper, i.e. a
netdev uevent turned into a `/sbin/hotplug-call`. Two things make the neighbourhood obvious:

* Every `sipa_dummy: dev ... evt ...` line in that boot (8 of them, and *only* these) belongs to the
  test's veth peer `v6cp`, all inside the same window, and the set includes `evt 1` / `evt 14`
  (`NETDEV_UP` / `NETDEV_PRE_UP`) -- the signature of a namespace being torn down and its devices
  re-registered into init_net, plus `device v6cp entered promiscuous mode` and `dev br-wifi evt 12/9/8`
  as the bridge re-evaluated its port.
* Nothing else was cooperating at that moment: the same boot had logged no `sipa_dummy` line at all
  before it, and this is the only new netdev in it.

The precise ordering cannot be nailed down from a ring buffer shared by eight CPUs (the first fault is
stamped 12 ms *before* the v6cp lines, which another CPU printed concurrently), so the honest statement
is: **the panic happened during the run whose netdev churn is the only unusual event in that boot, and
has not happened in any boot without it.** The suspect, if someone wants to chase it, is the vendor
`sipa`/`sipa_dummy` netdev-notifier path running against a device it does not own (`v6cp` is a plain
veth), corrupting the slab for whoever allocates next.

Practical rules that come out of this:

* **Do not put test clients on the bridge on this device.** A real phone joining the hotspot does not add
  or remove a bridge port; the AP served client traffic for days without this. The tool is bench
  equipment with a hazard, and `tools/net-v6-client-test.sh` now opens with that warning. It is not the
  verification to reach for first -- a real Wi-Fi client is both the safer and the more meaningful test.
* The panic, if it comes, comes within seconds of the run. Leave the phone alone afterwards rather than
  retesting immediately.
* `bootcause="Reboot into ap watchdog"` in `/proc/cmdline` means *the watchdog reset it*, not *the
  watchdog timed out* -- a panic looks identical from there. Read pstore before blaming the modem, SIPA,
  or anything the log happened to be printing at the time.

### 34. The SIPA delegate had no peer timeout (the wedge that only a reboot cured)

The "WAN goes dead but stays up" failure finally has a cause and a fix. It is not the bearer, not the
route, not the CP's data path: it is a *missing timeout* in the SIPA delegator, one layer below all of
the watchdogs added for it in §26.

Symptom, unchanged from every previous report: `sipa_eth0` keeps its address, `operstate` stays `up`,
`ip route` has the default, and not one packet passes (v4 100 % loss; v6 `sendto: No buffer space
available`). `mobile-data watch` cannot repair it -- its only cure was the last-resort reboot
(`6c6fe97`), and the CP's AT channel is dead in this state too, so even that guard had to wait for the
AT probe to go silent before it would act.

**The signature.** `/sys/kernel/debug/sipa/rm_res` on a wedged device (2026-10-13, uptime 605 s):

```
[res] name = SIPA_RM_RES_PROD_IPA    type = 0 ref_count = 1 state = 2   granted   -- IPA is fine
[res] name = SIPA_RM_RES_PROD_CP     type = 0 ref_count = 1 state = 1   REQUEST_IN_PROGRESS, stuck
[res] name = SIPA_RM_RES_CONS_WWAN_UL type = 1 ref_count = 0 state = 3  RELEASE_IN_PROGRESS, stuck
```

dmesg, in order:

```
605.530121  sipa_rm: calling driver CB
605.530229  sipa_rm: driver CB returned with -115          <- -EINPROGRESS, "not yet", not an error
605.530236  sipa_rm: SIPA_RM_RES_PROD_CP state changed 0->1
605.530257  sipa_eth: fail to send, ret -115
605.535504  sipa_eth: stop queue on dev sipa_eth0
605.535870  sipa_dele: smsg_send, dst=5 chan=120 type=5 flag=1   <- request goes out ...
<nothing>                                                        <- ... and is never answered
608.530877  sipa_rm: SIPA_RM_RES_CONS_WWAN_UL state changed 1->3
```

The 3 s gap is `sipa_nic`'s `SIPA_NIC_RM_INACTIVE_TIMER`: having got no grant, the nic releases the
consumer. But a consumer can only finish releasing once all its producers are granted, and `PROD_CP`
is stuck, so `CONS_WWAN_UL` parks in RELEASE_IN_PROGRESS and the TX queue is never woken again.

**Why it latches.** `sipa_dele_local_req_r_prod()` returns `-EINPROGRESS` for as long as its `stat` is
`SIPA_DELE_REQUESTING`, and only a `DONE` from the peer -- or a failed `smsg_send` -- ever leaves that
state. Nothing in the tree has a timeout there. A peer that stops answering therefore freezes the
producer for the rest of the boot, and every consumer depending on `PROD_CP` waits forever.
`sipa_dele_reset` (`echo 1 > /sys/kernel/debug/sipa/sipa_dele_reset`) does **not** help: its
`cp_dele_restart_handler()` powers SIPA down and drops `CONS_WWAN_DL`, but it never touches the
delegator's `stat`, so `PROD_CP` stays in REQUEST_IN_PROGRESS and `CONS_WWAN_UL` stays latched. That is
why rebooting was the only cure.

Note the trigger is on the CP side: when this happens the CP's AT channel is dead as well, so the peer
is not merely dropping SIPA messages, it is gone. Nothing on the AP can make it answer; what the AP
*can* do is stop treating "no answer" as "wait forever".

**The fix** -- `kernel/patches/sipa-delegate-peer-request-timeout.patch`. Arm a 2 s `delayed_work`
whenever the delegator enters `REQUESTING` (request, retry, re-open, request-after-release) or
`RELEASING`; on expiry, take the request back with `sipa_rm_notify_completion(SIPA_RM_EVT_FAIL,
prod_id)` -- the vendor's own give-up signal, already used when `smsg_send` itself fails. The unwinding
is then entirely vendor code:

```
FAIL -> producer_handle_cb      -> PROD_CP RELEASED, notify consumers
     -> consumer_handle_cb(FAIL)-> sipa_rm_resource_consumer_do_release(CONS_WWAN_UL) -> RELEASED
     -> sipa_nic_rm_notify_cb   -> sipa_nic_rm_res_reinit() (true while NIC_OPEN) -> clears rm_flow_ctrl
     -> SIPA_LEAVE_FLOWCTRL     -> netif_wake_queue(sipa_eth0)
     -> next TX re-requests from RELEASED -> a fresh smsg CMD to the CP
```

So the bearer retries instead of latching, and if the CP ever comes back it heals itself with no
reboot. Details worth keeping:

* 2 s is ~250x the peer's normal round trip (5-8 ms observed in the same log) and deliberately below
  the nic's 3 s inactivity timer, so the failure is reported *before* the nic gives up on its own.
* The work sits on `system_wq`, not the delegator's own `smsg_wq`: that queue is single-threaded and
  `smsg_send(..., -1)` can block in it forever, which would make the timeout itself un-timeoutable.
* Every path that legitimately ends a request cancels it (`GRANTED`, `RELEASING`-completion,
  `on_close`), and a `SMSG_VAL_DELE_REQ_FAIL` retry re-arms with a fresh budget rather than inheriting
  a nearly-expired one.

**Verified:** built and deployed as `sipa-dele.ko` (`md5 8bb307a017a9ecd716b552aae837f9eb`, device copy
backed up at `/root/sipa-dele.ko.orig`), reboot, WAN healthy (ping 0 % loss, `rm_res` cycling
0->1->2->0 exactly as before, normal request granted in ~8 ms) and **zero `peer silent` lines after a
6-flow/40 s load test** -- so the timeout does not fire in normal operation. **The recovery itself has
not been observed end to end**: the wedge has no on-demand trigger, it has to come from the CP going
mute. The way to catch it is to wait for the next natural one and watch `rm_res` plus
`dmesg | grep "peer silent"`. The deterministic alternative is to stop the CP on purpose through
`/dev/modem` (`MODEM_STOP_CMD` / `MODEM_UNCONDITIONAL_STOP_CMD`, which are not comm-gated the way
`MODEM_ASSERT_CMD` is, then `MODEM_START_CMD`) -- that cuts cellular for a few minutes and may need a
reboot, so it is a deliberate test, not a background one.

**What this does not fix:** the CP going mute in the first place. The patch converts a permanent latch
(reboot-only) into a bounded retry loop that recovers on its own when the peer returns. The reboot
guard in `mobile-data watch` stays as the backstop for the case where the peer never returns.

**Upstream survey (2026-10-13, `gh` only).** Nobody has fixed this, and nothing upstream contradicts
the approach:

* The runtime request path has *no* timeout anywhere in any UMS9620 tree. In
  `drivers/net/sprd/sipa_v3/sipa_priv.h:53` the vendor even wrote `#define SIPA_RM_REQUEST_TIMEOUT
  (1 * HZ)` -- and it is a **dead macro**: grep finds the definition and no use. `SIPA_RM_MAX_WAIT_TIME
  (HZ * 10)`, the only other one, is used solely by `sipa_rm_add_dependency_sync()` at boot. So the
  intent was there and was never wired up; our timeout is that intent, put where the wait actually
  happens.
* `dikeckaan/zte-ums9620-kernel-5.4.254` has exactly one commit touching `sipa_v3` (`b07050f10a first
  upload`) -- a pristine vendor mirror. `SIPA_WWAN_CONS_TIMER` and `SIPA_NIC_RM_INACTIVE_TIMER` are
  identical across the ZTE ums9620 trees (Enceka f50/u30air, Ssrml p720_w205ds, liuwang97 f50), and no
  repo anywhere exposes either as a module parameter or sysfs knob. Issue searches for `sipa_rm -115`
  / `sipa_dele` turn up nothing about this hang.
* The only upstream sipa_delegate patches are *load-time* ones (kanoqwq `eb5336875c` / dikeckaan
  `1cee306e7e`, `sipa-delegate-einprogress.patch`): tolerate `-EINPROGRESS` from
  `sipa_rm_add_dependency()` during probe, `devm_kzalloc` -> `kzalloc`, check
  `sipa_delegator_start()`'s return. Nothing about the runtime state machine.
* The vendor's one recovery lever is the `sipa_dele_reset` sysfs node (see above) -- which does not
  reach the delegator's `stat`, hence not this bug. `sprd-linux-devs/e5-linux` `4de42b4115` ("bearer: a
  watch that brings it back after a CP reset") is the same layer of idea in userspace: react to a CP
  reset rather than wait forever.
* **The strongest corroboration** is `dikeckaan/mu300-linux`'s `docs/reference/android-ipa-state.txt`,
  a capture of stock Android on this hardware: it shows the identical sequence -- RM idle release ->
  "ready to suspend and change to single" -> `driver CB returned with -115` -> `sipa_eth: fail to
  send, ret -115` -- **and then Android recovers 2.2 ms later, because the CP answers on chan 120**.
  So `-115` is normal, not a bug; the only thing missing is a fallback for when the CP does not answer.
  That is exactly what the 2 s timeout adds, along the `SIPA_RM_EVT_FAIL` path the state machine already
  has.

## Audio

### 24. No internal audio hardware
* The DT enables a sound card, the UMP9620 codec and an AW883xx amplifier at `6-0034`, and Android disables audio.
  With `i2c-dev`, nothing answers at 0x34 (nor at the bq2560x address 0x6b), and there is no AGDSP firmware partition.
  The board has no speaker path; only Bluetooth or USB-host audio devices are possible.
* Update: community Android modules show the audio DSP itself is usable. The F50 DT has `audiocp_boot` and `sound@0` but
  no `audio-mem`/`audiodsp-mem` reserved memory (another UMS9620 device uses 0xaf700000 3 MiB and 0xafa00000 6 MiB).
  Their flow loads an AGDSP image taken from a different device into `/sys/devices/platform/audiocp_boot/agdsp`
  (`stop`, write, `start`), binds `sound@0` to `vbc-rxpx-codec-sc27xx`, and gets a `sprdphone-sc2730` card with Bluetooth
  SCO call audio. The Unisoc ASoC/AGDSP driver sources are in the realme `unisoc-5.4` kernel_modules tree; porting this
  to Linux is future work (A2DP over BlueZ does not need the DSP).

## Bluetooth

### 25. SC2355 Bluetooth on BlueZ
* Transport: `sprdbt_tty` (realme `wcn/bluetooth/driver/tty-pcie`, built with `BSP_BOARD_UNISOC_WCN_SOCKET=pcie`) exposes
  an H4 tty `/dev/ttyBT0` over the WCN PCIe link and registers a `bluetooth` rfkill that powers the BT function.
  `btattach -B /dev/ttyBT0 -P h4` creates `hci0`.
* Vendor init (Android `libbt-sprd_suite`, Marlin3): before the stack starts, send `0xFCA0` with the 176-byte PSKey block
  from `bt_configure_pskey.ini` (BD address at bytes 20..25, little endian), `0xFCA2` with the 252-byte RF block from
  `bt_configure_rf.ini`, then `0xFCA1 00 00 01` (dual mode, enable). `tools/bt-init/mu300-bt-init.c` does this. Without the
  PSKey upload the controller reports a fixed placeholder address.
* The firmware advertises Hold Mode and Park State in its LMP features, but `Write Default Link Policy Settings` returns
  `Invalid HCI Command Parameters` for any value that includes them (0x0000/0x0001/0x0004/0x0005 accepted, 0x0007 rejected).
  The 5.4 kernel sets every advertised mode, so the init sequence aborts and `hciconfig hci0 up` fails with `EINVAL`.
  `kernel/patches/bluetooth-marlin3-link-policy.patch` requests only Role Switch and Sniff (Bluetooth is built in, so this
  needs the kernel rebuild).
* Android keeps the real BT address in `/data/vendor/bluetooth/btmac.txt` on encrypted `/data`; Linux uses
  `BDADDR=` from `/etc/mu300/bluetooth.conf` or a stable locally administered address derived from `machine-id`.
* Verified: `bluetoothd` powers the adapter and LE/BR-EDR scanning lists nearby devices.
* Rebuilding with a modified tree appends `-dirty` to the kernel release and breaks module loading; `.scmversion` with
  `-gb50db5b6224c` in the source tree keeps the release string stable.
