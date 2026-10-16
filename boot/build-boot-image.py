#!/usr/bin/env python3
"""Build a ZTE F50 / MU300 (Unisoc T760, UMS9620) Linux boot image for slot b.

The image reuses the stock boot image header and AVB footer layout (the device runs a
boot-verification bypass, the AVB descriptor is kept as-is), replaces the kernel and the
boot ramdisk, and adds a bootloader_control block that init writes back to misc so the
next reboot returns to slot a (Android).

Inputs are the user's own dumps; nothing device-specific is embedded in this script.

Example:
  build-boot-image.py \
    --stock-boot dumps/boot_a.img --misc-head dumps/misc-head.bin \
    --kernel out/Image --modules out/modules --busybox busybox-static-arm64 \
    --logdw tools/logdw/logdw --android-subset android-subset \
    --ueventd-perms android-vendor/ueventd-perms.sh --out boot-linux-slotb.img
"""
import argparse
import hashlib
import json
import os
import stat
import struct
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGE = 4096
BOOT_CMDLINE = b'loglevel=5'
MISC_BC_OFFSET = 0x800
# persistent init log lives at 56 MiB inside boot_b (4 MiB); the image must end before it.
# path C: kernel 30.5MB + openwrt tarball 14.7MB + ramdisk 7.5MB ≈ 52 MiB body, past the old
# 48 MiB limit — shift the persist region 48→56 MiB (count 2048→1024) to make room.
PERSIST_LOG_OFFSET = 56 << 20


def cpio_record(name, data, mode, ino, rdev=(0, 0)):
    nb = name.encode() + b'\0'
    fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(nb), 0]
    h = b'070701' + b''.join(('%08x' % v).encode() for v in fields)
    x = h + nb
    x += b'\0' * ((-len(x)) % 4)
    x += data
    x += b'\0' * ((-len(data)) % 4)
    return x


def bootloader_control(misc_head):
    """Return (slot_a_block, slot_b_trial_block) derived from the live misc bootloader_control.

    7552n-port: derive from the live state instead of hardcoding F50 bytes (7552N live is
    a=0xff/b=0x1e, F50 was a=0x9f/b=0x1e).  Each block is the live block with the *chosen*
    slot pinned to priority 15 and the other one clamped to at most 14, so the chosen slot
    always wins and the pair is stable no matter which slot we derive from:

      * slot b (Linux): prio 15, tries 2, successful 0.  LK decrements tries to 1 before
        booting b, and if the boot never marks itself successful the next reboot rolls back
        to slot a (Android).
      * slot a (Android): prio 15, tries 7, successful 1 — the stock Android slot; it must
        stay *successful* or a stale "boot android" request would run out of tries and fall
        back to Linux.

    Deriving both from the live block (rather than "live is the restore block, live minus one
    is the trial") is what makes the device work when it is already running slot b: the live
    misc then *is* the slot-b block changxing60-next-boot re-arms every boot, and a rule that just
    lowered the live slot a's priority would ratchet it down on every rebuild.
    """
    bc = misc_head[MISC_BC_OFFSET:MISC_BC_OFFSET + 32]
    if bc[4:8] != b'BCAB':
        sys.exit('misc head has no bootloader_control magic at 0x800')
    if zlib.crc32(bc[:28]) != struct.unpack('<I', bc[28:])[0]:
        sys.exit('misc bootloader_control CRC mismatch')
    if bc[0:2] not in (b'_a', b'_b'):
        sys.exit(f'misc bootloader_control suffix is neither _a nor _b: {bc[0:4]!r}')

    def block(target):
        t = bytearray(bc)
        t[0:4] = target + b'\0\0'
        if target == b'_b':
            t[14] = 0x2f                                             # b: prio 15, tries 2, successful 0
            t[12] = (bc[12] & 0xf0) | min(bc[12] & 0x0f, 14)         # a: <= 14, keeps tries/successful
        else:
            t[12] = 0xff                                             # a: prio 15, tries 7, successful 1
            t[14] = (bc[14] & 0xf0) | min(bc[14] & 0x0f, 14)         # b: <= 14
        t[28:32] = struct.pack('<I', zlib.crc32(bytes(t[:28])))
        return bytes(t)

    return block(b'_a'), block(b'_b')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--stock-boot', required=True, type=Path, help='stock boot_a.img dump (64 MiB, header v4)')
    ap.add_argument('--misc-head', required=True, type=Path, help='first 4 KiB of the misc partition')
    ap.add_argument('--kernel', required=True, type=Path, help='arm64 Image built from kernel/')
    ap.add_argument('--modules', required=True, type=Path, help='flat directory with the built .ko files')
    ap.add_argument('--module-order', type=Path, default=HERE / 'module-order.txt')
    ap.add_argument('--init', type=Path, default=HERE / 'init')
    ap.add_argument('--busybox', required=True, type=Path, help='static arm64 busybox')
    ap.add_argument('--logdw', required=True, type=Path, help='tools/logdw build (static arm64)')
    ap.add_argument('--ueventd-perms', required=True, type=Path)
    ap.add_argument('--android-subset', type=Path, help='directory produced by android-vendor/extract-subset.sh')
    ap.add_argument('--openwrt-tarball', type=Path, help='OpenWrt rootfs tarball; path C ships it as /openwrt.tar.gz in the ramdisk (extract + switch_root)')
    ap.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()

    base = a.stock_boot.read_bytes()
    if base[:8] != b'ANDROID!' or struct.unpack_from('<I', base, 40)[0] != 4:
        sys.exit('stock boot is not an Android boot image header v4')
    slot_a_bc, slot_b_bc = bootloader_control(a.misc_head.read_bytes())

    files = {
        'init': (a.init.read_bytes(), stat.S_IFREG | 0o755),
        'bin/busybox': (a.busybox.read_bytes(), stat.S_IFREG | 0o755),
        'bin/sh': (b'busybox', stat.S_IFLNK | 0o777),
        'bin/logdw': (a.logdw.read_bytes(), stat.S_IFREG | 0o755),
        'etc/ueventd-perms.sh': (a.ueventd_perms.read_bytes(), stat.S_IFREG | 0o755),
        'etc/misc-bc-slot-a.bin': (slot_a_bc, stat.S_IFREG | 0o644),
        'etc/misc-bc-slot-b-trial.bin': (slot_b_bc, stat.S_IFREG | 0o644),
        'etc/module-order': (a.module_order.read_bytes(), stat.S_IFREG | 0o644),
    }
    dirs = {'bin', 'sbin', 'etc', 'proc', 'sys', 'dev', 'run', 'tmp', 'root', 'config', 'linux-modules'}
    for name in a.module_order.read_text().split():
        ko = a.modules / name
        if not ko.exists():
            sys.exit(f'missing module {ko}')
        files['linux-modules/' + name] = (ko.read_bytes(), stat.S_IFREG | 0o644)
    if a.android_subset:
        dirs.add('android')
        for f in sorted(a.android_subset.rglob('*')):
            rel = 'android/' + str(f.relative_to(a.android_subset))
            if f.is_symlink():
                files[rel] = (os.readlink(f).encode(), stat.S_IFLNK | 0o777)
            elif f.is_dir():
                dirs.add(rel)
            else:
                files[rel] = (f.read_bytes(), stat.S_IFREG | (0o755 if os.access(f, os.X_OK) else 0o644))

    if a.openwrt_tarball:
        files['openwrt.tar.gz'] = (a.openwrt_tarball.read_bytes(), stat.S_IFREG | 0o644)

    cpio = bytearray()
    ino = 1
    for d in sorted(dirs, key=lambda x: (x.count('/'), x)):
        cpio += cpio_record(d, b'', stat.S_IFDIR | 0o755, ino)
        ino += 1
    for name, (data, mode) in files.items():
        cpio += cpio_record(name, data, mode, ino)
        ino += 1
    # the kernel opens /dev/console before running /init
    cpio += cpio_record('dev/console', b'', stat.S_IFCHR | 0o600, ino, (5, 1))
    ino += 1
    cpio += cpio_record('TRAILER!!!', b'', 0, ino)
    # must match vendor_boot's LZ4 legacy framing: a gzip segment makes this 5.4 kernel fall
    # back to the /dev/ram0 image path and panic "Unable to mount root fs on unknown-block(1,0)"
    ram = subprocess.run(['lz4', '-l', '-12', '-c'], input=bytes(cpio), capture_output=True, check=True).stdout
    assert ram[:4] == bytes.fromhex('02214c18')

    kern = a.kernel.read_bytes()
    hdr = bytearray(base[:PAGE])
    struct.pack_into('<I', hdr, 8, len(kern))
    struct.pack_into('<I', hdr, 12, len(ram))
    hdr[44:44 + 1536] = BOOT_CMDLINE + b'\0' * (1536 - len(BOOT_CMDLINE))
    struct.pack_into('<I', hdr, 1580, 0)  # signature_size
    body = bytes(hdr) + kern + b'\0' * ((-len(kern)) % PAGE) + ram
    body += b'\0' * ((-len(body)) % PAGE)
    original_size = len(body)

    avb_off, avb_size = struct.unpack_from('>QQ', base, len(base) - 44)
    body += base[avb_off:avb_off + avb_size]
    if len(body) > PERSIST_LOG_OFFSET:
        sys.exit(f'image data ({len(body)} bytes) overlaps the persistent log area at 56 MiB')
    body += b'\0' * (len(base) - 64 - len(body))
    footer = bytearray(base[-64:])
    struct.pack_into('>QQQ', footer, 12, original_size, original_size, avb_size)
    image = body + bytes(footer)
    assert len(image) == len(base)

    a.out.write_bytes(image)
    a.out.with_suffix('.misc-slot-b-trial.bin').write_bytes(slot_b_bc)
    manifest = {
        'image': a.out.name,
        'sha256': hashlib.sha256(image).hexdigest(),
        # boot_b's tail holds the persistent init log, so on-device checks compare only the first 48 MiB
        'sha256_head48m': hashlib.sha256(image[:PERSIST_LOG_OFFSET]).hexdigest(),
        'kernel_sha256': hashlib.sha256(kern).hexdigest(),
        'ramdisk_size': len(ram),
        'modules': len(a.module_order.read_text().split()),
        'misc_slot_b_trial_hex': slot_b_bc.hex(),
        'misc_slot_a_hex': slot_a_bc.hex(),
    }
    a.out.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
