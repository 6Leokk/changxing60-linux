# Mainline (LTS) kernel bring-up — experimental, not booting yet

Goal: run a kernel.org LTS kernel (6.18.52) instead of the vendor 5.4 on the MU300.

## What is here
* `Dockerfile`, `build.sh`, `mu300-mainline.config` — minimal arm64 build (allnoconfig + SoC, GIC, timer, Unisoc UART,
  LZ4 initramfs, pstore/ramoops, forced command line).
* `dts/ums9620-mu300.dts` — minimal device tree: 8 CPUs (4×A55, 4×A76), PSCI, GIC-v3, arch timer, full reserved-memory map,
  ramoops, UART1. `sprd,sc-id = "ums9620 1000 1000"` lets LK select it.
* `mkvendorboot.py` — replaces the DTB in `vendor_boot` (Android DT table, magic 0xd7b7ab1e) and keeps the AVB footer
  layout; rebuilding with the original DTB reproduces the stock image byte for byte.
* `wrap-image.py` — LK always copies the kernel to 0x80080000 (text_offset of old kernels); kernels since 5.8 have
  text_offset 0 and need a 2 MiB boundary, so a stub branches 0x180000 forward to run the Image from 0x80200000.
* `init-bringup` — initramfs probe that logs to the kernel log (pstore) and warm-reboots.

## Status (2026-09-17)
* Every slot-b attempt ended after ~320 s (PM co-processor power cut), with nothing in pstore — also with the stock DTB,
  and also when the *vendor 5.4* Image was patched to call PSCI SYSTEM_RESET as its first instruction. A normal reboot
  takes 25 s. So an early warm reset is not available (PSCI reset probably needs the PM firmware that `modem_control`
  loads), every failure ends in a power cut that erases RAM, and the pstore channel only works once the kernel can keep
  the device alive and reset it.
* Upstream 6.18 has only generic Unisoc drivers (UART, SDHCI, SPI/ADI, GPIO, I2C, watchdog, some SC27xx PMIC blocks);
  there is no UMS9620 clock/pinctrl/power-domain driver, no USB PHY/glue, no PCIe glue for the Wi-Fi/BT chip and no
  modem/PM (SIPC) stack. Without the modem_control path the PM watchdog powers the device off after ~290 s.

## Next steps
1. A debug channel: the UART (ttyS1, 0x20210000, 115200 8N1) on test pads, or bare-metal LED/PMIC register writes as
   progress markers.
2. Reset/keep-alive: drive the UMP9620 PMIC watchdog through the ADI SPI bus (register layout from the vendor
   `sprd_pmic_wdt`/`sc27xx` sources).
3. Only then: clocks/pinctrl for eMMC and USB, which would need new drivers.
