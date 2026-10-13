#!/usr/bin/env python3
"""Reference QR matrix from python-qrcode, in the same text format as test-qr.c.

Used only to validate tools/screen/qr.c on the host: our encoder is forced to the same mask so the
two matrices must be byte-identical (that covers codeword ordering, Reed-Solomon ECC, the format
bits and every function pattern).

    usage: ref-qr.py <text> <version> <mask>
"""
import sys
import qrcode
from qrcode.util import QRData, MODE_8BIT_BYTE

if __name__ == "__main__":
    text, version, mask = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    q = qrcode.QRCode(version=version, error_correction=qrcode.constants.ERROR_CORRECT_L,
                      mask_pattern=mask, border=0)
    q.add_data(QRData(text.encode("ascii"), mode=MODE_8BIT_BYTE))
    q.make(fit=False)
    m = q.get_matrix()
    print(len(m))
    for row in m:
        print("".join("#" if v else "." for v in row))
