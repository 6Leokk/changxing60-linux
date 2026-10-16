#!/usr/bin/env python3
"""Regenerate font8x16.h from a Linux kernel tree's lib/fonts/font_8x16.c (GPL-2.0).

The console font is 256 glyphs x 16 rows, one byte per row, MSB = leftmost pixel.
Usage: extract-font.py <kernel-tree>/lib/fonts/font_8x16.c tools/screen/font8x16.h
"""
import re, sys

src, dst = sys.argv[1], sys.argv[2]
vals = []
for line in open(src, encoding="utf-8", errors="replace"):
    m = re.match(r"\s*0x([0-9a-fA-F]{2}),", line)   # data lines only: comments also carry hex
    if m:
        vals.append(int(m.group(1), 16))
assert len(vals) == 4096, f"expected 4096 bytes, got {len(vals)}"
with open(dst, "w") as f:
    f.write("/* Generated from Linux lib/fonts/font_8x16.c (GPL-2.0) by tools/screen/extract-font.py.\n"
            " * 256 glyphs x 16 rows; each row is one byte, MSB = leftmost pixel. */\n"
            "#ifndef CHANGXING60_FONT8X16_H\n#define CHANGXING60_FONT8X16_H\n"
            "static const unsigned char font8x16[4096] = {\n")
    for i in range(0, 4096, 16):
        f.write("  " + ",".join("0x%02x" % v for v in vals[i:i+16]) + ",\n")
    f.write("};\n#endif\n")
print("wrote", dst, len(vals), "bytes")
