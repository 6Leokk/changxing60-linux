# Mainline (LTS) kernel on the MU300 — boots to userspace

Mainline **Linux 6.18.52** boots on the ZTE F50 / MU300 (Unisoc UMS9620): all 8 CPUs (4×A55, 4×A76), GICv3, arch
timer, PSCI 1.0, 1.5 GiB RAM, pstore/ramoops, initramfs `/init`, and reboot through the UMP9620 PMIC.

Reference: Unisoc's UMS9620 DT series (LKML, 2023-12-15, "arm64: dts: sprd: Add support for Unisoc's UMS9620", not
merged) describes the same GIC/UART/timer layout; this device is derived from their ums9620-2h10 reference board.

## How it boots
* **Device tree:** the stock vendor DTB in `vendor_boot` is used unchanged. Mainline ignores the vendor-only nodes and
  uses the standard ones (cpus, psci, GIC, timer, memory, reserved-memory, ramoops, ADI). A minimal custom DTB
  (`dts/ums9620-mu300.dts`, installed with `mkvendorboot.py`) was *rejected*: after LK's dtbo merge and fixups the kernel
  hung in `setup_machine_fdt`.
* **Load address:** LK always copies the kernel to 0x80080000 (old text_offset); `wrap-image.py` prepends a branch stub
  so the Image runs from 0x80200000 (2 MiB aligned).
* **Reset:** PSCI SYSTEM_RESET never returns on this firmware. `patches/0001-spi-sprd-adi-add-UMS9620-restart.patch`
  adds the UMS9620/UMP9620 variant to `spi-sprd-adi` (also matching the vendor compatible `sprd,qogirn6pro-adi`) and
  resets through the PMIC software reset, registered above the PSCI handler.
* **Logs:** with a working reset the console survives in ramoops and Android shows it as
  `/sys/fs/pstore/console-ramoops-0` (`tools/collect-logs.sh`).

## Build and test
```sh
docker build -t mu300-mainline-build upstream/
docker volume create mu300-mainline   # unpack linux-6.18.52 into /src of this volume
docker run --rm -v mu300-mainline:/src -v "$PWD/upstream":/work mu300-mainline-build bash /work/build.sh
python3 upstream/wrap-image.py upstream/out/Image upstream/out/Image.lk
python3 boot/build-boot-image.py --kernel upstream/out/Image.lk --init upstream/init-bringup ... --out boot-mainline.img
boot/flash-trial.sh boot-mainline.img      # slot b only, falls back to Android
```

## Debugging without a console
* `stub/pmic-reset.c`: bare-metal PMIC reset used as the kernel entry — proved that LK reaches our code and that the
  PMIC reset works (30 s cycle instead of the ~320 s PM power cut).
* `debug/install-probe.py` (`MU300_PROBE_STAGE=N` for `build.sh`): resets at a chosen boot stage; the cycle time tells
  whether the stage was reached. This located the custom-DTB hang in `setup_machine_fdt`.

## Missing for a usable system
No mainline drivers yet for UMS9620 clocks, pinctrl, power domains, USB (DWC3 glue + PHY), eMMC clocking, PCIe (Wi-Fi/BT),
or the modem/PM (SIPC) stack. Without `modem_control` the PM co-processor powers the board off after ~290 s.
Next: USB gadget (console/network) and eMMC, which need clock/PHY drivers ported from the vendor 5.4 tree.
