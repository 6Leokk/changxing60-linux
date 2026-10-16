#!/usr/bin/env python3
"""Stage the vendor kernel modules OpenWrt needs into out/modules.

The kernel build produces ~200 .ko, most of them filesystem/network modules a router
never loads. Staging "the ones we remembered" is how wcn_bsp, zram and the thermal
drivers silently stayed out of the rootfs for weeks: the built kernel had them, the
image did not, and nothing failed until someone probed the hardware.

So the selection here is not a hand-written list. It is the transitive closure of the
modules the changxing60 scripts actually modprobe, resolved from the `depends=` field each
.ko carries in its .modinfo section (the same field OpenWrt's kmodloader reads). A
root module that was not built, or a dependency that is neither built nor built into
the kernel, is reported and makes the script exit non-zero.
"""
import argparse
import shutil
import struct
import subprocess
import sys
from pathlib import Path

# Modules the rootfs loads itself: wifi-start, extra-modules, zram-start and
# bluetooth-start name these. They are roots, not the whole set -- their
# dependencies are pulled in below.
ROOTFS_ROOTS = [
    # wifi-start, in load order
    "pcie-sprd-misc", "pcie-sprd", "wcn_bsp", "sprd_wlan_combo",
    # extra-modules
    "sprd_soc_thm", "thermal-generic-adc", "sprd_cpu_cooling", "leds-sc27xx-bltc",
    "zte_card_holder_det", "sc27xx-vibra", "sprd_cp_dvfs",
    "sprd_ddr_dvfs", "sprd_gpu_cooling",
    # extra-modules, Mali. Out-of-tree: kernel/build-mali.sh builds it from the realme C51/C53
    # kernel_modules tree (kernel5.4/gpu/natt/mali, DDK r40p0-01eac0) and drops the .ko into
    # out-linux/, so it lands in this index like any other module. It is a hard root now -- it
    # silently stayed out of the rootfs and extra-modules logged "FAILED mali_kbase" at boot.
    "mali_kbase",
    # zram-start (zram -> zsmalloc)
    "zram",
    # changxing60-voiced, the call-audio stack. Out-of-tree: kernel/build-audio.sh builds it
    # from the realme C51/C53 kernel_modules tree (kernel5.4/audio_driver) the same way; see
    # docs/changxing60/telephony.md. The depends= closure only pulls what these modules
    # *depend on*, so the leaf services (which depend on the stack, but are not depended
    # on by it) have to be named explicitly -- that is the same reason Android keeps a
    # modules.load list instead of trusting modules.dep: the UMP9620 codec, the AGDSP boot
    # and DVFS loaders, the DSP debug/pipe services, saudio, the BT-SCO / vaudio / TDM /
    # PDM DAIs, the DP codec, the routing helper and the voice triggers would never be
    # reached from below.
    "snd-soc-sprd-card",
    "snd-soc-sprd-vbc-fe",
    "snd-soc-sprd-vbc-v4",
    "snd-soc-sprd-dai",
    "sprd-dmaengine-pcm",
    "sprd-compr-2stage-dma",
    "sprd-platform-pcm-routing",
    "snd-soc-sprd-codec-ump9620",
    "snd-soc-sprd-codec-ump9620-power",
    "snd-soc-sprd-codec-ump9620-power-dev",
    "sprd_audcp_boot",
    "sprd_audcp_dvfs",
    "audio-dsp-dump",
    "audio-pipe",
    "saudio",
    "sprd_apipe",
    "snd-soc-sprd-dummy-codec",
    "snd-soc-sprd-vaudio",
    "snd-soc-sprd-tdm",
    "snd-soc-sprd-pdm-r2p0",
    "snd-soc-unisoc-dp-codec",
    "voice_trigger_irq",
    "voice_trigger_node",
    # built here but deliberately not a load root: snd-soc-sprd-pa-ucp1301 binds no node
    # on this board (no ucp1301 PA in the DT), kept out of the rootfs like Android does.
]

# Named by the rootfs scripts but absent from out-linux: sprdbt_tty and zte_sar come from the realme
# vendor tree -- separate out-of-tree builds that have not been run here. Report them, do not fail
# the build: a missing root in this list is a known feature gap (Bluetooth, SAR), not a staging bug.
OPTIONAL_ROOTS = ["zte_sar", "sprdbt_tty"]


def modinfo(path: Path) -> dict:
    """Return the .modinfo key/values of an ELF module (or {} if it has none)."""
    data = path.read_bytes()
    if data[:4] != b"\x7fELF":
        return {}
    is64 = data[4] == 2
    if is64:
        e_shoff, = struct.unpack_from("<Q", data, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3a)
    else:
        e_shoff, = struct.unpack_from("<I", data, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x2e)

    def section(idx):
        off = e_shoff + idx * e_shentsize
        if is64:
            name, _, _, addr, offset, size = struct.unpack_from("<IIQQQQ", data, off)
        else:
            name, _, _, addr, offset, size = struct.unpack_from("<IIIIII", data, off)
        return name, offset, size

    _, shstr_off, _ = section(e_shstrndx)
    for i in range(e_shnum):
        name, offset, size = section(i)
        end = data.index(b"\0", shstr_off + name)
        if data[shstr_off + name:end] == b".modinfo":
            blob = data[offset:offset + size]
            break
    else:
        return {}

    out = {}
    for entry in blob.split(b"\0"):
        key, sep, value = entry.partition(b"=")
        if sep:
            out[key.decode()] = value.decode()
    return out


def strip_modules(out: Path, image: str) -> str:
    """Drop the debug info from the staged .ko. The kernel tree keeps it (46 MiB for the 94
    ramdisk modules) and the ramdisk only has room for the stripped set (20 MiB). A host
    binutils strip cannot read aarch64 objects, so fall back to the cross build image."""
    which = next((c for c in ("aarch64-linux-gnu-strip", "llvm-strip") if shutil.which(c)), None)
    if which:
        subprocess.run([which, "--strip-debug", *map(str, sorted(out.glob("*.ko")))], check=True)
        return which
    if not shutil.which("docker"):
        raise SystemExit("stage-modules: no aarch64 strip and no docker to borrow one from")
    subprocess.run(["docker", "run", "--rm", "-v", f"{out}:/m", image, "sh", "-c",
                    "aarch64-linux-gnu-strip --strip-debug /m/*.ko"], check=True)
    return f"docker {image} aarch64-linux-gnu-strip"


def main() -> int:
    top = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--built", type=Path, default=top / "out-linux",
                    help="kernel build tree to take .ko from (default: out-linux)")
    ap.add_argument("--out", type=Path, default=top / "out" / "modules",
                    help="staging directory (default: out/modules)")
    ap.add_argument("--order", type=Path, default=top / "boot" / "module-order.txt",
                    help="the ramdisk module list, also staged (the rescue image shares it)")
    ap.add_argument("--builtin", type=Path, default=top / "out" / "modules.builtin",
                    help="modules.builtin of the kernel, whose entries need no .ko")
    ap.add_argument("--prune", action="store_true",
                    help="delete .ko in the staging dir that are outside the closure")
    ap.add_argument("--no-strip", action="store_true",
                    help="keep the debug info (the modules will not fit the ramdisk budget)")
    ap.add_argument("--strip-image", default="changxing60-kbuild-cross",
                    help="container holding aarch64-linux-gnu-strip (default: %(default)s)")
    args = ap.parse_args()

    index = {}
    for ko in args.built.rglob("*.ko"):
        index.setdefault(ko.name[:-3], ko)
    if not index:
        print(f"stage-modules: no .ko under {args.built}", file=sys.stderr)
        return 2

    builtin = set()
    if args.builtin.exists():
        builtin = {line.strip().rsplit("/", 1)[-1][:-3]
                   for line in args.builtin.read_text().splitlines() if line.strip()}

    roots = []
    if args.order.exists():
        roots += [line.strip()[:-3] for line in args.order.read_text().splitlines() if line.strip()]
    roots += ROOTFS_ROOTS
    roots += OPTIONAL_ROOTS

    root_set = set(roots)
    optional = set(OPTIONAL_ROOTS)
    wanted, missing, queue = {}, [], list(roots)
    while queue:
        name = queue.pop()
        if name in wanted or name in builtin:
            continue
        ko = index.get(name)
        if ko is None:
            missing.append((name, name in root_set and name not in optional))
            continue
        wanted[name] = ko
        for dep in filter(None, modinfo(ko).get("depends", "").split(",")):
            dep = dep.strip()
            if dep not in wanted and dep not in builtin:
                queue.append(dep)

    args.out.mkdir(parents=True, exist_ok=True)
    copied = []
    for name, ko in sorted(wanted.items()):
        dst = args.out / ko.name
        if not dst.exists() or dst.read_bytes() != ko.read_bytes():
            dst.write_bytes(ko.read_bytes())
            copied.append(ko.name)
    if copied and not args.no_strip:
        stripper = strip_modules(args.out, args.strip_image)
        print(f"stage-modules: stripped {len(copied)} module(s) with {stripper}")

    stale = [p for p in args.out.glob("*.ko") if p.name[:-3] not in wanted]
    if args.prune:
        for p in stale:
            p.unlink()

    total = sum(p.stat().st_size for p in args.out.glob("*.ko"))
    print(f"stage-modules: {len(wanted)} modules, {total / 1048576:.1f} MiB -> {args.out}")
    if stale and not args.prune:
        print(f"stage-modules: {len(stale)} module(s) in {args.out} are outside the closure "
              f"(pass --prune to remove): {', '.join(p.name for p in stale)}")
    failed = 0
    for name, is_root in sorted(missing):
        if is_root:
            print(f"stage-modules: {name} is requested by the rootfs scripts but was not built",
                  file=sys.stderr)
            failed += 1
        else:
            print(f"stage-modules: optional module {name} was not built (feature gap, not a "
                  f"staging bug)", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
