#!/bin/bash
# Build the internal-panel display stack as external modules against out-linux (5.4.254).
#
# The device's live device tree (supplied by LK from vendor_boot_b/dtbo_b) already describes the
# panel, the DSI host, the DPHY, the backlight and the display power domain, all status=okay, and
# the running kernel already has the framework config (DRM, MIPI_DSI, DRM_PANEL, KMS_HELPER,
# BACKLIGHT_CLASS_DEVICE, ION, UNISOC_IOMMU, PM_GENERIC_DOMAINS_OF). What is missing is just two
# modules, both absent from the 109-module set the device boots with:
#
#   sprd-drm.ko     ZTE tree drivers/gpu/drm/sprd. The shipped F50 config leaves CONFIG_DRM_SPRD
#                   off (the F50 has no panel). Built here for the internal MIPI panel: DPU0 + DSI,
#                   which pulls in the panel (sprd_dsi_panel.c) and backlight (sprd_bl.c) drivers.
#                   DPU1/DP/DPHY1 are deliberately NOT enabled -- they are the DisplayPort and
#                   external-display paths and nothing in this device uses them.
#
#   sprd-vpu-pd.ko  genpd provider for the "sprd,vpu-pd" node the DPU and DSI hang off. Without it
#                   both defer forever. See ext-vpu-pd/Makefile.
#
# Nothing here touches the kernel image, so the 109 boot modules keep their CRCs untouched.
# Run inside changxing60-kbuild with the changxing60-kernel volume on /src and changxing60-linux/kernel on /work.
set -e
K=/src/zte-u30air
OUT=/src/out-display
# CROSS_COMPILE=aarch64-linux-gnu- is required when the host is x86_64 (route A of
# docs/changxing60/port-design.md), exactly as build-linux.sh does it -- without it clang tries to
# assemble the arm64 inline asm as x86_64 and dies on "unknown register name 'x0' in asm".
M="make O=/src/out-linux ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} -j${JOBS:-$(nproc)}"
mkdir -p $OUT

# ---------------------------------------------------------------- sprd-drm (internal panel)
D=/src/ext-sprd-drm
rm -rf $D && cp -r $K/drivers/gpu/drm/sprd $D
# The in-tree Makefile points -I at $(srctree)/$(src)/../../../devfreq/apsys, which is not where the
# external copy sits; repoint both include paths at absolute locations inside the build container.
sed -i "s#-I \$(srctree)/\$(src)/../../../devfreq/apsys/#-I $K/drivers/devfreq/apsys/#; s#-I \$(srctree)/\$(src)\$#-I $D#" $D/Makefile

# The device tree also carries the DPU1/DPTX external-display path, and dpu1@31880000 is
# status=okay on this board. The component master matches it as a crtc port, but this build has no
# DPU1 driver, so that component can never be added and component_master_add_with_match() would
# wait for it forever: no card0, no panel, and no error in the log pointing at the cause. The
# patch makes the match follow the same config guards the driver registration table already uses.
patch -p1 -N -s -d $D < /work/patches/drm-skip-unbuilt-display-components.patch

# CONFIG_DVFS_APSYS_SPRD=m in the F50 config means apsys_dvfs.h declares
# dpu_dvfs_notifier_call_chain() extern instead of stubbing it inline, and the DPU cores link
# against it -- but apsys-dvfs.ko is not part of the device's module set, so the symbol is
# unresolvable at insmod ("Unknown symbol dpu_dvfs_notifier_call_chain"). Compile the no-op
# straight into sprd-drm; see ext-dpu-dvfs-stub/dpu_dvfs_stub.c for why that is behaviourally
# identical to loading the real one. (Alternative, deliberately not taken: stage apsys-dvfs.ko,
# which would put a voltage-voting subsystem next to the display power domain.)
cp -r /work/ext-dpu-dvfs-stub $D/stub
sed -i "/^obj-\$(CONFIG_DRM_SPRD) += sprd-drm.o/i sprd-drm-y += stub/dpu_dvfs_stub.o" $D/Makefile

cd $K
$M M=$D \
  CONFIG_DRM_SPRD=m CONFIG_DRM_SPRD_DPU0=y CONFIG_DRM_SPRD_DSI=y \
  CONFIG_DRM_SPRD_DPU1= CONFIG_DRM_SPRD_DP= CONFIG_DRM_SPRD_GSP= CONFIG_DRM_SPRD_DUMMY= \
  KCFLAGS="-DCONFIG_DRM_SPRD_MODULE=1 -DCONFIG_DRM_SPRD_DPU0=1 -DCONFIG_DRM_SPRD_DSI=1 -I$D" \
  modules

# ---------------------------------------------------------------- sprd-vpu-pd (genpd provider)
V=/src/ext-vpu-pd
rm -rf $V && cp -r /work/ext-vpu-pd $V
$M M=$V modules

# ---------------------------------------------------------------- collect + verify
# trusty-ipc is a real dependency of the module: CONFIG_TRUSTY_VIRTIO_IPC=m, so the DRM Makefile
# pulls in disp_trusty.o, which opens a TIPC channel to the "com.android.trusty.disp" secure TA.
# The driver itself is dependency-free (every symbol it needs is in vmlinux), which is why it is
# taken straight from the kernel build rather than built separately here.
T=/src/out-linux/drivers/trusty/trusty-ipc.ko
# pwm-sprd is the other dependency-free one, found the hard way: the DT backlight node has a
# "pwms" phandle into 64030000.pwm, so sprd_backlight_probe() blocks in devm_pwm_get() until the
# PWM controller has a driver. With pwm-sprd absent that deferral never resolves, the backlight
# never registers, and the DPU and panel defer behind it ("backlight is not ready") -- the panel
# stays dark with no obvious cause.
P=/src/out-linux/drivers/pwm/pwm-sprd.ko
for f in $D/sprd-drm.ko $V/sprd-vpu-pd.ko $T $P; do
    llvm-strip --strip-debug -o $OUT/$(basename $f) $f
done

echo "=== built ==="
ls -la $OUT
echo "=== modinfo ==="
for f in $OUT/*.ko; do
    echo "--- $(basename $f)"
    strings $f | grep -E '^(vermagic|name|license|depends)=' || true
done
