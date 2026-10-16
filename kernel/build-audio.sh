#!/bin/bash
# Build Unisoc's ASoC/AGDSP driver set against the 5.4 kernel this project already builds.
#
# These are the drivers behind real call audio: the AGDSP boot/power modules, the MCDT
# transport, the VBC v4 voice DAI, the UMP9620 PMIC codec and the machine card that binds
# the board's sound@0 node ("sprdphone-sc2730"). On this phone Android runs exactly this
# set as out-of-tree modules from vendor_dlkm/lib/modules; our kernel config has
# CONFIG_SND_SOC_SPRD off and does not need it turned on -- the same Kbuilds build
# everything out of tree, which is why this script exists.
#
#   (called by tools/build-audio-54.sh inside the changxing60-kbuild-cross container,
#    with /src = changxing60-kernel volume, /work = kernel/ checkout, /mnt/audio =
#    the realme audio_driver source drop)
#
# Three things about this build are not obvious and cost an evening each (dikeckaan's
# notes, confirmed here):
#
#   * Order matters and one pass is not enough. audio_sipc needs symbols from agdsp_access,
#     the DAIs need the platform, the card needs all of them. Dependencies resolve by
#     building repeatedly and handing every Module.symvers produced so far to the next
#     attempt (3 passes).
#   * A failed attempt has to be cleaned before it is retried. Leftover objects link a
#     second time and the error is "duplicate symbol: __this_module", which says nothing
#     about the real problem.
#   * The UMP9620 codec only compiles with BSP_KERNEL_DEFCONFIG=sprd_qogirn6pro_defconfig.
#     Its Kbuild hides -DCONFIG_SND_SOC_UNISOC_CODEC_UMP9620 behind that, and without it
#     the failure is an implicit declaration of TO_STRING several hundred lines away.
#
# Two directories never build and should not: dmaengine_2stage_pcm and i2s are for older
# Unisoc SoCs (their VBC_DAI_NORMAL comes from the pike2/sharkl3/sharkle headers); our
# generation uses VBC v4.
#
# Patches (kernel/patches/audio-*.patch), applied here idempotently, guarded by a grep:
#   audio-mcdt-enable-clock        MCDT skips every register write when its agcp clock
#                                  enable bit is clear, and on this board nothing sets it.
#   audio-pcm-period-timer         Period events from an hrtimer because the AGCP DMA
#                                  interrupt never arrives on these boards.
#   audio-pcm-pointer-agcp-access  No DMA position read while the AGCP domain is asleep.
#                                  MUST come after audio-pcm-period-timer (its hunk #1
#                                  expects the tick fields that patch adds).
#   audio-fe-dai-formats           The DSP front ends offered only the formats/layouts of
#                                  the DSP; add the host-side ones the ALSA route needs.
#   audio-sprd-card-dummy-on-defer A codec that never arrives must not take the whole
#                                  card down.
# NOT applied, because this phone does not need them (their mu300 F50 board did):
#   audio-mem-fixed-region   Our DT already describes audio-mem@af700000 (0x300000) and
#                            audiodsp-mem@afa00000 (0x600000) via memory-region phandles.
#   audio-mem-shm-shift      Our DT carries our own board's absolute sprd,shmaddr-* values.
set -eu

A=/src/ext-audio
cd /src/zte-u30air

# ---- source drop -----------------------------------------------------------
# Fresh copy every run (tools/build-audio-54.sh mounts the pinned sparse checkout at
# /mnt/audio). A stale /src/ext-audio with half-applied patches would poison the build.
rm -rf "$A"
cp -a /mnt/audio "$A"

apply() { # apply PATCH_DIR MARKER...
    p=$1; mark=$2; shift 2
    if grep -rq "$mark" $A/sprd_audio/mcdt $A/sprd/platform $A/sprd/dai $A/sprd/machine $A/sprd_audio/agdsp_access 2>/dev/null; then
        echo "patch $p: already applied"
        return 0
    fi
    (cd $A && patch -p1 -s -f < /work/patches/$p.patch) || { echo "patch $p FAILED" >&2; exit 1; }
    echo "patch $p: applied"
}

apply audio-mcdt-enable-clock "enabled the agcp mcdt clock"
apply audio-pcm-period-timer sprd_pcm_period_tick
apply audio-pcm-pointer-agcp-access last_pointer
apply audio-fe-dai-formats fe_dai_uses_mcdt
apply audio-sprd-card-dummy-on-defer dummy_on_defer

# ---- what gets built, and why the set looks like it does -------------------
# Android runs 27 audio .ko on this phone (the vendor_boot ramdisk /lib/modules set =
# vendor_dlkm/lib/modules; see docs/changxing60/telephony.md). This build reproduces
# 25 of them from the realme C51/C53 tree, plus 2 this tree has and Android does not
# (snd-soc-sprd-pa-ucp1301, snd-soc-sprd-vaudio: harmless, they bind nothing here).
# The 2 real gaps:
#   * snd-soc-aw87xxx  the speaker PA driver -- NOT in the realme tree, and not in any
#     other source tree we have. Android ships it as a prebuilt that cannot load here
#     (module_layout CRC). The machine card still links because the realme hook file
#     wraps its aw87xxx references in `#if 0` (kallsyms_lookup_name lookups, and that
#     symbol is not exported by our kernel either). Consequence: every non-PA path
#     (earpiece, headset, mic, BT-SCO) builds and binds; the speaker PA stays silent
#     until that driver turns up. Firmware for it exists on the phone (aw87xxx_acf.bin
#     in vendor firmware).
#   * smartpa_stat     a tiny status helper for smart PA debugging; absent from the
#     realme tree as well, nothing else depends on it.

# ---- what gets built, and why the set looks like it does -------------------
# Android runs 27 audio .ko on this phone (the vendor_boot ramdisk /lib/modules set =
# vendor_dlkm/lib/modules; see docs/changxing60/telephony.md). This build reproduces
# 25 of them from the realme C51/C53 tree, plus 2 this tree has and Android does not
# (snd-soc-sprd-pa-ucp1301, snd-soc-sprd-vaudio: harmless, they bind nothing here).
# The 2 real gaps:
#   * snd-soc-aw87xxx  the speaker PA driver -- NOT in the realme tree, and not in any
#     other source tree we have. Android ships it as a prebuilt that cannot load here
#     (module_layout CRC). The machine card still links because the realme hook file
#     wraps its aw87xxx references in `#if 0` (kallsyms_lookup_name lookups, and that
#     symbol is not exported by our kernel either). Consequence: every non-PA path
#     (earpiece, headset, mic, BT-SCO) builds and binds; the speaker PA stays silent
#     until that driver turns up. Firmware for it exists on the phone (aw87xxx_acf.bin
#     in vendor firmware).
#   * smartpa_stat     a tiny status helper for smart PA debugging; absent from the
#     realme tree as well, nothing else depends on it.

# ---- build -----------------------------------------------------------------
# Headers these Kbuilds include by name without putting the directory on their own path.
INC="-I$A/sprd_audio/agdsp_access -I$A/sprd_audio/audiomem -I$A/sprd_audio/audiosipc"
INC="$INC -I$A/sprd/include -I$A/sprd/platform/include -I$A/sprd/platform/dmaengine_pcm"
INC="$INC -I$A/sprd/codec/sprd -I$A/sprd/dai/vbc/v4/vbc_dai"

DIRS="sprd_audio/agdsp_access sprd_audio/audiomem sprd_audio/audiosipc sprd_audio/audiocpboot
sprd_audio/audiodvfs sprd_audio/audiodspdump sprd_audio/mcdt/mcdt_r2p0 sprd_audio/audio_pipe
sprd_audio/audiopipe sprd_audio/saudio sprd_audio/voice_trigger sprd_audio/voice_trigger_irq
sprd/platform/platform_routing sprd/platform/dmaengine_pcm sprd/platform/compr_2stage_dma
sprd/dai/sprd_dai sprd/dai/vaudio sprd/dai/tdm sprd/dai/vbc/v4/vbc_dai sprd/dai/vbc/v4/fe_dai
sprd/codec/sprd/ump9620/power sprd/codec/sprd/ump9620/power_dev sprd/codec/sprd/ump9620/codec
sprd/codec/dummy-codec sprd/codec/sprd/ucp1301 sprd/codec/sprd/pdm_r2p0 sprd/codec/sprd/dp
sprd/machine/sprd_card"

syms() { find $A -name Module.symvers | tr '\n' ' '; }
build() {
    d=$A/$1
    [ -f "$d/Kbuild" ] || return 0
    ls "$d"/*.ko >/dev/null 2>&1 && return 0            # already built in an earlier pass
    find "$d" -name "*.o" -delete 2>/dev/null || true   # or the retry links __this_module twice
    rm -f "$d"/*.mod "$d"/*.mod.c "$d"/Module.symvers "$d"/modules.order 2>/dev/null || true
    make O=/src/out-linux ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld -j"$(nproc)" \
        M=$d KCFLAGS="$INC" BSP_KERNEL_DEFCONFIG=sprd_qogirn6pro_defconfig \
        KBUILD_EXTRA_SYMBOLS="$(syms)" modules >/tmp/b.log 2>&1 \
        && echo "   ok: $1" \
        || echo "   still missing: $1 ($(grep -m1 -E 'error:|undefined!' /tmp/b.log | cut -c1-110))"
}
for pass in 1 2 3; do
    echo "==> pass $pass"
    for d in $DIRS; do build "$d"; done
done

mkdir -p /work/out
find $A -name "*.ko" -exec cp {} /work/out/ \;
llvm-strip --strip-debug /work/out/*.ko 2>/dev/null || true
echo "$(ls /work/out/*.ko | wc -l) audio modules"
