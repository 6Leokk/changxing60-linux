#!/usr/bin/env python3
"""Flip one node's `status` inside a vendor_boot DTB *in place*, byte-for-byte size preserving.

Why this exists
---------------
vendor_boot_b holds the DT that **both** kernels on slot b read: the 6.18 mainline boot and the 5.4
OpenWrt boot.  patch-vendor-dtb.py edits that DT for mainline and, among other things, sets

    dummyphy { compatible = "sprd,usb-dummy-phy"; status = "disabled"; };

which is right for mainline (no driver for that compatible exists in 6.18, so dwc3's legacy phy
lookup must get -ENODEV, not -EPROBE_DEFER) and *fatal* for 5.4: the vendor glue's
devm_usb_get_phy_by_phandle(dev, "usb-phy", 0) then finds no usb_phy for that node, so
`dwc3-sprd 25100000.usb3: unable to get usb2.0 phy device` -> no UDC -> no gadget -> no usb0 ->
the box boots with no management interface at all.  That is what happened: the mainline DTB was
left in vendor_boot_b, and every slot-b OpenWrt boot after 2026-10-14 came up unreachable
(2026-10-16 post-mortem).

Now the trick that makes the way back cheap.  In the DT, "disabled" is 9 bytes with the NUL and
"okay" is 5, and values are padded to 4, so a naive edit changes the blob's size -- which would
need a full repack (dtc round trip + mkvendorboot.py + a new dtb_table_entry).  But `okay` padded
to the *same* 12-byte stride trivially: keep `len = 9` and store "okay\\0\\0\\0\\0\\0".  Every
kernel-side reader (of_device_is_available, strcmp) stops at the first NUL, so this is exactly
"okay".  The result differs from the original file in 9 bytes and *nothing* moves: no totalsize
change, no table entry change, no AVB/size bookkeeping, no dtc needed.  Which means the fix is a
9-byte dd on the device, and the same tool run the other way is all it takes to hand vendor_boot_b
back to mainline for a 6.18 trial.

usage:
  vendor-dtb-status.py --image work/dumps/vendor_boot_b-7552n.img --node dummyphy --show
  vendor-dtb-status.py --image <in.img> --node dummyphy --set okay --out <out.img>
  vendor-dtb-status.py --image <in.img> --node dummyphy --set okay --prep work/dtbprep
      # ^ the one to use before a device-side fix: writes the patched image plus vb-patch.bin /
      #   vb-offset / vb-before.sha / vb-after.sha, which is exactly what
      #   work/changxing60-android-dtb-fix.sh reads.
  vendor-dtb-status.py --image <in.img> --node dummyphy --set okay --patch-at   # dd one-liner values

--patch-at prints the absolute offset inside the image and the 9 bytes to write, so the device-side
write is `dd if=value.bin of=$PART bs=1 seek=<off> conv=notrunc` plus a readback.
"""
import argparse
import hashlib
import os
import struct
import sys

FDT_MAGIC = 0xD00DFEED
DT_TABLE_MAGIC = 0xD7B7AB1E
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def align(x, a=4):
    return (x + a - 1) // a * a


def extract_dtb(image):
    """(dtb_bytes, absolute_offset_of_dtb_in_image) from a vendor_boot v4 image.

    The v4 "dtb" section is: 32-byte table header (big endian) | dtb_table_entry[count] | the DT
    blobs.  dtb_table_entry.dtb_offset counts from the start of that section, so the blob is at
    o_dtb + dt_off -- note patch-vendor-dtb.py slices `e_off + e_size` instead, which lands on the
    same byte only because this image has one entry sitting immediately before the blob.
    """
    b = open(image, 'rb').read()
    if b[:8] != b'VNDRBOOT' or struct.unpack_from('<I', b, 8)[0] != 4:
        sys.exit(f'{image}: not a vendor_boot v4 image')
    page, = struct.unpack_from('<I', b, 12)
    vr_size, = struct.unpack_from('<I', b, 24)
    hsize, dtb_size = struct.unpack_from('<II', b, 2096)
    o_dtb = align(hsize, page) + align(vr_size, page)
    old = b[o_dtb:o_dtb + dtb_size]
    magic, total, h_size, e_size, e_count, e_off, t_page, t_ver = struct.unpack_from('>8I', old, 0)
    if magic != DT_TABLE_MAGIC or e_count < 1:
        sys.exit('unexpected DTB section format')
    if e_count > 1:
        sys.exit(f'{e_count} DTBs in the table; this tool only handles the single-DTB images we build')
    dt_size, dt_off = struct.unpack_from('>II', old, e_off)
    if b[o_dtb + dt_off:o_dtb + dt_off + 4] != b'\xd0\x0d\xfe\xed':
        sys.exit(f'no FDT magic at o_dtb+dt_off = {o_dtb + dt_off}')
    return old[dt_off:dt_off + dt_size], o_dtb + dt_off


def fdt_walk(dtb):
    """Yield (path, prop_name, value_offset, value_len) for every property in the blob.

    Hand-rolled on purpose: the alternative is dtc, and dtc cannot round trip a blob without
    moving bytes around, which is the one thing this tool must not do.
    """
    magic, totalsize, off_struct, off_strings, off_rsvmap, version, lastcomp, bootcpu, \
        size_strings, size_struct = struct.unpack_from('>10I', dtb, 0)
    if magic != FDT_MAGIC:
        sys.exit(f'bad FDT magic 0x{magic:08x}')
    if totalsize != len(dtb):
        sys.exit(f'FDT totalsize {totalsize} != blob size {len(dtb)}')

    def cstr(off):
        end = dtb.index(b'\0', off)
        return dtb[off:end].decode('utf-8', 'replace')

    p, stack = off_struct, []
    while True:
        if p + 4 > off_struct + size_struct:
            sys.exit('structure block ended without FDT_END')
        (tok,) = struct.unpack_from('>I', dtb, p)
        p += 4
        # every offset inside the struct block is 4-aligned relative to its start, not to the file
        rel = lambda x: off_struct + align(x - off_struct)
        if tok == FDT_BEGIN_NODE:
            end = dtb.index(b'\0', p)
            stack.append(cstr(p).split('@')[0])
            p = rel(end + 1)
        elif tok == FDT_END_NODE:
            if not stack:
                sys.exit('FDT_END_NODE with empty node stack')
            stack.pop()
        elif tok == FDT_PROP:
            ln, nameoff = struct.unpack_from('>II', dtb, p)
            p += 8
            yield '/'.join(stack), cstr(off_strings + nameoff), p, ln
            p = rel(p + ln)
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            return
        else:
            sys.exit(f'bad FDT token {tok} at {p - 4}')


def show(dtb, node):
    """(path, value_offset, value_len, value_bytes) for the `status` of the node named `node`."""
    out = []
    for path, name, off, ln in fdt_walk(dtb):
        if name != 'status':
            continue
        if path.split('/')[-1] != node:
            continue
        out.append((path, off, ln, dtb[off:off + ln]))
    if not out:
        sys.exit(f'no status property on a node named {node!r}')
    if len(out) > 1:
        sys.exit(f'{len(out)} nodes named {node!r}: ' + ', '.join(p for p, *_ in out))
    return out[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--image', help='vendor_boot image to read/rewrite')
    ap.add_argument('--dtb', help='bare DTB file instead of an image')
    ap.add_argument('--node', help='node name (unit address stripped), e.g. dummyphy')
    ap.add_argument('--set', dest='value', help='new status value, e.g. okay')
    ap.add_argument('--show', action='store_true', help='print the current value and stop')
    ap.add_argument('--patch-at', action='store_true',
                    help='print the image offset + bytes for a device-side dd, write nothing')
    ap.add_argument('--out', help='write the patched image/DTB here')
    ap.add_argument('--prep', metavar='DIR',
                    help='write everything the on-device fix script needs: DIR/vendor_boot_b.fixed.img, '
                         'DIR/vb-patch.bin, DIR/vb-offset, DIR/vb-before.sha, DIR/vb-after.sha')
    a = ap.parse_args()
    if not (a.image or a.dtb):
        sys.exit('need --image or --dtb')

    if a.image:
        dtb, base = extract_dtb(a.image)
    else:
        dtb, base = open(a.dtb, 'rb').read(), 0
    print(f'  DTB {len(dtb)} bytes, image offset {base}')

    if not a.node:
        sys.exit('need --node')
    path, off, ln, cur = show(dtb, a.node)
    val = cur.split(b'\0', 1)[0].decode()   # computed outside the f-string: an escaped NUL in an
    print(f'  {path}: status = {val!r} '      # f-string expression is a version-dependent trap
          f'(len {ln}, padded {align(ln)}, at DT+{off})')

    if a.show or not a.value:
        return

    new = a.value.encode() + b'\0'
    slot = align(ln)
    if len(new) > slot:
        sys.exit(f'  REFUSING: {a.value!r} is {len(new)} bytes with the NUL but the slot is only '
                 f'{slot} (len {ln}, padded).\n'
                 f'  In-place editing means the new value must fit the padding already there, so bytes\n'
                 f'  never move and no repack is needed. "disabled" (9) -> "okay" (5) fits a 12-byte\n'
                 f'  slot; the reverse does not. For that direction use patch-vendor-dtb.py + a repack.')
    if len(new) != ln:
        # keep the stored length; NUL-pad the value up to it. Every kernel-side reader
        # (of_device_is_available, strcmp) and dtc stop at the first NUL, so this is the same string.
        new = new + b'\0' * (ln - len(new))
        print(f'  (value NUL-padded to the stored length {ln}; strcmp-identical to {a.value!r})')

    out = bytearray(dtb)
    out[off:off + ln] = new
    out = bytes(out)
    diff = [i for i in range(len(dtb)) if dtb[i] != out[i]]
    print(f'  patched: {len(diff)} bytes differ (DT+{diff[0]}..DT+{diff[-1]}), size unchanged')
    assert all(diff[i] + 1 == diff[i + 1] for i in range(len(diff) - 1)), 'patch is not contiguous'
    print(f'  image offset {base + off}  bytes {new.hex()}')

    full = None
    if a.image:
        full = bytearray(open(a.image, 'rb').read())
        full[base + off:base + off + ln] = new
        full = bytes(full)
        assert len(full) == os.path.getsize(a.image)
    patched = full if a.image else out

    if a.prep:
        sh = hashlib.sha256
        os.makedirs(a.prep, exist_ok=True)
        open(os.path.join(a.prep, 'vendor_boot_b.fixed.img'), 'wb').write(patched)
        open(os.path.join(a.prep, 'vb-patch.bin'), 'wb').write(new)
        open(os.path.join(a.prep, 'vb-offset'), 'w').write(f'{base + off}\n')
        open(os.path.join(a.prep, 'vb-before.sha'), 'w').write(
            sh(open(a.image, 'rb').read()).hexdigest() + '\n')
        open(os.path.join(a.prep, 'vb-after.sha'), 'w').write(sh(patched).hexdigest() + '\n')
        for f in ('vendor_boot_b.fixed.img', 'vb-patch.bin', 'vb-offset', 'vb-before.sha', 'vb-after.sha'):
            p = os.path.join(a.prep, f)
            print(f'  {p}: {os.path.getsize(p)} bytes')
        return
    if a.patch_at and not a.out:
        return
    if not a.out:
        sys.exit('need --out, --prep or --patch-at to write anything')

    open(a.out, 'wb').write(patched)
    print(f'  {a.out}: written')
    # re-read what we just wrote and prove the node now reports the new value
    dtb2, _ = extract_dtb(a.out) if a.image else (open(a.out, 'rb').read(), 0)
    path2, _, _, cur2 = show(dtb2, a.node)
    got = cur2.split(b'\0', 1)[0].decode()
    if got != a.value:
        sys.exit(f'  VERIFY FAILED: {path2} reads back as {got!r}')
    print(f'  verify: {path2}: status = {got!r}')


if __name__ == '__main__':
    main()
