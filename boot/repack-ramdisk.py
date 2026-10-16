#!/usr/bin/env python3
"""Rebuild a slot-b boot image, replacing files inside its ramdisk and nothing else.

    boot/repack-ramdisk.py --base work/boot_b-live.img --set init=boot/init \
        --out work/boot-linux-slotb.img

Why this exists next to build-boot-image.py: that one builds an image from parts (a kernel
Image, a modules directory, a static busybox, an Android subset) and needs the whole
toolchain to be present. When the only thing that has changed is a file *inside* the
ramdisk -- which is the case for the rename, where exactly one file, /init, carried the old
name -- rebuilding from parts would mean reproducing a 30 MiB kernel byte-for-byte just to
prove nothing about it changed. This takes an image that already boots and rewrites the
ramdisk, so the kernel, the AVB block and the header are carried over untouched and the
difference between the input and the output is exactly the files named with --set.

The image is laid out the same way build-boot-image.py lays one out, because that layout is
what the device has already been booting: Android boot header v4 (kernel, then the ramdisk,
each page aligned), then the AVB block moved to the end of the body, then the 64-byte AVB
footer with original_image_size rewritten to where the AVB block now starts. The persistent
init log lives at 56 MiB inside boot_b, so the body must stay below it; this refuses rather
than silently overwriting the log.

--set takes NAME=SOURCE, repeated: NAME is the path inside the ramdisk (e.g. init) and
SOURCE is a file on the host. --show lists what the base image's ramdisk holds.
"""
import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path

PAGE = 4096
# 7552n-port: boot_b's tail holds a persistent init log; the image body has to end before it.
PERSIST_LOG_OFFSET = 56 << 20


def read_cpio(blob):
    """Return ([(name, mode, ino, rdev, data)], trailer_ino) in the order the archive stores them.

    Everything is kept verbatim -- the inode numbers, the modes, the dev nodes, the symlink
    targets -- so that repacking an unmodified ramdisk reproduces it byte for byte. Only
    what --set names is allowed to differ. The trailer's inode number comes back too: it is
    the one field of that record anything ever looks at, and reusing it keeps a no-op repack
    byte-identical instead of merely equivalent.
    """
    out, off = [], 0
    while True:
        if blob[off:off + 6] != b'070701':
            sys.exit(f'ramdisk is not a newc cpio archive (magic at {off} is {blob[off:off + 6]!r})')
        f = [int(blob[off + 6 + 8 * i:off + 6 + 8 * (i + 1)], 16) for i in range(13)]
        ino, mode, _uid, _gid, _nlink, _mtime, size, _dmaj, _dmin, rmaj, rmin, namesize = f[:12]
        off += 110
        name = blob[off:off + namesize - 1].decode()
        off += namesize
        off += (-off) % 4
        data = blob[off:off + size]
        off += size
        off += (-off) % 4
        if name == 'TRAILER!!!':
            return out, ino
        out.append((name, mode, ino, (rmaj, rmin), data))


def cpio_record(name, mode, ino, rdev, data):
    nb = name.encode() + b'\0'
    fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(nb), 0]
    x = b'070701' + b''.join(('%08x' % v).encode() for v in fields) + nb
    x += b'\0' * ((-len(x)) % 4)
    x += data
    x += b'\0' * ((-len(data)) % 4)
    return x


def write_cpio(entries, trailer_ino):
    blob = b''
    for name, mode, ino, rdev, data in entries:
        blob += cpio_record(name, mode, ino, rdev, data)
    return blob + cpio_record('TRAILER!!!', 0, trailer_ino, (0, 0), b'')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', required=True, type=Path, help='boot image to rebuild from (the one currently in boot_b)')
    ap.add_argument('--set', action='append', default=[], metavar='NAME=SOURCE',
                    help='replace a file inside the ramdisk; repeatable')
    ap.add_argument('--show', action='store_true', help='list the ramdisk contents and exit')
    ap.add_argument('--out', type=Path, help='where to write the rebuilt image')
    a = ap.parse_args()

    base = a.base.read_bytes()
    if base[:8] != b'ANDROID!' or struct.unpack_from('<I', base, 40)[0] != 4:
        sys.exit(f'{a.base} is not an Android boot image header v4')
    ks, rs = struct.unpack_from('<2I', base, 8)
    kern = base[PAGE:PAGE + ks]
    ram_off = PAGE + ((ks + PAGE - 1) // PAGE) * PAGE
    ram = base[ram_off:ram_off + rs]
    if ram[:4] != bytes.fromhex('02214c18'):
        sys.exit('the base image\'s ramdisk is not LZ4 legacy framed; this kernel will not boot it')

    cpio = subprocess.run(['lz4', '-d', '-c'], input=ram, capture_output=True, check=True).stdout
    entries, trailer_ino = read_cpio(cpio)

    if a.show:
        for name, mode, ino, rdev, data in entries:
            kind = 'dir' if mode & 0o170000 == 0o040000 else ('lnk' if mode & 0o170000 == 0o120000 else 'file')
            print(f'{kind:4} {mode & 0o7777:04o} {len(data):>10} {name}')
        print(f'--- {len(entries)} entries, cpio {len(cpio)} bytes, ramdisk {rs} bytes')
        return

    if not a.out:
        sys.exit('--out is required (or use --show)')
    overrides = {}
    for s in a.set:
        if '=' not in s:
            sys.exit(f'--set wants NAME=SOURCE, got {s!r}')
        name, src = s.split('=', 1)
        overrides[name] = Path(src).read_bytes()

    names = [e[0] for e in entries]
    for name in overrides:
        if name not in names:
            sys.exit(f'the base ramdisk has no {name!r}; --show lists what it does have')

    new_entries = [(n, m, i, r, overrides.get(n, d)) for n, m, i, r, d in entries]
    new_cpio = write_cpio(new_entries, trailer_ino)
    new_ram = subprocess.run(['lz4', '-l', '-12', '-c'], input=new_cpio, capture_output=True, check=True).stdout
    assert new_ram[:4] == bytes.fromhex('02214c18'), 'lz4 did not produce legacy framing'

    hdr = bytearray(base[:PAGE])
    struct.pack_into('<I', hdr, 8, len(kern))
    struct.pack_into('<I', hdr, 12, len(new_ram))
    body = bytes(hdr) + kern + b'\0' * ((-ks) % PAGE) + new_ram
    body += b'\0' * ((-len(body)) % PAGE)
    original_size = len(body)

    # The AVB block moves with the body: the footer's original_image_size is the offset the
    # block starts at, so it is rewritten rather than the block being left where it was.
    avb_off, avb_size = struct.unpack_from('>QQ', base, len(base) - 44)
    body += base[avb_off:avb_off + avb_size]
    if len(body) > PERSIST_LOG_OFFSET:
        sys.exit(f'image data ({len(body)} bytes) overlaps the persistent log area at 56 MiB')
    # Past the image is the partition's own, not the image's: boot_b's tail carries the
    # persistent init log (the previous boot's, at 48 MiB in an older layout and 56 MiB in
    # this one). build-boot-image.py zero-fills here because it builds an image from scratch;
    # a repack is rewriting an image that has been booted, and wiping the log would throw away
    # the forensics the log exists for. So the tail is carried over -- unless the image shrank,
    # in which case carrying it over would resurrect the old ramdisk's bytes as if they were
    # the new image's.
    if len(body) >= avb_off + avb_size:
        body += base[len(body):len(base) - 64]
    else:
        body += b'\0' * (len(base) - 64 - len(body))
    footer = bytearray(base[-64:])
    struct.pack_into('>QQQ', footer, 12, original_size, original_size, avb_size)
    image = body + bytes(footer)
    assert len(image) == len(base)

    a.out.write_bytes(image)
    a.out.with_suffix('.json').write_text(json.dumps({
        'image': a.out.name,
        'base': a.base.name,
        'sha256': hashlib.sha256(image).hexdigest(),
        'sha256_head56m': hashlib.sha256(image[:PERSIST_LOG_OFFSET]).hexdigest(),
        'kernel_sha256': hashlib.sha256(kern).hexdigest(),
        'ramdisk_size': len(new_ram),
        'replaced': {n: hashlib.sha256(d).hexdigest() for n, d in overrides.items()},
    }, indent=2) + '\n')
    print(f'{a.out}: kernel {len(kern)} B unchanged, ramdisk {rs} -> {len(new_ram)} B, '
          f'replaced {", ".join(sorted(overrides))}')


if __name__ == '__main__':
    main()
